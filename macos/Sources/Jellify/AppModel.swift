import AppKit
import Foundation
import Observation
import SwiftUI
@preconcurrency import JellifyCore
import JellifyAudio

/// Top-level app state. Owns the Rust core and publishes a reactive surface
/// that SwiftUI views observe. All core calls go through here so views never
/// touch the FFI directly.
@Observable
@MainActor
final class AppModel {
    // MARK: - Core
    let core: JellifyCore
    let audio: AudioEngine
    let mediaSession: MediaSession
    let network: NetworkMonitor
    let serverReachability: ServerReachability

    // MARK: - Session
    var session: Session?
    var serverURL: String = ""
    var username: String = ""

    // MARK: - Navigation
    enum Screen: Hashable { case home, discover, library, search, settings, album(String), artist(String), playlist(String), nowPlaying }
    var screen: Screen = .library

    /// Screen the app was on before the user opened the full Now Playing
    /// view. `NowPlayingView` offers a "Back" affordance that pops to this
    /// value rather than unconditionally routing to `.library`, so a user
    /// who opened the full player from the Album detail page lands back
    /// there on exit. `nil` when we've never been anywhere interesting
    /// (first launch lands on `.library`, which is already the fallback).
    /// See #89.
    var previousScreen: Screen?

    /// Toggled by the ⌘F menu command to request that `SearchView` move
    /// keyboard focus into its text field. `SearchView` observes changes and
    /// resets the flag after focusing so subsequent ⌘F presses fire again
    /// even when already on the Search screen.
    var requestSearchFocus: Bool = false

    /// Mirror of `requestSearchFocus` published as a plain focus flag so
    /// toolbar / search fields can bind a SwiftUI `@FocusState` to it via the
    /// usual projected-value pattern. `focusSearch()` writes both (keeping the
    /// legacy flag alive for `SearchView`'s existing onChange handler) and
    /// observers are expected to reset it once focus has landed. See #7 / #104.
    var isSearchFieldFocused: Bool = false

    /// Track id that currently has keyboard focus inside an arrow-navigable
    /// list row (Library Tracks tab, album / playlist detail). Set by
    /// `TrackListRow` / `TrackRow` when they gain focus and by arrow-key
    /// handlers when focus moves between siblings. `nil` when no list row is
    /// focused. Return plays the focused id; Space toggles global play/pause
    /// regardless. See #105.
    var focusedTrackId: String?

    // MARK: - Library
    var albums: [Album] = []
    var artists: [Artist] = []
    var tracks: [Track] = []
    /// Playlists known to the app — populated as the user navigates into
    /// playlist detail surfaces or hits a screen that needs them (e.g. the
    /// Library's Playlists tab, once #220 / #313 land). This is the source
    /// of truth for `PlaylistView` to look up a playlist by id when the
    /// shell routes `.playlist(id)`; upstream surfaces insert the playlist
    /// here on navigation so a subsequent `.playlist(id)` doesn't have to
    /// re-fetch. See #234.
    var playlists: [Playlist] = []
    var albumTracks: [String: [Track]] = [:]          // albumID → tracks
    /// Per-playlist track caches, mirroring `albumTracks`. Populated by
    /// `loadPlaylistTracks(playlist:)`; held for the session; cleared on
    /// logout. See #125 and #234.
    var playlistTracks: [String: [Track]] = [:]       // playlistID → tracks
    /// Tracks for the playlist currently on screen in `PlaylistDetailView`
    /// (#74 / #236). Separate from the keyed `playlistTracks` cache because
    /// the detail view mutates this list in response to remove / add / undo
    /// and needs a single observable array to drive the list rendering. The
    /// cache is refreshed from `playlistTracks[playlistId]` when present so
    /// repeat visits are instant.
    var currentPlaylistTracks: [Track] = []
    /// The most-recent optimistic removal from a playlist, held so the undo
    /// toast in `PlaylistDetailView` can restore it. Cleared when the 10s
    /// toast window lapses or the user taps Undo. See #74.
    var pendingPlaylistRemoval: PendingRemoval?
    /// Client-side overrides for playlist description. The server-side
    /// Jellyfin item carries `Overview`, but our core `Playlist` record
    /// doesn't expose it yet (see #130 / `update_playlist`). Until the FFI
    /// lands, the hero's click-to-edit description reads from and writes
    /// to this in-memory map so the interaction feels real; on the next
    /// session / core-refresh the override evaporates. See #234.
    var playlistDescriptions: [String: String] = [:]
    /// Cache of the top most-played tracks per artist id. Populated on demand
    /// by `loadArtistTopTracks(artistId:)` when the Artist detail screen
    /// opens. Held for the session; cleared on logout. See #229.
    var artistTopTracks: [String: [Track]] = [:]      // artistID → top tracks
    var recentlyPlayed: [Track] = []
    /// Tracks surfaced in the Discover "For You" carousel (#249). Today this
    /// is a best-effort fallback to the first 20 `recentlyPlayed` tracks. A
    /// real recommendations endpoint — seeded from listening history, minus
    /// already-played items, leaning on similar artists — is tracked as a
    /// follow-up on the core (no FFI exists yet; see `refreshForYou()` for
    /// the TODO).
    var forYou: [Track] = []
    /// Last-played albums for the Home "Jump Back In" carousel (#51). Up to
    /// 12 albums the user has played recently, sorted by `DatePlayed` desc.
    /// Backed by a raw `/Items` fetch because the core's `ItemsQuery`
    /// builder (BATCH-24) hasn't landed yet. See `refreshJumpBackIn`.
    var jumpBackIn: [Album] = []
    /// Recently-added albums for the Home "Recently Added" carousel (#54).
    /// Up to 20 albums, sorted by `DateCreated` desc (server-side via
    /// `/Users/{id}/Items/Latest`). Wired through the existing
    /// `core.latestAlbums` FFI.
    var recentlyAdded: [Album] = []
    /// `DateCreated` for each album in `recentlyAdded`, keyed by album id.
    /// Drives the "NEW" badge on tiles within the last 7 days. Parsed
    /// alongside the album list in `refreshRecentlyAdded`.
    var recentlyAddedDates: [String: Date] = [:]
    /// "Quick Picks" — heavy-rotation albums over the last 30 days (#53).
    /// Sorted by server-side `PlayCount` desc with a client-side
    /// `DatePlayed > now - 30d` filter applied via Jellyfin's `MinDateLastSaved`.
    /// Up to 12 albums.
    var quickPicks: [Album] = []
    /// Play count per album in `quickPicks`, keyed by album id. Shown as a
    /// subtle "42 plays" badge on tile hover. Parsed out of the same `/Items`
    /// response that drives `quickPicks`.
    var quickPicksPlayCounts: [String: UInt32] = [:]
    /// Favorite albums for the Home "Favorites" carousel (#55). The full
    /// favorite set is fetched once per session and then shuffled down to
    /// 12 visible tiles — re-shuffled on each `refreshFavoriteAlbums` call
    /// so the carousel feels fresh on relaunch.
    var favoriteAlbumsAll: [Album] = []
    /// Currently-visible shuffled sample of `favoriteAlbumsAll`, capped at
    /// 12. Re-derived every time the backing set is refreshed so the view
    /// doesn't have to know about the shuffle.
    var favoriteAlbumsVisible: [Album] = []
    var searchResults: SearchResults?
    var searchQuery: String = ""

    /// Instant-search payload rendered by `SearchInstantDropdown` while the
    /// user is typing in the toolbar / search field. Distinct from
    /// `searchResults` (which backs the full Search screen) so a live
    /// dropdown and the committed "see all results" surface don't trample
    /// each other. Always safe to read — empty until a non-empty query
    /// arrives. See #85 / #241 / #243.
    var instantSearchResults: InstantSearchResults = .empty

    /// In-flight debounced instant-search task. Published so re-entrant
    /// callers (each keystroke invokes `runInstantSearch`) can cancel the
    /// previous pass before kicking off a new one. Storing the handle as
    /// state rather than a local makes the cancel-previous pattern trivial
    /// regardless of which view / keystroke triggered the original fetch.
    var searchTask: Task<Void, Never>?

    /// Collection-view id of the Jellyfin "Playlists" library. Resolved
    /// lazily on first `refreshPlaylists()` — see `ensurePlaylistLibraryId`.
    /// Cached across the session; cleared on logout.
    ///
    /// Jellyfin scopes `user_playlists` / `public_playlists` by `ParentId`,
    /// so we need this before we can fetch anything. There is no FFI yet for
    /// listing the user's libraries (tracked in core issue separate from
    /// #483), so the current resolve is a pragmatic empty-string fallback:
    /// Jellyfin's `/Items` endpoint treats an empty `ParentId` as "root /
    /// any library the user can see", which happens to return playlists
    /// across the whole server. When a real `core.libraries()` FFI lands,
    /// swap this for a proper lookup.
    var playlistLibraryId: String?

    // MARK: - Pagination
    //
    // `*Total` mirrors the server's `TotalRecordCount` so views can render
    // "N of M" sublines and decide when to trigger a follow-up page. The
    // `isLoadingMore*` flags debounce near-end triggers so a fast scroll
    // through the grid doesn't fan out into duplicate in-flight fetches.
    //
    // Size of each page (see `libraryInitialPageSize` and `libraryPageSize`):
    // first paint uses 100 so the grid shows up fast; subsequent pages fetch
    // 200 to keep round-trip count low once the user has committed to browsing.

    /// Server-reported total album count for the current library.
    var albumsTotal: UInt32 = 0
    /// Server-reported total artist count for the current library.
    var artistsTotal: UInt32 = 0
    /// Server-reported total track count for the current library.
    var tracksTotal: UInt32 = 0
    /// Server-reported total playlist count for the current library.
    ///
    /// Caveat: `user_playlists` / `public_playlists` on the core filter the
    /// server's response client-side by `Path`, so this total is the raw
    /// server count across BOTH user- and public-owned playlists — i.e. an
    /// upper bound on what `items.count` will reach. See the core's
    /// `PaginatedPlaylists` docstring.
    var playlistsTotal: UInt32 = 0
    /// Server-reported total recently-played count (listening history size).
    var recentlyPlayedTotal: UInt32 = 0
    /// Server-reported total for the current search query across all item kinds.
    var searchResultsTotal: UInt32 = 0

    /// A follow-up albums page is in flight. Views check this to suppress
    /// duplicate near-end triggers and to show a bottom spinner.
    var isLoadingMoreAlbums: Bool = false
    /// A follow-up artists page is in flight. See `isLoadingMoreAlbums`.
    var isLoadingMoreArtists: Bool = false
    /// A follow-up tracks page is in flight. See `isLoadingMoreAlbums`.
    var isLoadingMoreTracks: Bool = false
    /// A follow-up playlists page is in flight. See `isLoadingMoreAlbums`.
    var isLoadingMorePlaylists: Bool = false
    /// A follow-up search page is in flight for the current query.
    var isLoadingMoreSearch: Bool = false

    /// First-paint size for library lists. Tuned smaller than subsequent
    /// pages so the grid renders quickly on login; raising this increases
    /// time-to-first-paint without measurable benefit.
    private let libraryInitialPageSize: UInt32 = 100
    /// Follow-up page size for library lists. Larger than the initial page
    /// to keep round-trip count down once the user has committed to scrolling.
    private let libraryPageSize: UInt32 = 200
    /// Initial page size for recently-played on the Home screen.
    private let recentlyPlayedInitialPageSize: UInt32 = 20
    /// Page size when walking `playlist_tracks` to completion.
    private let playlistPageSize: UInt32 = 200
    /// Hard cap on total tracks pulled from a single playlist to keep a
    /// pathological 50k-track playlist from holding the UI hostage. Callers
    /// that hit this see up to this many tracks; beyond that the rest is
    /// silently dropped. Easy to raise once a real use case complains.
    private let playlistSafetyCap: Int = 5000
    /// Page size for the "Show all results" affordance in search.
    private let searchPageSize: UInt32 = 50

    // MARK: - Player
    var status: PlayerStatus
    var pollTimer: Timer?

    // MARK: - Queue inspector (BATCH-07a, #79 / #80 / #282)
    //
    // Issue #282 — separate "Up Next" (user-added) from "Auto Queue" (what
    // will play after the user-added items run out). The core queue is a
    // flat list today (see `player::set_queue`), so the split lives only
    // in-app: `upNextAutoQueue` is derived from the core queue tail after
    // the current track, and `upNextUserAdded` is a client-side overlay
    // fed by `playNext(...)` / `addToQueue(...)` calls. When we gain a
    // proper core primitive (tracked as TODO(core-#282)), this shape stays
    // the same — only the `play(tracks:)` fan-out changes.

    /// User-added "Up Next" overlay — what the user explicitly queued via
    /// "Play Next" / "Add to Queue". Drained into actual playback as the
    /// engine advances past the current track. Reorderable and removable
    /// from the Queue Inspector (#80).
    var upNextUserAdded: [Queue] = []
    /// Auto-queue tail — the rest of the current playback source (album /
    /// playlist / radio) after the currently-playing track. Read-only in
    /// the inspector; double-click jumps to that track (#282). Derived
    /// from the core queue on every `play(tracks:)` for now.
    var upNextAutoQueue: [Queue] = []
    /// Human-readable label + id + kind for the source that populated
    /// `upNextAutoQueue`. Used by the inspector's "PLAYING FROM" header
    /// (#82 / BATCH-07b will expand this into a richer display). Nil when
    /// playback was started from an ad-hoc selection without a known
    /// source (e.g. a single track picked from "All Tracks").
    var currentContext: QueueContext?
    /// Show / hide the right-side queue inspector panel. Toggled by the
    /// Cmd+Opt+Q shortcut (#79).
    var isQueueInspectorOpen: Bool = false

    /// Contributors on the currently-playing track, sourced from Jellyfin's
    /// `Item.People` field. Populated by `fetchCurrentTrackDetails()` on
    /// track changes and cleared when the track stops. See #279.
    var currentTrackPeople: [Person] = []
    /// The track id that `currentTrackPeople` was fetched for, so we can
    /// skip redundant network calls when the status poll fires with the
    /// same track still playing.
    private var currentTrackPeopleForId: String?

    /// Parsed lyrics for the currently-playing track, if any. Populated by
    /// `fetchCurrentTrackLyrics()` on track changes and cleared when the
    /// track stops. `nil` while a fetch is pending or when no lyrics have
    /// been requested yet; empty array when the server answered but had no
    /// lyrics. The Lyrics tab of the Now Playing view uses the
    /// `nil` / empty distinction to render a loading state vs. a "No
    /// lyrics available" placeholder. See #91, #273, #287, #288.
    var currentLyrics: [LyricLine]?
    /// Track id that `currentLyrics` was fetched for, to skip redundant
    /// network calls while the same track keeps playing. Mirrors
    /// `currentTrackPeopleForId`.
    private var currentLyricsForId: String?

    // MARK: - Loading / errors
    var isLoggingIn = false
    var isLoadingLibrary = false
    var errorMessage: String?

    /// Set during the one-shot `attemptRestoreSession` pass at launch. `RootView`
    /// renders a minimal loading state while this is true so we don't briefly
    /// flash `LoginView` on cold start even though a valid session is about to
    /// be rehydrated from the keychain.
    ///
    /// Starts `true` so the very first render (which happens before
    /// `RootView.task` fires) shows the loading splash rather than a
    /// one-frame flash of `LoginView`. `attemptRestoreSession` flips this to
    /// `false` once the restore pass is done — either a session was
    /// rehydrated or there was nothing to restore.
    var isRestoringSession = true

    /// Set when a core call fails because the server rejected our token
    /// (HTTP 401) or the core reports no-longer-authenticated. Drives the
    /// modal prompt in `MainShell`. Reset after the user dismisses the sheet
    /// or signs back in. Auto-reauth (reissuing credentials silently) is
    /// tracked separately in #440 — this flag only powers the prompt.
    var authExpired: Bool = false

    /// Toggled `true` for a brief window when a track fails to stream, so the
    /// `PlayerBar` can flash a 10% danger tint as a peripheral-vision cue.
    /// `StreamErrorToast` is the foreground surface; this flag is the
    /// subtle accompanying signal (see issue #302).
    ///
    /// The toast + flash pair is published here so the reliability wiring
    /// (`BATCH-21`) can flip it without reaching into view code. `PlayerBar`
    /// observes the flag via the usual `@Environment(AppModel.self)` channel;
    /// callers that raise an error should flip this on, then flip it off
    /// after ~2s (the flash duration). No animation is driven from here — the
    /// consumer owns the tween.
    var streamErrorFlash: Bool = false

    /// Playlist the user asked to delete from a context menu. Observed by
    /// `MainShell` to present a `.confirmationDialog`; cleared when the
    /// user confirms or dismisses. Single-shot rather than a list because
    /// the dialog is modal — only one can be pending at a time. See #131.
    var playlistPendingDelete: Playlist?

    /// Artists the user has "followed" in-app. Today this is purely local
    /// state (no server-side follow primitive on Jellyfin), persisted to
    /// `UserDefaults` on write. See #64 / #228.
    var followedArtistIds: Set<String> = []

    // MARK: - Command Palette (⌘K)

    /// Whether the command-palette overlay is currently visible. Toggled by
    /// the ⌘K menu command and by the palette itself on Esc / row commit.
    /// Driven out of `AppModel` rather than `MainShell` so the overlay can
    /// sit above every screen (Home, Library, Now Playing, and the auth
    /// sheet's host) from one place, and so the menu command doesn't need a
    /// SwiftUI `@Environment(AppModel.self)` round-trip. See #305 / #306 /
    /// #307 / #309.
    var isCommandPaletteOpen: Bool = false

    /// A single verb entry in the command palette's action list. See
    /// `paletteActions` for the live roster and `executePaletteAction(id:)`
    /// for the dispatcher. Actions are intentionally held by id + closure
    /// rather than by enum so the registry can grow without rippling
    /// through view code. See #307.
    struct PaletteAction: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let symbol: String
        let run: () -> Void
    }

    /// Static verb list surfaced by the command palette. Computed so the
    /// play/pause entry swaps labels based on the current playback state —
    /// re-evaluated on every palette render since the model publishes
    /// `status` changes. See #307.
    var paletteActions: [PaletteAction] {
        let isPlaying = status.state == .playing
        let hasTrack = status.currentTrack != nil
        var actions: [PaletteAction] = []

        // Transport. "Play" / "Pause" swap so the user sees the action that
        // actually fires rather than a generic "Toggle Play/Pause".
        if hasTrack {
            if isPlaying {
                actions.append(PaletteAction(
                    id: "playback.pause",
                    title: "Pause",
                    symbol: "pause.fill",
                    run: { [weak self] in self?.pause() }
                ))
            } else {
                actions.append(PaletteAction(
                    id: "playback.play",
                    title: "Play",
                    symbol: "play.fill",
                    run: { [weak self] in self?.togglePlayPause() }
                ))
            }
        } else {
            // No loaded track — still surface "Play" so ⌘K → Play has a
            // landing pad (it's a no-op until a track is loaded). Using
            // `togglePlayPause` keeps the behavior consistent with the
            // Space-bar shortcut (both no-op in this state).
            actions.append(PaletteAction(
                id: "playback.play",
                title: "Play",
                symbol: "play.fill",
                run: { [weak self] in self?.togglePlayPause() }
            ))
        }
        actions.append(PaletteAction(
            id: "playback.playNext",
            title: "Play Next",
            symbol: "text.line.first.and.arrowtriangle.forward",
            run: { [weak self] in
                guard let track = self?.status.currentTrack else { return }
                self?.playNext(tracks: [track])
            }
        ))
        actions.append(PaletteAction(
            id: "playback.addToQueue",
            title: "Add to Queue",
            symbol: "text.badge.plus",
            run: { [weak self] in
                guard let track = self?.status.currentTrack else { return }
                self?.addToQueue(tracks: [track])
            }
        ))

        // Navigation. Keep parity with the Go menu (⌘1 / ⌘2 / Discover).
        actions.append(PaletteAction(
            id: "nav.library",
            title: "Go to Library",
            symbol: "music.note.list",
            run: { [weak self] in self?.screen = .library }
        ))
        actions.append(PaletteAction(
            id: "nav.home",
            title: "Go to Home",
            symbol: "house",
            run: { [weak self] in self?.screen = .home }
        ))
        actions.append(PaletteAction(
            id: "nav.discover",
            title: "Go to Discover",
            symbol: "sparkles",
            run: { [weak self] in self?.goToDiscover() }
        ))

        // Preferences. macOS exposes the Settings scene through the standard
        // Application menu (⌘,); from the palette we mirror that by opening
        // the scene directly rather than routing through `screen = .settings`
        // (which is unused today).
        actions.append(PaletteAction(
            id: "app.openPreferences",
            title: "Open Preferences",
            symbol: "gearshape",
            run: {
                // `showSettingsWindow:` is the documented selector for
                // opening the Settings scene from outside a menu command.
                // Fall back to the legacy Preferences selector for older
                // macOS versions that don't respond to the newer one.
                if #available(macOS 14, *) {
                    NSApp.sendAction(
                        Selector(("showSettingsWindow:")),
                        to: nil,
                        from: nil
                    )
                } else {
                    NSApp.sendAction(
                        Selector(("showPreferencesWindow:")),
                        to: nil,
                        from: nil
                    )
                }
            }
        ))

        // Playback toggles. Shuffle / repeat state isn't yet carried on
        // `PlayerStatus` (tracked in research/02-media-integration.md), so
        // these are logging stubs for now — the palette entry still has a
        // landing pad so ⌘K discovery works before the FFI lands.
        actions.append(PaletteAction(
            id: "playback.toggleShuffle",
            title: "Toggle Shuffle",
            symbol: "shuffle",
            run: {
                // TODO(core): wire to core.setShuffle(on:) once FFI lands.
                print("[AppModel] Toggle Shuffle — not yet wired (see research/02-media-integration.md)")
            }
        ))
        actions.append(PaletteAction(
            id: "playback.toggleRepeat",
            title: "Toggle Repeat",
            symbol: "repeat",
            run: {
                // TODO(core): wire to core.setRepeatMode(_:) once FFI lands.
                print("[AppModel] Toggle Repeat — not yet wired (see research/02-media-integration.md)")
            }
        ))

        // Queue + download verbs. Both are placeholders today — the core
        // lacks a `clear_queue` primitive and the download engine hasn't
        // landed (#70). Kept in the roster so the discovery affordance
        // surfaces them; the closures are no-ops for now.
        actions.append(PaletteAction(
            id: "queue.clear",
            title: "Clear Queue",
            symbol: "trash",
            run: {
                // TODO(#282): wire to a core `clear_queue` primitive.
                print("[AppModel] Clear Queue — not yet wired (see #282)")
            }
        ))
        actions.append(PaletteAction(
            id: "download.current",
            title: "Download Current",
            symbol: "arrow.down.circle",
            run: { [weak self] in
                guard self?.status.currentTrack != nil else { return }
                // TODO(#70): wire to the download engine once it lands.
                print("[AppModel] Download Current — not yet wired (see #70)")
            }
        ))

        return actions
    }

    /// Look up a palette action by id and run it. Called by `CommandPalette`
    /// on ↩ commit. Also closes the palette on success, mirroring the
    /// "execute and dismiss" behavior users expect from Spotlight-style
    /// launchers. See #307.
    func executePaletteAction(id: String) {
        guard let action = paletteActions.first(where: { $0.id == id }) else { return }
        action.run()
        isCommandPaletteOpen = false
    }

    init() throws {
        let core = try JellifyCore(
            config: CoreConfig(dataDir: "", deviceName: "Jellify macOS")
        )
        self.core = core
        self.audio = AudioEngine(core: core)
        self.mediaSession = MediaSession()
        self.network = NetworkMonitor()
        self.serverReachability = ServerReachability()
        self.status = core.status()
        self.audio.onTrackEnded = { [weak self] in
            self?.handleTrackEnded()
        }
        // Hand the engine and the media session the things they need
        // from us *after* all stored properties are initialized. The
        // MediaSession is the single writer of MPNowPlayingInfoCenter;
        // the engine pushes state transitions to it.
        self.mediaSession.attach(delegate: self)
        self.audio.mediaSession = self.mediaSession
    }

    // MARK: - Network

    /// Re-evaluates network reachability and, if a session exists, kicks off a
    /// library refetch. Wired to the offline banner's `Retry` button.
    func retryNetwork() {
        network.retry()
        guard session != nil else { return }
        Task { await refreshLibrary() }
    }

    /// Clears the server-reachability failure counter and retries the library
    /// fetch. Wired to the server-unreachable banner's `Retry` button.
    /// Resetting up-front means the banner disappears while the user waits;
    /// if the refetch fails again, the error flow in `refreshLibrary` will
    /// re-accumulate failures and the banner will come back.
    func retryServer() {
        serverReachability.reset()
        guard session != nil else { return }
        Task { await refreshLibrary() }
    }

    // MARK: - Session

    func login(url: String, username: String, password: String) async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            let session = try await Task.detached(priority: .userInitiated) { [core] in
                try core.login(url: url, username: username, password: password)
            }.value
            self.session = session
            self.serverURL = url
            self.username = username
            self.errorMessage = nil
            startPolling()
            await refreshLibrary()
        } catch {
            self.errorMessage = "Login failed: \(error.localizedDescription)"
        }
    }

    /// Rehydrate the previous session from on-disk settings + the keychain
    /// token. Called once from `RootView.task` on cold start. No-ops when the
    /// core has nothing to restore (first launch, post-logout, etc.); in that
    /// case `RootView` falls through to `LoginView`.
    ///
    /// Silent on errors: the core's `resume_session` is best-effort, so if the
    /// local state is inconsistent we log and let the user sign in again
    /// rather than blocking the app. Library fetches against the restored
    /// session go through the regular `handleAuthError` flow, so a 401 on the
    /// first call surfaces the auth-expired sheet just like a mid-session
    /// expiry. Silent reauth is the rest of #440.
    func attemptRestoreSession() async {
        // Run at most once per AppModel lifetime. `hasAttemptedRestore`
        // flips the first time this runs so re-renders of `RootView` that
        // re-fire `.task` don't repeat the restore pass.
        guard !hasAttemptedRestore else { return }
        hasAttemptedRestore = true
        guard session == nil else {
            isRestoringSession = false
            return
        }
        defer { isRestoringSession = false }
        do {
            let restored = try await Task.detached(priority: .userInitiated) { [core] in
                try core.resumeSession()
            }.value
            guard let session = restored else { return }
            self.session = session
            self.serverURL = session.server.url
            self.username = session.user.name
            self.errorMessage = nil
            startPolling()
            await refreshLibrary()
        } catch {
            // Best-effort: leave `session == nil` so RootView renders LoginView.
            // No banner — the user sees the login form, which is already the
            // recovery path, and the library refetch after a manual sign-in
            // will noisily surface any persistent server problem.
            print("[AppModel] attemptRestoreSession failed: \(error.localizedDescription)")
        }
    }

    /// Internal guard for `attemptRestoreSession` — the restore pass should
    /// run exactly once per app lifetime. Separate from `isRestoringSession`
    /// so the UI flag can be flipped without gating re-entry, and vice-versa.
    private var hasAttemptedRestore = false

    func logout() {
        audio.stop()
        try? core.logout()
        session = nil
        albums = []
        artists = []
        tracks = []
        playlists = []
        playlistLibraryId = nil
        albumTracks = [:]
        playlistTracks = [:]
        currentPlaylistTracks = []
        pendingPlaylistRemoval = nil
        playlistDescriptions = [:]
        artistTopTracks = [:]
        recentlyPlayed = []
        forYou = []
        jumpBackIn = []
        recentlyAdded = []
        recentlyAddedDates = [:]
        quickPicks = []
        quickPicksPlayCounts = [:]
        favoriteAlbumsAll = []
        favoriteAlbumsVisible = []
        searchResults = nil
        searchQuery = ""
        instantSearchResults = .empty
        searchTask?.cancel()
        searchTask = nil
        currentTrackPeople = []
        currentTrackPeopleForId = nil
        currentLyrics = nil
        currentLyricsForId = nil
        resetPaginationState()
        stopPolling()
    }

    /// Drop the stored access token (keychain + in-memory session) without
    /// clearing the remembered server URL / username, so the user can re-auth
    /// against the same server by re-entering only their password. Called
    /// when the user taps "Sign in" on the auth-expired sheet. Note: the
    /// caller still owns toggling `authExpired` off and nilling `session`.
    ///
    /// Unlike `logout`, this goes through the core's `forget_token` which
    /// keeps `last_server_url` / `last_username` on disk for the login-form
    /// prefill and only drops the credential store token plus the id settings
    /// that key into it. So a subsequent `attemptRestoreSession` on next launch
    /// short-circuits to `None` (safe), and the form is pre-populated.
    func forgetToken() {
        audio.stop()
        try? core.forgetToken()
        albums = []
        artists = []
        tracks = []
        playlists = []
        playlistLibraryId = nil
        albumTracks = [:]
        playlistTracks = [:]
        currentPlaylistTracks = []
        pendingPlaylistRemoval = nil
        playlistDescriptions = [:]
        artistTopTracks = [:]
        recentlyPlayed = []
        forYou = []
        jumpBackIn = []
        recentlyAdded = []
        recentlyAddedDates = [:]
        quickPicks = []
        quickPicksPlayCounts = [:]
        favoriteAlbumsAll = []
        favoriteAlbumsVisible = []
        searchResults = nil
        searchQuery = ""
        instantSearchResults = .empty
        searchTask?.cancel()
        searchTask = nil
        currentTrackPeople = []
        currentTrackPeopleForId = nil
        currentLyrics = nil
        currentLyricsForId = nil
        resetPaginationState()
        stopPolling()
    }

    /// Clear all pagination counters and in-flight flags. Kept in one place
    /// so the two clear-the-session entry points (`logout`, `forgetToken`)
    /// stay in sync.
    private func resetPaginationState() {
        albumsTotal = 0
        artistsTotal = 0
        tracksTotal = 0
        playlistsTotal = 0
        recentlyPlayedTotal = 0
        searchResultsTotal = 0
        isLoadingMoreAlbums = false
        isLoadingMoreArtists = false
        isLoadingMoreTracks = false
        isLoadingMorePlaylists = false
        isLoadingMoreSearch = false
    }

    /// Flag the session as expired. The UI surfaces this via the auth-expired
    /// modal in `MainShell`. Idempotent — second hits within a session are
    /// no-ops while the prompt is still visible.
    func markAuthExpired() {
        guard !authExpired else { return }
        audio.stop()
        stopPolling()
        authExpired = true
    }

    /// Inspect an error from a core call and, if it looks like a 401 or the
    /// core's `NotAuthenticated` variant, mark the session expired and return
    /// `true` so the caller knows to skip its generic error surfacing.
    ///
    /// `JellifyError` is a `flat_error` in uniffi, so on the Swift side we
    /// only get the `thiserror` Display string. The variants we care about
    /// are:
    /// - `NotAuthenticated` → `"not logged in"`
    /// - `Server { status: 401, .. }` → `"server returned an error: 401 ..."`
    private func handleAuthError(_ error: Error) -> Bool {
        let description = error.localizedDescription
        let isNotAuthenticated = description.contains("not logged in")
        let isServer401 = description.contains("server returned an error: 401")
        guard isNotAuthenticated || isServer401 else { return false }
        markAuthExpired()
        return true
    }

    // MARK: - Library

    func refreshLibrary() async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        // Fetch albums, artists, tracks, and playlists in parallel. Previously
        // the album/artist calls were sequential, doubling time-to-first-paint
        // on every fresh session; `async let` lets all round-trips overlap.
        // Playlists are wired in alongside so switching to the Playlists chip
        // doesn't trigger a first-paint spinner. The smaller
        // `libraryInitialPageSize` (100 vs. the old 200) is a further
        // first-paint win — the grid fills the viewport with 100 and the
        // per-tab `loadMore*` paths take over when the user scrolls.
        //
        // Playlists go through their own try/catch because the library id
        // resolution can fail independently (no playlist library on the
        // server, or an error from a hypothetical future `core.libraries()`)
        // and we don't want that to sink the albums/artists/tracks fetch.
        async let albumsPage = Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
            try core.listAlbums(offset: 0, limit: libraryInitialPageSize)
        }.value
        async let artistsPage = Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
            try core.listArtists(offset: 0, limit: libraryInitialPageSize)
        }.value
        async let tracksPage = Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
            try core.listTracks(musicLibraryId: nil, offset: 0, limit: libraryInitialPageSize)
        }.value
        async let playlistsResult: Void = refreshPlaylists()
        do {
            let (albums, artists, tracks) = try await (albumsPage, artistsPage, tracksPage)
            self.albums = albums.items
            self.albumsTotal = albums.totalCount
            self.artists = artists.items
            self.artistsTotal = artists.totalCount
            self.tracks = tracks.items
            self.tracksTotal = tracks.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = "Library load failed: \(error.localizedDescription)"
        }
        _ = await playlistsResult
        await refreshRecentlyPlayed()
        await refreshForYou()
        // Home screen carousels (#49 / #51–#55). Kicked off after the main
        // library so first paint isn't blocked on these secondary shelves.
        // Each of these is best-effort — empty or errored rows just hide in
        // the Home layout.
        await refreshJumpBackIn()
        await refreshRecentlyAdded()
        await refreshQuickPicks()
        await refreshFavoriteAlbums()
    }

    /// Fetch the next page of albums and append to `albums`. No-op when a
    /// page is already in flight or when the local count has caught up to
    /// `albumsTotal`. Called from `LibraryView`'s near-end `.onAppear`
    /// trigger — see `LibraryView.swift`.
    func loadMoreAlbums() async {
        guard !isLoadingMoreAlbums else { return }
        guard albumsTotal == 0 || albums.count < Int(albumsTotal) else { return }
        isLoadingMoreAlbums = true
        defer { isLoadingMoreAlbums = false }
        let offset = UInt32(albums.count)
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryPageSize] in
                try core.listAlbums(offset: offset, limit: libraryPageSize)
            }.value
            self.albums.append(contentsOf: page.items)
            self.albumsTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = "Library load failed: \(error.localizedDescription)"
        }
    }

    /// Fetch the next page of artists and append to `artists`. Mirror of
    /// `loadMoreAlbums` — see its docs for the trigger contract.
    func loadMoreArtists() async {
        guard !isLoadingMoreArtists else { return }
        guard artistsTotal == 0 || artists.count < Int(artistsTotal) else { return }
        isLoadingMoreArtists = true
        defer { isLoadingMoreArtists = false }
        let offset = UInt32(artists.count)
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryPageSize] in
                try core.listArtists(offset: offset, limit: libraryPageSize)
            }.value
            self.artists.append(contentsOf: page.items)
            self.artistsTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = "Library load failed: \(error.localizedDescription)"
        }
    }

    /// Refetch the first page of library tracks for the All Tracks tab.
    /// Called from `refreshLibrary` (inline as an `async let`) on session
    /// establishment, and available for an explicit retry path later.
    /// Matches `refreshRecentlyPlayed` in shape — stores items + total.
    func refreshTracks() async {
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
                try core.listTracks(musicLibraryId: nil, offset: 0, limit: libraryInitialPageSize)
            }.value
            self.tracks = page.items
            self.tracksTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = "Library load failed: \(error.localizedDescription)"
        }
    }

    /// Fetch the next page of tracks and append to `tracks`. Mirror of
    /// `loadMoreAlbums` — see its docs for the trigger contract.
    func loadMoreTracks() async {
        guard !isLoadingMoreTracks else { return }
        guard tracksTotal == 0 || tracks.count < Int(tracksTotal) else { return }
        isLoadingMoreTracks = true
        defer { isLoadingMoreTracks = false }
        let offset = UInt32(tracks.count)
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryPageSize] in
                try core.listTracks(musicLibraryId: nil, offset: offset, limit: libraryPageSize)
            }.value
            self.tracks.append(contentsOf: page.items)
            self.tracksTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = "Library load failed: \(error.localizedDescription)"
        }
    }

    /// Resolve (and cache) the `ParentId` to scope playlist queries by.
    ///
    /// Jellyfin exposes playlists under a dedicated "Playlists"
    /// CollectionFolder, but the core doesn't yet ship an FFI for listing a
    /// user's libraries (tracked alongside #124 / #483). Until it does, we
    /// fall back to the empty string: Jellyfin's `/Items` endpoint treats an
    /// empty `ParentId` query value as "no filter", which returns the
    /// server-wide set of playlists the user can see. That's slightly
    /// broader than what the eventual proper resolve will return, but the
    /// client-side `Path`-based filter in `user_playlists` / `public_playlists`
    /// keeps the result correct.
    ///
    /// Logs a warning on first resolve so the gap is visible in Console.app.
    private func ensurePlaylistLibraryId() -> String {
        if let cached = playlistLibraryId { return cached }
        // TODO: wire `core.libraries()` (tracked in core followup) so we can
        // pick the CollectionFolder with `CollectionType == "playlists"`.
        print("[AppModel] No playlist-library resolver available — falling back to empty ParentId. This returns the correct set for typical Jellyfin servers; wire core.libraries() when it lands.")
        let resolved = ""
        playlistLibraryId = resolved
        return resolved
    }

    /// Fetch the first page of user-owned playlists for the Library screen's
    /// Playlists chip. Wired into `refreshLibrary` so the chip is populated
    /// before the user clicks it. Parallels `loadMoreAlbums` for the error
    /// / auth / reachability story.
    ///
    /// Uses `user_playlists` (user-owned) rather than `public_playlists`. The
    /// Playlists tab spec (#212) describes "your playlists"; a separate
    /// "Community" affordance for public playlists is a future concern.
    func refreshPlaylists() async {
        let libraryId = ensurePlaylistLibraryId()
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
                try core.userPlaylists(
                    playlistLibraryId: libraryId,
                    offset: 0,
                    limit: libraryInitialPageSize
                )
            }.value
            self.playlists = page.items
            self.playlistsTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            // Silent-ish: don't clobber the albums/artists error banner if
            // both fail in the same refresh. The Playlists tab empty state
            // already explains "nothing to see here" when `playlists` is
            // empty.
            print("[AppModel] refreshPlaylists failed: \(error.localizedDescription)")
        }
    }

    /// Fetch the next page of playlists and append to `playlists`. Mirror
    /// of `loadMoreAlbums` — see its docs for the trigger contract.
    ///
    /// Server-side total caveat: `user_playlists` filters results client-
    /// side by `Path`, so `playlistsTotal` is an upper bound on the raw
    /// server count, not on `playlists.count`. The `<` guard below uses the
    /// raw total deliberately — stopping at `playlists.count >= total` is
    /// safe even when the two drift, because the server itself won't return
    /// more items past its total and we'd bail on an empty page anyway.
    func loadMorePlaylists() async {
        guard !isLoadingMorePlaylists else { return }
        guard playlistsTotal == 0 || playlists.count < Int(playlistsTotal) else { return }
        isLoadingMorePlaylists = true
        defer { isLoadingMorePlaylists = false }
        let libraryId = ensurePlaylistLibraryId()
        let offset = UInt32(playlists.count)
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, libraryPageSize] in
                try core.userPlaylists(
                    playlistLibraryId: libraryId,
                    offset: offset,
                    limit: libraryPageSize
                )
            }.value
            self.playlists.append(contentsOf: page.items)
            self.playlistsTotal = page.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = "Playlists load failed: \(error.localizedDescription)"
        }
    }

    /// Fetch the user's recently played tracks for the Home screen carousel
    /// (#206). Passes `nil` for the music library id so the core returns
    /// tracks across all music libraries the user can see. Failures are
    /// swallowed silently — an empty carousel is preferable to an error
    /// banner for a best-effort Home widget.
    ///
    /// Stores `totalCount` alongside the page so a future "See all" view can
    /// expand the carousel without issuing another count query.
    func refreshRecentlyPlayed() async {
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, recentlyPlayedInitialPageSize] in
                try core.recentlyPlayed(
                    musicLibraryId: nil,
                    offset: 0,
                    limit: recentlyPlayedInitialPageSize
                )
            }.value
            self.recentlyPlayed = page.items
            self.recentlyPlayedTotal = page.totalCount
        } catch {
            // Silent fallback — don't surface errors for a secondary widget.
            _ = handleAuthError(error)
        }
    }

    /// Load ALL tracks on a playlist by paging through `playlist_tracks` in
    /// chunks of `playlistPageSize` until `totalCount` is reached or the
    /// `playlistSafetyCap` is hit. Returns as soon as any page fails. No UI
    /// wiring calls this yet (playlist detail screen is #313 et al), but the
    /// FFI is now paginated so the caller that lands it can rely on "pass
    /// this a playlist id and get every track". See #125 / #429.
    func loadAllPlaylistTracks(playlistID: String) async -> [Track] {
        var all: [Track] = []
        var offset: UInt32 = 0
        let limit = playlistPageSize
        let cap = playlistSafetyCap
        do {
            while all.count < cap {
                let page = try await Task.detached(priority: .userInitiated) { [core] in
                    try core.playlistTracks(
                        playlistId: playlistID,
                        offset: offset,
                        limit: limit
                    )
                }.value
                all.append(contentsOf: page.items)
                if page.items.isEmpty { break }
                if all.count >= Int(page.totalCount) { break }
                offset = UInt32(all.count)
            }
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return all }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = "Playlist load failed: \(error.localizedDescription)"
        }
        return all
    }

    /// Refresh the Discover "For You" carousel (#249). Until the core exposes
    /// a real recommendations endpoint (e.g. Jellyfin Items/Suggestions or a
    /// client-side "artists similar to top-3 played, minus already-played"
    /// algorithm per research/06-screen-specs.md), this is a best-effort
    /// stub that mirrors the first 20 recently played tracks so the shelf is
    /// never empty for an active listener. If `recentlyPlayed` is empty the
    /// carousel hides itself rather than showing nothing-of-interest.
    ///
    /// TODO: replace this stub with a real `core.recommendations(limit: 20)`
    /// FFI call once it lands. At that point the view layer stays unchanged —
    /// only the body of this method needs swapping.
    func refreshForYou() async {
        // Best-effort fallback: reuse the recently played tracks we already
        // fetched. Capped at 20 so the carousel stays tight even if the core
        // later starts returning a longer list.
        self.forYou = Array(recentlyPlayed.prefix(20))
    }

    // MARK: - Home carousels (#49 / #51–#55)
    //
    // The Home carousels (#51 Jump Back In, #52 Recently Played, #53 Quick
    // Picks, #54 Recently Added, #55 Favorites) each need an `/Items` query
    // with a different `SortBy` / `Filters` combination. The core exposes
    // `list_albums` / `latest_albums` / `recently_played` for the
    // un-filtered variants, but the three new album-level shelves
    // (Jump Back In, Quick Picks, Favorites) rely on filter knobs the
    // core's current FFI doesn't expose. Rather than block Home on a new
    // `items_query` builder (BATCH-24), we inline the raw HTTP call here
    // via the session URL + `auth_header` and parse the subset of
    // `BaseItemDto` we care about. Swap to the typed builder when it lands.
    //
    // TODO(core-#465): retire these raw fetches in favour of a typed
    //   `core.items_query()` builder once it exists.

    /// Refresh the "Jump Back In" carousel (#51). Fetches up to 12 albums
    /// the user has played recently, sorted by `DatePlayed` descending and
    /// filtered to `IsPlayed`. Silent on error — an empty shelf is a fine
    /// first-time-user state.
    func refreshJumpBackIn() async {
        let albums = await fetchAlbumsViaItemsQuery(
            sortBy: "DatePlayed",
            filters: "IsPlayed",
            limit: 12,
            extraFields: [],
            minDateLastSaved: nil
        )
        self.jumpBackIn = albums
    }

    /// Refresh the "Recently Added" carousel (#54). Uses the core's
    /// `latest_albums` FFI, which is already backed by Jellyfin's
    /// `/Users/{id}/Items/Latest` endpoint. Falls back to the empty
    /// `library_id` convention already used elsewhere (see
    /// `ensurePlaylistLibraryId`) until a real library resolver lands.
    /// Also parses `DateCreated` off the server so the tile can surface a
    /// "NEW" badge for albums created in the last 7 days.
    func refreshRecentlyAdded() async {
        // TODO(core-#465): the typed `latest_albums` FFI returns
        //   `PaginatedAlbums` without the `DateCreated` field that drives
        //   the NEW badge. Until the core surfaces that directly, fetch
        //   the same shape via `/Users/{id}/Items/Latest` and pull both
        //   the album list + per-item `DateCreated` out of one response.
        let (albums, dates) = await fetchLatestAlbumsWithDates(limit: 20)
        self.recentlyAdded = albums
        self.recentlyAddedDates = dates
    }

    /// Refresh the "Quick Picks" carousel (#53). Heavy-rotation albums
    /// over the last 30 days, sorted by `PlayCount` descending. The core
    /// doesn't yet expose a `min_date_played` filter, so this is an
    /// inlined `/Items` fetch. Also records per-album play counts so the
    /// tile can surface a "42 plays" badge on hover.
    func refreshQuickPicks() async {
        // Jellyfin doesn't ship a "date played > X" filter, but the
        // `MinDateLastSaved` parameter on /Items is a reasonable proxy —
        // it gates on "last touched by the user", which for our purposes
        // (filtering out stale top-played ancient history) lines up well.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let thirtyDaysAgo = Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
        let minDate = iso.string(from: thirtyDaysAgo)
        let (albums, playCounts) = await fetchAlbumsWithPlayCounts(
            sortBy: "PlayCount,SortName",
            filters: "IsPlayed",
            limit: 12,
            minDateLastSaved: minDate
        )
        self.quickPicks = albums
        self.quickPicksPlayCounts = playCounts
    }

    /// Refresh the "Favorites" carousel (#55). Fetches up to 50 favorite
    /// albums, stores the full set, and picks a random 12 to surface
    /// today. Re-shuffles whenever this is called — which happens on
    /// login, on an explicit pull-to-refresh, or on app relaunch.
    func refreshFavoriteAlbums() async {
        let albums = await fetchAlbumsViaItemsQuery(
            sortBy: "SortName",
            filters: "IsFavorite",
            limit: 50,
            extraFields: [],
            minDateLastSaved: nil
        )
        self.favoriteAlbumsAll = albums
        self.favoriteAlbumsVisible = Array(albums.shuffled().prefix(12))
        // Hydrate the per-id favorite map so album detail / tile hearts are
        // correct from first paint without waiting for the user to toggle.
        for album in albums {
            favoriteById[album.id] = true
        }
    }

    /// Re-shuffle `favoriteAlbumsVisible` from the already-fetched
    /// `favoriteAlbumsAll`. Cheaper than a full refresh — used by the "see
    /// all" / reshuffle affordance when we want a new set without hitting
    /// the server.
    func reshuffleFavoriteAlbumsVisible() {
        self.favoriteAlbumsVisible = Array(favoriteAlbumsAll.shuffled().prefix(12))
    }

    /// Load every favorite track on the server and play them shuffled.
    /// Powers the "Shuffle All Favorites" CTA on the Home favorites header
    /// (#55). Fetches up to 500 favorite tracks in one shot — that's an
    /// order of magnitude above the typical power-user favorite library
    /// and more than enough to seed a shuffled listening session.
    func shuffleAllFavorites() {
        Task {
            let tracks = await fetchFavoriteTracks(limit: 500)
            guard !tracks.isEmpty else {
                // Silent no-op if the user has nothing favorited yet — the
                // empty state in the Favorites header explains how to
                // start favoriting.
                return
            }
            play(tracks: tracks.shuffled(), startIndex: 0)
        }
    }

    /// Navigate to the full library scoped to favorites (#55 "See All").
    /// The library view doesn't yet carry a "filter to favorites" chip
    /// (tracked alongside the filter UI in a future library polish pass),
    /// so this just routes the user to the library for now. The view
    /// accepts additional filters once the chip row grows one.
    func showAllFavorites() {
        // TODO(library-filter): once the library chip row supports a
        //   "Favorites" filter, route here with the filter pre-selected.
        screen = .library
    }

    /// Shared helper: build a `GET /Items` request against the user's
    /// library with the given `sortBy` / `filters`, parse the response,
    /// and return a typed array of `Album`. Returns an empty array on
    /// any failure (auth, network, parse) so callers can stay
    /// conditionally-rendering shelves without an error-banner code path.
    ///
    /// TODO(core-#465): replace with a typed `core.items_query()` builder
    ///   once that FFI exists. This function's surface lines up
    ///   deliberately with the shape that builder will expose.
    private func fetchAlbumsViaItemsQuery(
        sortBy: String,
        filters: String?,
        limit: UInt32,
        extraFields: [String],
        minDateLastSaved: String?
    ) async -> [Album] {
        guard let request = buildItemsQuery(
            includeItemTypes: "MusicAlbum",
            sortBy: sortBy,
            sortOrder: "Descending",
            filters: filters,
            limit: limit,
            extraFields: extraFields,
            minDateLastSaved: minDateLastSaved,
            parentId: nil
        ) else { return [] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return []
            }
            return Self.parseAlbumsFromItems(data: data)
        } catch {
            print("[AppModel] fetchAlbumsViaItemsQuery failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Like `fetchAlbumsViaItemsQuery` but also returns a map from album
    /// id to the server-reported `UserData.PlayCount` so "N plays" can
    /// render on the Quick Picks tile.
    private func fetchAlbumsWithPlayCounts(
        sortBy: String,
        filters: String?,
        limit: UInt32,
        minDateLastSaved: String?
    ) async -> ([Album], [String: UInt32]) {
        guard let request = buildItemsQuery(
            includeItemTypes: "MusicAlbum",
            sortBy: sortBy,
            sortOrder: "Descending",
            filters: filters,
            limit: limit,
            extraFields: [],
            minDateLastSaved: minDateLastSaved,
            parentId: nil
        ) else { return ([], [:]) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return ([], [:])
            }
            return Self.parseAlbumsWithPlayCounts(data: data)
        } catch {
            print("[AppModel] fetchAlbumsWithPlayCounts failed: \(error.localizedDescription)")
            return ([], [:])
        }
    }

    /// Fetch Recently Added via `/Users/{id}/Items/Latest`. Returns both
    /// the album array and a per-album `DateCreated` map (used by the NEW
    /// badge on `RecentlyAddedTile`).
    private func fetchLatestAlbumsWithDates(limit: UInt32) async -> ([Album], [String: Date]) {
        guard let session = session,
              let baseURL = URL(string: session.server.url),
              let authHeader = try? core.authHeader()
        else { return ([], [:]) }
        let userId = session.user.id
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("Users/\(userId)/Items/Latest"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "GroupItems", value: "true"),
            URLQueryItem(
                name: "Fields",
                value: "Genres,ProductionYear,DateCreated,ChildCount,PrimaryImageAspectRatio"
            ),
        ]
        guard let url = comps?.url else { return ([], [:]) }
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return ([], [:])
            }
            // `/Items/Latest` returns a bare array, not the
            // `{Items, TotalRecordCount}` wrapper — parse accordingly.
            return Self.parseLatestAlbumsWithDates(data: data)
        } catch {
            print("[AppModel] fetchLatestAlbumsWithDates failed: \(error.localizedDescription)")
            return ([], [:])
        }
    }

    /// Fetch up to `limit` favorited audio tracks. Backs the
    /// "Shuffle All Favorites" CTA on the Home Favorites header (#55).
    private func fetchFavoriteTracks(limit: UInt32) async -> [Track] {
        guard let request = buildItemsQuery(
            includeItemTypes: "Audio",
            sortBy: "Random",
            sortOrder: "Ascending",
            filters: "IsFavorite",
            limit: limit,
            extraFields: [],
            minDateLastSaved: nil,
            parentId: nil
        ) else { return [] }
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
                markAuthExpired()
                return []
            }
            return Self.parseTracksFromItems(data: data)
        } catch {
            print("[AppModel] fetchFavoriteTracks failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Build an authenticated `GET /Items` request against the current
    /// session's server. Returns `nil` when there is no session or the
    /// core refuses to hand out an auth header. Keeps the URL
    /// construction boilerplate in one place so each caller can just
    /// specify the filter knobs it cares about.
    private func buildItemsQuery(
        includeItemTypes: String,
        sortBy: String,
        sortOrder: String,
        filters: String?,
        limit: UInt32,
        extraFields: [String],
        minDateLastSaved: String?,
        parentId: String?
    ) -> URLRequest? {
        guard let session = session,
              let baseURL = URL(string: session.server.url),
              let authHeader = try? core.authHeader()
        else { return nil }
        let userId = session.user.id
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("Users/\(userId)/Items"),
            resolvingAgainstBaseURL: false
        )
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: includeItemTypes),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(
                name: "Fields",
                value: (["Genres", "ProductionYear", "ChildCount", "PrimaryImageAspectRatio", "UserData"] + extraFields)
                    .joined(separator: ",")
            ),
        ]
        if let filters, !filters.isEmpty {
            queryItems.append(URLQueryItem(name: "Filters", value: filters))
        }
        if let minDateLastSaved {
            queryItems.append(URLQueryItem(name: "MinDateLastSaved", value: minDateLastSaved))
        }
        if let parentId, !parentId.isEmpty {
            queryItems.append(URLQueryItem(name: "ParentId", value: parentId))
        }
        comps?.queryItems = queryItems
        guard let url = comps?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Parse the `{ Items: [...], TotalRecordCount: ... }` envelope
    /// Jellyfin returns for `/Users/{id}/Items` into our typed `Album`
    /// array. Only the fields `Album` carries are extracted; everything
    /// else is dropped. Returns `[]` on any parse failure.
    private static func parseAlbumsFromItems(data: Data) -> [Album] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["Items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { Self.albumFromDTO($0) }
    }

    /// Like `parseAlbumsFromItems` but also extracts `UserData.PlayCount`
    /// per item into the returned map.
    private static func parseAlbumsWithPlayCounts(data: Data) -> ([Album], [String: UInt32]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["Items"] as? [[String: Any]]
        else { return ([], [:]) }
        var albums: [Album] = []
        var plays: [String: UInt32] = [:]
        for entry in items {
            guard let album = Self.albumFromDTO(entry) else { continue }
            albums.append(album)
            if let userData = entry["UserData"] as? [String: Any],
               let playCount = userData["PlayCount"] as? Int, playCount > 0 {
                plays[album.id] = UInt32(playCount)
            }
        }
        return (albums, plays)
    }

    /// Parse the bare `BaseItemDto[]` response from
    /// `/Users/{id}/Items/Latest` into an album list + per-album
    /// `DateCreated` map. The NEW badge on `RecentlyAddedTile` reads the
    /// date map.
    private static func parseLatestAlbumsWithDates(data: Data) -> ([Album], [String: Date]) {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return ([], [:]) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var albums: [Album] = []
        var dates: [String: Date] = [:]
        for entry in items {
            guard let album = Self.albumFromDTO(entry) else { continue }
            albums.append(album)
            if let raw = entry["DateCreated"] as? String {
                if let d = iso.date(from: raw) {
                    dates[album.id] = d
                } else {
                    iso.formatOptions = [.withInternetDateTime]
                    if let d = iso.date(from: raw) {
                        dates[album.id] = d
                    }
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                }
            }
        }
        return (albums, dates)
    }

    /// Parse a Jellyfin `BaseItemDto` (from a `/Items` response) into the
    /// typed `Album` the core produces. Returns `nil` when the minimum
    /// required fields (`Id`, `Name`) aren't present so we don't render
    /// blank tiles.
    private static func albumFromDTO(_ entry: [String: Any]) -> Album? {
        guard
            let id = (entry["Id"] as? String)?.trimmingCharacters(in: .whitespaces),
            !id.isEmpty,
            let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        else { return nil }
        let artistName = (entry["AlbumArtist"] as? String)
            ?? (entry["Artists"] as? [String])?.first
            ?? ""
        let artistId: String? = {
            if let id = entry["AlbumArtistId"] as? String, !id.isEmpty { return id }
            if let items = entry["AlbumArtists"] as? [[String: Any]],
               let first = items.first,
               let id = first["Id"] as? String, !id.isEmpty { return id }
            return nil
        }()
        let year: Int32? = {
            if let y = entry["ProductionYear"] as? Int, y > 0 { return Int32(y) }
            return nil
        }()
        let trackCount: UInt32 = {
            if let c = entry["ChildCount"] as? Int, c >= 0 { return UInt32(c) }
            return 0
        }()
        let runtimeTicks: UInt64 = {
            if let t = entry["RunTimeTicks"] as? Int64, t >= 0 { return UInt64(t) }
            if let t = entry["RunTimeTicks"] as? Int, t >= 0 { return UInt64(t) }
            return 0
        }()
        let genres: [String] = (entry["Genres"] as? [String]) ?? []
        let imageTag: String? = {
            if let tags = entry["ImageTags"] as? [String: String],
               let primary = tags["Primary"], !primary.isEmpty { return primary }
            return nil
        }()
        return Album(
            id: id,
            name: name,
            artistName: artistName,
            artistId: artistId,
            year: year,
            trackCount: trackCount,
            runtimeTicks: runtimeTicks,
            genres: genres,
            imageTag: imageTag
        )
    }

    /// Parse the `{ Items: [...] }` envelope into typed `Track` values.
    /// Mirrors `parseAlbumsFromItems` but targets audio tracks — used by
    /// `fetchFavoriteTracks` for the Shuffle All Favorites CTA.
    private static func parseTracksFromItems(data: Data) -> [Track] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["Items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { Self.trackFromDTO($0) }
    }

    /// Turn a `BaseItemDto` (audio track) into the typed `Track` record.
    /// Returns `nil` on missing `Id`/`Name` so blank rows don't land in
    /// the shuffle queue.
    private static func trackFromDTO(_ entry: [String: Any]) -> Track? {
        guard
            let id = (entry["Id"] as? String)?.trimmingCharacters(in: .whitespaces),
            !id.isEmpty,
            let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        else { return nil }
        let albumId = (entry["AlbumId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let albumName = (entry["Album"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let artistName = (entry["AlbumArtist"] as? String)
            ?? (entry["Artists"] as? [String])?.first
            ?? ""
        let artistId: String? = {
            if let items = entry["ArtistItems"] as? [[String: Any]],
               let first = items.first,
               let id = first["Id"] as? String, !id.isEmpty { return id }
            if let items = entry["AlbumArtists"] as? [[String: Any]],
               let first = items.first,
               let id = first["Id"] as? String, !id.isEmpty { return id }
            return nil
        }()
        let indexNumber: UInt32? = {
            if let n = entry["IndexNumber"] as? Int, n > 0 { return UInt32(n) }
            return nil
        }()
        let discNumber: UInt32? = {
            if let n = entry["ParentIndexNumber"] as? Int, n > 0 { return UInt32(n) }
            return nil
        }()
        let year: Int32? = {
            if let y = entry["ProductionYear"] as? Int, y > 0 { return Int32(y) }
            return nil
        }()
        let runtimeTicks: UInt64 = {
            if let t = entry["RunTimeTicks"] as? Int64, t >= 0 { return UInt64(t) }
            if let t = entry["RunTimeTicks"] as? Int, t >= 0 { return UInt64(t) }
            return 0
        }()
        let userData = entry["UserData"] as? [String: Any]
        let isFavorite = (userData?["IsFavorite"] as? Bool) ?? false
        let playCount: UInt32 = {
            if let c = userData?["PlayCount"] as? Int, c > 0 { return UInt32(c) }
            return 0
        }()
        let container = (entry["Container"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let bitrate: UInt32? = {
            if let b = entry["Bitrate"] as? Int, b > 0 { return UInt32(b) }
            return nil
        }()
        let imageTag: String? = {
            if let tags = entry["ImageTags"] as? [String: String],
               let primary = tags["Primary"], !primary.isEmpty { return primary }
            return nil
        }()
        return Track(
            id: id,
            name: name,
            albumId: albumId,
            albumName: albumName,
            artistName: artistName,
            artistId: artistId,
            indexNumber: indexNumber,
            discNumber: discNumber,
            year: year,
            runtimeTicks: runtimeTicks,
            isFavorite: isFavorite,
            playCount: playCount,
            container: container,
            bitrate: bitrate,
            imageTag: imageTag
        )
    }

    func loadTracks(forAlbum albumID: String) async -> [Track] {
        if let cached = albumTracks[albumID] { return cached }
        do {
            let tracks = try await Task.detached(priority: .userInitiated) { [core] in
                try core.albumTracks(albumId: albumID)
            }.value
            albumTracks[albumID] = tracks
            serverReachability.noteSuccess()
            return tracks
        } catch {
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = "Album tracks failed: \(error.localizedDescription)"
            return []
        }
    }

    /// Fetch the top 5 most-played tracks for an artist, driving the
    /// "Top Tracks" section on the artist detail screen (#229). Backed by
    /// `/Items?ArtistIds=<id>&SortBy=PlayCount,SortName&SortOrder=Descending,Ascending`
    /// on the server. Results are cached per-artist for the session. Errors
    /// are swallowed silently — an empty section is preferable to an error
    /// banner for a secondary widget on the artist page.
    @discardableResult
    func loadArtistTopTracks(artistId: String, limit: UInt32 = 5) async -> [Track] {
        if let cached = artistTopTracks[artistId] { return cached }
        do {
            let tracks = try await Task.detached(priority: .userInitiated) { [core] in
                try core.artistTopTracks(artistId: artistId, limit: limit)
            }.value
            artistTopTracks[artistId] = tracks
            serverReachability.noteSuccess()
            return tracks
        } catch {
            // Silent fallback — don't surface errors for a secondary widget.
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            return []
        }
    }

    /// Fetch the ordered tracks for a playlist, preserving the server-side
    /// playlist order. Mirrors `loadTracks(forAlbum:)` — results are cached
    /// for the session, scoped to `playlistTracks[playlist.id]`. Backed by
    /// `JellifyCore.playlistTracks` (core's `playlist_tracks`, see #125).
    ///
    /// We ask for up to 500 entries, which covers the vast majority of
    /// playlists; paging the tail is a follow-up alongside virtualization of
    /// the track list itself (see #234's spec — the hero ships first, the
    /// long-playlist scroll optimization is a later polish pass).
    @discardableResult
    func loadPlaylistTracks(playlist: Playlist) async -> [Track] {
        if let cached = playlistTracks[playlist.id] { return cached }
        do {
            let playlistID = playlist.id
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.playlistTracks(playlistId: playlistID, offset: 0, limit: 500)
            }.value
            let tracks = page.items
            playlistTracks[playlist.id] = tracks
            serverReachability.noteSuccess()
            return tracks
        } catch {
            if handleAuthError(error) { return [] }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = "Playlist tracks failed: \(error.localizedDescription)"
            return []
        }
    }

    /// Look up a cached `Playlist` by id. Returns `nil` if no upstream surface
    /// has inserted one — the caller (`PlaylistView`) renders a minimal
    /// fallback in that case until playlist listing lands (#220).
    func playlist(id: String) -> Playlist? {
        playlists.first { $0.id == id }
    }

    /// Load the ordered track list for `playlistId` and publish it on
    /// `currentPlaylistTracks` so `PlaylistDetailView` can drive its list and
    /// multi-select surface off a single observable array. See #74 / #236.
    ///
    /// Hits the keyed `playlistTracks` cache first so switching back to a
    /// playlist you just left is instant. On a miss, delegates to
    /// `core.playlistTracks(playlistId:)` for up to 500 entries — same cap as
    /// `loadPlaylistTracks(playlist:)`. Errors surface through the usual
    /// auth / reachability / error-banner path.
    func loadPlaylistTracks(playlistId: String) async {
        if let cached = playlistTracks[playlistId] {
            currentPlaylistTracks = cached
            return
        }
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core] in
                try core.playlistTracks(playlistId: playlistId, offset: 0, limit: 500)
            }.value
            playlistTracks[playlistId] = page.items
            currentPlaylistTracks = page.items
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = "Playlist tracks failed: \(error.localizedDescription)"
        }
    }

    /// Remove tracks from a playlist by entry id (the track id, since the
    /// core's FFI doesn't yet surface playlist-entry ids — see #128).
    ///
    /// Applied optimistically: rows disappear from `currentPlaylistTracks`
    /// and `playlistTracks[playlistId]` immediately, and the removed tracks
    /// are stashed on `pendingPlaylistRemoval` so the 10-second undo window
    /// can put them back via `undoRemoveFromPlaylist` (which routes through
    /// `core.addToPlaylist`). The real remove call is TODO(core-#128): the
    /// core doesn't yet expose `remove_from_playlist`, so the server-side
    /// state drifts until that FFI lands. Track-counts on the in-memory
    /// `Playlist` are kept consistent so the hero stat doesn't lie.
    func removeFromPlaylist(playlistId: String, entryIds: [String]) {
        guard !entryIds.isEmpty else { return }
        let removing = Set(entryIds)
        let removed = currentPlaylistTracks.filter { removing.contains($0.id) }
        guard !removed.isEmpty else { return }
        currentPlaylistTracks.removeAll { removing.contains($0.id) }
        playlistTracks[playlistId] = currentPlaylistTracks
        pendingPlaylistRemoval = PendingRemoval(
            playlistId: playlistId,
            tracks: removed
        )
        // Keep the cached `Playlist.trackCount` in sync with the optimistic
        // remove so the hero's stat matches the rendered list length.
        if let idx = playlists.firstIndex(where: { $0.id == playlistId }) {
            let p = playlists[idx]
            let newCount = max(0, Int(p.trackCount) - removed.count)
            playlists[idx] = Playlist(
                id: p.id,
                name: p.name,
                trackCount: UInt32(newCount),
                runtimeTicks: p.runtimeTicks,
                imageTag: p.imageTag
            )
        }
        // TODO(core-#128): `core.remove_from_playlist` FFI not yet wired. The
        // optimistic drop above keeps the UI responsive; the server won't
        // actually lose the entries until the FFI lands and we replace this
        // log line with the real call.
        print("[AppModel] removeFromPlaylist(\(playlistId), \(entryIds.count) tracks) local-only — see core-#128")
    }

    /// Restore a previously-removed batch by re-adding via `core.addToPlaylist`.
    /// Called from the undo toast in `PlaylistDetailView`. Clears
    /// `pendingPlaylistRemoval` on success; leaves it intact on failure so
    /// the user can retry by tapping Undo again.
    func undoRemoveFromPlaylist() {
        guard let pending = pendingPlaylistRemoval else { return }
        let ids = pending.tracks.map(\.id)
        let playlistId = pending.playlistId
        pendingPlaylistRemoval = nil
        // Optimistically re-insert so the list pops back immediately. The
        // server call below is the actual durability guarantee.
        let existingIds = Set(currentPlaylistTracks.map(\.id))
        let reinserted = pending.tracks.filter { !existingIds.contains($0.id) }
        currentPlaylistTracks.append(contentsOf: reinserted)
        playlistTracks[playlistId] = currentPlaylistTracks
        if let idx = playlists.firstIndex(where: { $0.id == playlistId }) {
            let p = playlists[idx]
            playlists[idx] = Playlist(
                id: p.id,
                name: p.name,
                trackCount: p.trackCount + UInt32(reinserted.count),
                runtimeTicks: p.runtimeTicks,
                imageTag: p.imageTag
            )
        }
        Task.detached(priority: .userInitiated) { [core] in
            try? core.addToPlaylist(playlistId: playlistId, itemIds: ids)
        }
    }

    /// Append tracks to a playlist by id. Backs the drop-to-add handler on
    /// `PlaylistDetailView` and any future "Add to playlist" affordance. See
    /// #236. Updates the in-memory caches optimistically and fires the core
    /// call in a detached task.
    func addToPlaylist(playlistId: String, trackIds: [String]) {
        guard !trackIds.isEmpty else { return }
        let ids = trackIds
        Task.detached(priority: .userInitiated) { [core] in
            try? core.addToPlaylist(playlistId: playlistId, itemIds: ids)
        }
        // Optimistically refresh the currently-loaded list so the drop
        // visually lands without waiting for the round-trip. We don't know
        // the full `Track` records for ids that aren't already resident, so
        // we only bump the count on the in-memory `Playlist` and leave the
        // list alone — a follow-up `loadPlaylistTracks` (the caller usually
        // fires one after a drop) will reconcile.
        if let idx = playlists.firstIndex(where: { $0.id == playlistId }) {
            let p = playlists[idx]
            playlists[idx] = Playlist(
                id: p.id,
                name: p.name,
                trackCount: p.trackCount + UInt32(trackIds.count),
                runtimeTicks: p.runtimeTicks,
                imageTag: p.imageTag
            )
        }
    }

    /// Navigate to the playlist detail screen. Caches the playlist so
    /// `PlaylistView` can resolve it by id. Called from the Sidebar, Home
    /// shelves, and context menus as they start linking into playlist detail
    /// (#220 / #313 follow-ups).
    func goToPlaylist(_ playlist: Playlist) {
        if !playlists.contains(where: { $0.id == playlist.id }) {
            playlists.append(playlist)
        }
        screen = .playlist(playlist.id)
    }


    /// Switch to the Search screen and request keyboard focus in the search
    /// field. Called from the ⌘F menu command. Writes both the legacy
    /// one-shot `requestSearchFocus` flag (which `SearchView` already observes)
    /// and the new `isSearchFieldFocused` mirror so toolbar / field bindings
    /// introduced by #7 can attach a `@FocusState` via `$model.isSearchFieldFocused`.
    func focusSearch() {
        screen = .search
        requestSearchFocus = true
        isSearchFieldFocused = true
    }

    /// Programmatic navigation entry point. Views that want to push a screen
    /// should prefer this over assigning `model.screen` directly so there's
    /// a single seam to add side effects (analytics, breadcrumb history, nav
    /// animations) later. Today it's a thin setter — matches the direct
    /// `model.screen = ...` pattern used elsewhere.
    ///
    /// Wired by the Artist detail page's Similar Artists tiles (BATCH-04)
    /// and available to future surfaces that want a less brittle navigation
    /// handle.
    func navigate(to screen: Screen) {
        self.screen = screen
    }

    /// Navigate to the Discover screen. See #248.
    func goToDiscover() {
        screen = .discover
    }

    /// Kick off a library-seeded Instant Mix from the Discover screen's CTA.
    /// TODO: #144 / #327 — Instant Mix (polymorphic) FFI + modal not yet
    /// wired. This is a logging stub so the UI action has a landing pad.
    func startInstantMix() {
        // TODO: #144 / #327 — Instant Mix FFI + modal not yet wired.
        print("[AppModel] startInstantMix() not yet wired — see #144 / #327")
    }

    /// Shuffle the entire library — loads tracks from a handful of random
    /// albums, interleaves them into one queue, shuffles, and plays.
    ///
    /// Powers the "Shuffle All" CTA on the Home greeting header (#204). The
    /// core doesn't expose a "list every track" primitive yet (see #465), so
    /// we draw from the albums already loaded on the Home screen and assemble
    /// a queue of up to ~200 tracks. Good enough as a "play my library"
    /// affordance until a server-side random-songs endpoint lands.
    func shuffleLibrary() {
        guard !albums.isEmpty else { return }
        Task {
            // Draw from a random sample of albums so repeat presses don't
            // always yield the same seed set. Cap the sample so we don't
            // fan-out hundreds of `albumTracks` calls in a single tap.
            let sampleSize = min(albums.count, 25)
            let sampled = Array(albums.shuffled().prefix(sampleSize))
            var collected: [Track] = []
            for album in sampled {
                let tracks = await loadTracks(forAlbum: album.id)
                collected.append(contentsOf: tracks)
                // Cap total queue length — mirrors other "play a lot" flows.
                if collected.count >= 200 { break }
            }
            guard !collected.isEmpty else { return }
            play(tracks: collected.shuffled(), startIndex: 0)
        }
    }

    func search(_ query: String) async {
        searchQuery = query
        guard !query.isEmpty else {
            searchResults = nil
            searchResultsTotal = 0
            return
        }
        do {
            let results = try await Task.detached(priority: .userInitiated) { [core, searchPageSize] in
                try core.search(query: query, offset: 0, limit: searchPageSize)
            }.value
            self.searchResults = results
            self.searchResultsTotal = results.totalRecordCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    /// Fetch the next page of the current search query and merge into
    /// `searchResults`. Jellyfin's combined-type `/Users/{id}/Items`
    /// endpoint doesn't let us fetch more of a single kind at a time, so
    /// this appends whichever of (artists, albums, tracks) the next page
    /// happens to contain. The "Show all N results" button in `SearchView`
    /// is the caller.
    ///
    /// Dedupes by id so the typed arrays don't accumulate duplicates if a
    /// row happens to overlap across paged responses (which can happen
    /// because Jellyfin's ordering is stable only per sort key).
    func loadMoreSearchResults() async {
        guard !isLoadingMoreSearch else { return }
        guard let current = searchResults, !searchQuery.isEmpty else { return }
        let loaded = current.artists.count + current.albums.count + current.tracks.count
        guard loaded < Int(searchResultsTotal) else { return }
        isLoadingMoreSearch = true
        defer { isLoadingMoreSearch = false }
        let offset = UInt32(loaded)
        let query = searchQuery
        do {
            let page = try await Task.detached(priority: .userInitiated) { [core, searchPageSize] in
                try core.search(query: query, offset: offset, limit: searchPageSize)
            }.value
            // Merge with dedupe — see method doc.
            var artistSet = Set(current.artists.map(\.id))
            var albumSet = Set(current.albums.map(\.id))
            var trackSet = Set(current.tracks.map(\.id))
            var artists = current.artists
            var albums = current.albums
            var tracks = current.tracks
            for a in page.artists where artistSet.insert(a.id).inserted { artists.append(a) }
            for a in page.albums where albumSet.insert(a.id).inserted { albums.append(a) }
            for t in page.tracks where trackSet.insert(t.id).inserted { tracks.append(t) }
            self.searchResults = SearchResults(
                artists: artists,
                albums: albums,
                tracks: tracks,
                totalRecordCount: page.totalRecordCount
            )
            self.searchResultsTotal = page.totalRecordCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    /// Debounced instant search for the dropdown shown under the toolbar
    /// search field. Cancels any previous in-flight pass, waits 250ms for
    /// more keystrokes, then hits `core.search`. On success we rank a
    /// single "top result" by exact-title > prefix > contains (ties broken
    /// by play count when available, then alpha) and split the rest into
    /// typed sections for the dropdown to render.
    ///
    /// Empty / whitespace-only queries short-circuit to `.empty` and
    /// cancel any pending fetch so the dropdown clears instantly.
    ///
    /// Spec: #85 (instant dropdown), #241 (debounced fetch), #243 (hero
    /// top result). Deliberately uses the existing `core.search` endpoint
    /// — a leaner `/Search/Hints` path is tracked separately; swapping
    /// here is a one-line change when that lands.
    func runInstantSearch(query: String) {
        // Cancel whatever was in flight — the user either typed another
        // character or cleared the field. Either way, the old result is
        // stale.
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            instantSearchResults = .empty
            searchTask = nil
            return
        }

        searchTask = Task { [weak self, core] in
            // 250ms debounce — if another keystroke fires the task is
            // cancelled before we ever hit the network.
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            if Task.isCancelled { return }

            // Instant dropdown is tuned for speed, not completeness —
            // 20 items is enough to populate every section without
            // hauling the whole "see all" page down on each keystroke.
            let results: SearchResults
            do {
                results = try await Task.detached(priority: .userInitiated) {
                    try core.search(query: trimmed, offset: 0, limit: 20)
                }.value
            } catch {
                // Instant search failures are cosmetic — the full Search
                // screen still surfaces the "real" error on submit. Swallow
                // here so a flaky network doesn't keep firing error banners
                // for every keystroke.
                return
            }
            if Task.isCancelled { return }

            guard let self else { return }
            await MainActor.run {
                let top = Self.pickTopResult(query: trimmed, results: results)
                self.instantSearchResults = InstantSearchResults(
                    topResult: top,
                    artists: results.artists,
                    albums: results.albums,
                    tracks: results.tracks,
                    // Playlists and genres are not yet surfaced by
                    // `core.search` (today it returns Audio / MusicAlbum /
                    // MusicArtist only). TODO(core): expand the search
                    // endpoint to include Playlist + MusicGenre so the
                    // instant dropdown can render those sections.
                    playlists: [],
                    genres: []
                )
            }
        }
    }

    /// Pick the single "top result" for the hero card.
    ///
    /// Ranking, strongest → weakest: exact case-insensitive title match,
    /// then prefix match, then substring match. Ties are broken by play
    /// count (only tracks carry one today) and finally by alphabetical
    /// order so the choice is deterministic across keystrokes.
    nonisolated static func pickTopResult(query: String, results: SearchResults) -> SearchItem? {
        let q = query.lowercased()
        var candidates: [SearchItem] = []
        candidates.reserveCapacity(results.artists.count + results.albums.count + results.tracks.count)
        candidates.append(contentsOf: results.artists.map(SearchItem.artist))
        candidates.append(contentsOf: results.albums.map(SearchItem.album))
        candidates.append(contentsOf: results.tracks.map(SearchItem.track))
        guard !candidates.isEmpty else { return nil }

        // Lower sort key wins. `(rank, -playCount, name)` so we can call
        // `.min(by:)` without an ad-hoc comparator per tier.
        func rank(for name: String) -> Int {
            let lower = name.lowercased()
            if lower == q { return 0 }
            if lower.hasPrefix(q) { return 1 }
            if lower.contains(q) { return 2 }
            return 3
        }

        return candidates.min { a, b in
            let ra = rank(for: a.title)
            let rb = rank(for: b.title)
            if ra != rb { return ra < rb }
            // Play count — only tracks carry one. Treat non-tracks as 0.
            let pa = a.playCount
            let pb = b.playCount
            if pa != pb { return pa > pb }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    func imageURL(for itemID: String, tag: String?, maxWidth: UInt32 = 400) -> URL? {
        guard let s = try? core.imageUrl(itemId: itemID, tag: tag, maxWidth: maxWidth) else { return nil }
        return URL(string: s)
    }

    // MARK: - Playback

    func play(tracks: [Track], startIndex: Int = 0) {
        do {
            _ = try core.setQueue(tracks: tracks, startIndex: UInt32(startIndex))
            guard let first = tracks[safe: startIndex] else { return }
            try audio.play(track: first)
            errorMessage = nil
        } catch {
            if handleAuthError(error) { return }
            errorMessage = "Couldn't start playback: \(error.localizedDescription)"
        }
    }

    func play(album: Album) {
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Shuffle an album — loads tracks, randomises order, then plays from top.
    func shuffle(album: Album) {
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks.shuffled(), startIndex: 0)
        }
    }

    /// Insert an album's tracks immediately after the currently-playing track.
    /// TODO: #282 — proper Up Next vs Auto Queue separation. For now, the core
    /// queue is replaced on every `setQueue`, so until we grow an `insertNext`
    /// primitive this falls back to appending behaviour.
    func playNext(album: Album) {
        // TODO: #282 — queue "Up Next" insertion; for now, surface a log.
        print("[AppModel] playNext(album:) not yet wired — see #282")
        Task {
            let tracks = await loadTracks(forAlbum: album.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Append an album's tracks to the end of the queue.
    /// TODO: #282 — the core lacks an `appendToQueue` primitive, so this is a
    /// stub that plays the album outright for now.
    func addToQueue(album: Album) {
        // TODO: #282 — queue append. Currently behaves like `play`.
        print("[AppModel] addToQueue(album:) not yet wired — see #282")
        play(album: album)
    }

    /// In-memory favorite flag keyed by item id (album/track/artist/playlist).
    /// Populated lazily: when the user toggles the heart on the album detail
    /// screen we record the server's authoritative return value here, and the
    /// UI reads this map rather than passing fragile per-screen state around.
    ///
    /// Not persisted across launches — the server is the source of truth and
    /// a fresh load refetches. A future #133 follow-up hydrates this from
    /// the initial library fetch so favourites show up without a per-item
    /// round-trip.
    var favoriteById: [String: Bool] = [:]

    /// Toggle the favorite flag for an album on the Jellyfin server. Reads
    /// the current state from `favoriteById` (falling back to `false` on a
    /// cold start) and calls the opposite side of `set_favorite` /
    /// `unset_favorite` on the core. The returned [`FavoriteState`] is the
    /// server's authoritative answer and is written back to `favoriteById`
    /// so the heart glyph reflects the saved state.
    ///
    /// Errors surface the generic `errorMessage` banner — a failed toggle is
    /// rare enough that swallowing it would hide real trouble (token
    /// revoked, network flapping), but not so load-bearing that we want a
    /// modal.
    func toggleFavorite(album: Album) {
        Task { await setFavorite(itemId: album.id, enabled: !isFavorite(id: album.id)) }
    }

    /// Toggle the favorite flag for a track. Same contract as
    /// `toggleFavorite(album:)` — see its doc for the state-cache semantics.
    func toggleFavorite(track: Track) {
        Task { await setFavorite(itemId: track.id, enabled: !isFavorite(id: track.id)) }
    }

    /// Check the local favorite-state cache. Returns `false` when the item
    /// hasn't been toggled this session — callers that need server truth on
    /// first paint should trigger a refetch via #133 when that lands.
    func isFavorite(id: String) -> Bool {
        favoriteById[id] ?? false
    }

    /// Internal helper — hits `set_favorite` / `unset_favorite` on the core
    /// and mirrors the server's answer into `favoriteById`. Kept private so
    /// the public API stays `toggleFavorite(...)` and the desired-state
    /// boolean is always computed at the call site.
    private func setFavorite(itemId: String, enabled: Bool) async {
        do {
            let state = try await Task.detached(priority: .userInitiated) { [core] in
                if enabled {
                    return try core.setFavorite(itemId: itemId)
                } else {
                    return try core.unsetFavorite(itemId: itemId)
                }
            }.value
            favoriteById[itemId] = state.isFavorite
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = "Favorite failed: \(error.localizedDescription)"
        }
    }

    /// Enqueue a download of every track on the album.
    /// TODO: #70, #222 — there is no download engine yet; this is a logging
    /// stub so the UI action has a landing pad.
    func enqueueDownload(album: Album) {
        // TODO: #70 / #222 — download engine not yet wired.
        print("[AppModel] enqueueDownload(album:) not yet wired — see #70 / #222")
    }

    /// Present an "Add all to playlist" destination picker.
    ///
    /// The album detail screen has its own inline popover that does the
    /// actual picking; this entry point is kept for menu-bar / context-menu
    /// callers that don't own a popover anchor. When the new
    /// `addToPlaylist(...)` helper below lands for every surface, this
    /// becomes a no-op wrapper.
    /// TODO: #72, #126 — menu-bar picker sheet for surfaces without their
    /// own popover anchor.
    func requestAddToPlaylist(album: Album) {
        // TODO: #72 / #126 — standalone picker sheet for non-popover callers.
        print("[AppModel] requestAddToPlaylist(album:) not yet wired — see #72 / #126")
    }

    /// Append a batch of tracks to an existing playlist via `add_to_playlist`
    /// on the core. Used by the album detail popover (#222) and any other
    /// caller that has already resolved a target playlist. Returns `true` on
    /// success so UI can dismiss the popover / show a confirmation tick.
    ///
    /// Errors surface on `errorMessage` rather than throwing so the popover
    /// can stay presentation-only. An empty `trackIds` short-circuits before
    /// the FFI hop since the server would reject it anyway.
    @discardableResult
    func addToPlaylist(trackIds: [String], playlistId: String) async -> Bool {
        guard !trackIds.isEmpty else { return false }
        do {
            try await Task.detached(priority: .userInitiated) { [core] in
                try core.addToPlaylist(playlistId: playlistId, itemIds: trackIds)
            }.value
            serverReachability.noteSuccess()
            return true
        } catch {
            if handleAuthError(error) { return false }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            errorMessage = "Add to playlist failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Fetch the album's hydrated detail fields (label, premiere date, and
    /// aggregated People credits) via `fetch_item`. Returned as a compact
    /// [`AlbumDetail`] value type so the view layer can render the
    /// liner-note credits section (#65) without a second parse pass.
    ///
    /// Silent on errors: the liner-note section degrades to whatever fields
    /// are present on the cached `Album` so a 404 or a stripped-down server
    /// doesn't take down the whole detail page.
    func loadAlbumDetail(albumId: String) async -> AlbumDetail {
        do {
            let json = try await Task.detached(priority: .userInitiated) { [core] in
                try core.fetchItem(
                    itemId: albumId,
                    fields: ["People", "Studios", "PremiereDate", "DateCreated", "ProductionYear"]
                )
            }.value
            return Self.parseAlbumDetail(from: json)
        } catch {
            _ = handleAuthError(error)
            return AlbumDetail(label: nil, releaseDate: nil, people: [])
        }
    }

    /// Parse the subset of the album item JSON that the liner-note section
    /// cares about. Static + internal so tests can hit it without wiring
    /// the full model. Missing fields become `nil`; the parser never throws.
    static func parseAlbumDetail(from json: String) -> AlbumDetail {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return AlbumDetail(label: nil, releaseDate: nil, people: [])
        }

        // Jellyfin ships `Studios` as an array of `{ Name, Id }` objects. Pick
        // the first non-empty label — servers with multiple labels tend to
        // list the primary one first.
        let label: String? = {
            guard let studios = root["Studios"] as? [[String: Any]] else { return nil }
            for entry in studios {
                if let name = entry["Name"] as? String {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }()

        // `PremiereDate` is an ISO 8601 string; fall back to `DateCreated`
        // if absent. We only keep the yyyy-MM-dd portion since the hero
        // already shows the year and the liner-note section wants "Released
        // 19 Apr 2013".
        let releaseDate: Date? = {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for key in ["PremiereDate", "DateCreated"] {
                if let raw = root[key] as? String, !raw.isEmpty {
                    if let d = iso.date(from: raw) { return d }
                    iso.formatOptions = [.withInternetDateTime]
                    if let d = iso.date(from: raw) { return d }
                }
            }
            return nil
        }()

        let people: [Person] = {
            guard let raw = root["People"] as? [[String: Any]] else { return [] }
            return raw.compactMap { entry in
                let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let type = (entry["Type"] as? String) ?? ""
                let rawId = (entry["Id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let id = rawId.isEmpty ? nil : rawId
                guard !name.isEmpty else { return nil }
                return Person(name: name, type: type, id: id)
            }
        }()

        return AlbumDetail(label: label, releaseDate: releaseDate, people: people)
    }

    /// Navigate to the artist detail screen for this album's artist, if known.
    func goToArtist(album: Album) {
        guard let artistID = album.artistId else { return }
        screen = .artist(artistID)
    }

    /// Navigate to the album's own detail screen. Used when the menu is
    /// invoked from a surface other than the album detail itself (e.g. a
    /// track row that links back to its album).
    func goToAlbum(album: Album) {
        screen = .album(album.id)
    }

    /// Kick off an Instant Mix ("album radio") seeded by this album.
    /// TODO: #144, #327 — Instant Mix endpoint + modal not yet wired.
    func startAlbumRadio(album: Album) {
        // TODO: #144 / #327 — Instant Mix FFI not yet wired.
        print("[AppModel] startAlbumRadio(album:) not yet wired — see #144 / #327")
    }

    /// Mark every track on the album as played.
    /// TODO: #133 / #222 — `mark_played` FFI not yet wired.
    func markAllAsPlayed(album: Album) {
        // TODO(#133): mark_played FFI not yet wired.
        print("[AppModel] markAllAsPlayed(album:) not yet wired — see #133 / #222")
    }

    /// Present the album metadata editor. Admin-only once the sheet lands.
    /// TODO: #96 / #222 — metadata editor sheet not yet implemented.
    func requestEditAlbum(album: Album) {
        // TODO(#96): metadata editor sheet not yet implemented.
        print("[AppModel] requestEditAlbum(album:) not yet wired — see #96 / #222")
    }

    /// Append every track on the album to a user-picked playlist.
    /// TODO: #126 / #130 — `add_to_playlist` FFI not yet wired.
    func addAlbumToPlaylist(album: Album, playlist: Playlist) {
        // TODO(#126): add_to_playlist FFI not yet wired.
        print("[AppModel] addAlbumToPlaylist(\(album.name) → \(playlist.name)) not yet wired — see #126")
    }

    // MARK: - Sharing

    /// Jellyfin web URL for an album, e.g.
    /// `https://server.example.com/web/#/details?id=<albumId>`.
    func webURL(for album: Album) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        return URL(string: "\(base)/web/#/details?id=\(album.id)")
    }

    /// Copy the album's web URL to the system pasteboard.
    func copyShareLink(album: Album) {
        guard let url = webURL(for: album) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    /// Open the album in the Jellyfin web UI.
    func openInJellyfin(album: Album) {
        guard let url = webURL(for: album) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Artist actions

    /// Play every track by an artist in catalog order.
    /// TODO: #156 / #465 — artist-tracks FFI (and an ItemsQuery filter for
    /// `artist_id`) isn't wired yet, so this is a logging stub.
    func playAll(artist: Artist) {
        // TODO: #156 / #465 — artist-tracks FFI not yet wired.
        print("[AppModel] playAll(artist:) not yet wired — see #156 / #465")
    }

    /// Shuffle every track by an artist.
    /// TODO: #156 / #465 — same artist-tracks FFI dependency as `playAll`.
    func shuffle(artist: Artist) {
        // TODO: #156 / #465 — artist-tracks FFI not yet wired.
        print("[AppModel] shuffle(artist:) not yet wired — see #156 / #465")
    }

    /// Play the artist's top tracks (play-count-weighted). Fetches the
    /// top 5 via the core, then starts playback from the first. See #229.
    func playTopTracks(artist: Artist) {
        Task {
            let tracks = await loadArtistTopTracks(artistId: artist.id)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Toggle the favorite flag for an artist on the Jellyfin server.
    /// TODO: #133, #64 — wire through `set_favorite` / `unset_favorite` on
    /// the core once the FFI surface exists.
    func toggleFavorite(artist: Artist) {
        // TODO: #133 / #64 — set_favorite FFI not yet wired.
        print("[AppModel] toggleFavorite(artist:) not yet wired — see #133 / #64")
    }

    /// Toggle the follow flag for an artist.
    /// TODO: #64 / #228 — server-side follow primitive TBD. For now,
    /// toggle a local `followedArtistIds` set so the UI has something to
    /// render against; persistence lives alongside the real API work.
    func toggleFollow(artist: Artist) {
        if followedArtistIds.contains(artist.id) {
            followedArtistIds.remove(artist.id)
        } else {
            followedArtistIds.insert(artist.id)
        }
    }

    /// `true` when the user has followed this artist (in-app, today).
    /// See `toggleFollow(artist:)` for the TODO on server-side follow.
    func isFollowing(artist: Artist) -> Bool {
        followedArtistIds.contains(artist.id)
    }

    /// Play a handful of the artist's top tracks as "Play Next".
    /// TODO: #282 — needs an Up Next queue primitive. Until that lands,
    /// behaves like `playTopTracks` (start playback from the first top
    /// track) so the UI action has a landing pad.
    func playNextArtist(artist: Artist) {
        // TODO(#282): queue "Up Next" insertion. Fall through to top-tracks
        // playback so the menu item does something.
        playTopTracks(artist: artist)
    }

    /// Navigate to the artist detail screen. Used when the menu is invoked
    /// from a surface other than the artist detail itself (e.g. a track
    /// row whose secondary line is the artist).
    func goToArtistPage(artist: Artist) {
        screen = .artist(artist.id)
    }

    /// Kick off an Instant Mix ("artist radio") seeded by this artist.
    /// TODO: #144 — Instant Mix (polymorphic) FFI not yet wired.
    func startArtistRadio(artist: Artist) {
        // TODO: #144 — Instant Mix FFI not yet wired.
        print("[AppModel] startArtistRadio(artist:) not yet wired — see #144")
    }

    /// Navigate to the artist detail screen, anchored on the discography.
    /// The artist detail screen itself is tracked in #58 / #60 / #408; for now
    /// we just route to `.artist(id)` and let that view (when it lands) pick
    /// up the discography anchor.
    func goToDiscography(artist: Artist) {
        screen = .artist(artist.id)
    }

    /// Show artists similar to this one.
    /// TODO: #146 — similar_artists FFI not yet wired.
    func showSimilar(artist: Artist) {
        // TODO: #146 — similar_artists FFI not yet wired.
        print("[AppModel] showSimilar(artist:) not yet wired — see #146")
    }

    // MARK: - Artist sharing

    /// Jellyfin web URL for an artist, e.g.
    /// `https://server.example.com/web/#/details?id=<artistId>`.
    func webURL(for artist: Artist) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        return URL(string: "\(base)/web/#/details?id=\(artist.id)")
    }

    /// Copy the artist's web URL to the system pasteboard.
    func copyShareLink(artist: Artist) {
        guard let url = webURL(for: artist) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    /// Open the artist in the Jellyfin web UI.
    func openInJellyfin(artist: Artist) {
        guard let url = webURL(for: artist) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Playlist actions
    //
    // Parallels the album actions above. Issue #313.
    //
    // Playback actions are live now that `playlist_tracks` has landed (#125;
    // see `loadPlaylistTracks`). Mutation actions (favorite, download,
    // rename, delete) remain TODO stubs pending follow-up FFI work:
    // favorites (#133), download engine (#70), `update_playlist` (#130),
    // `delete_playlist` (#131). The UI is wired up now so that when each
    // backing endpoint lands the action just needs its stub swapped for a
    // real call.

    /// Fetch a playlist's tracks and start playback from the top.
    func play(playlist: Playlist) {
        Task {
            let tracks = await loadPlaylistTracks(playlist: playlist)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks, startIndex: 0)
        }
    }

    /// Shuffle a playlist — loads tracks, randomises order, then plays from
    /// the top. Mirrors `shuffle(album:)`.
    func shuffle(playlist: Playlist) {
        Task {
            let tracks = await loadPlaylistTracks(playlist: playlist)
            guard !tracks.isEmpty else { return }
            play(tracks: tracks.shuffled(), startIndex: 0)
        }
    }

    /// Insert a playlist's tracks immediately after the currently-playing track.
    /// TODO: #282 — proper Up Next vs Auto Queue separation. For now, the core
    /// queue is replaced on every `setQueue`, so until we grow an `insertNext`
    /// primitive this falls back to replace-and-play behaviour.
    func playNext(playlist: Playlist) {
        // TODO: #282 — queue "Up Next" insertion; for now, replace-and-play.
        print("[AppModel] playNext(playlist:) not yet wired — see #282")
        play(playlist: playlist)
    }

    /// Append a playlist's tracks to the end of the queue.
    /// TODO: #282 — the core lacks an `appendToQueue` primitive, so this is a
    /// stub that plays the playlist outright for now.
    func addToQueue(playlist: Playlist) {
        // TODO: #282 — queue append. Currently behaves like `play`.
        print("[AppModel] addToQueue(playlist:) not yet wired — see #282")
        play(playlist: playlist)
    }

    /// Toggle the favorite flag for a playlist on the Jellyfin server.
    /// TODO: #133, #222 — wire through `set_favorite` / `unset_favorite` on
    /// the core once the FFI surface exists.
    func toggleFavorite(playlist: Playlist) {
        // TODO: #133 / #222 — set_favorite FFI not yet wired.
        print("[AppModel] toggleFavorite(playlist:) not yet wired — see #133 / #222")
    }

    /// Enqueue a download of every track in the playlist.
    /// TODO: #70, #222 — there is no download engine yet; this is a logging
    /// stub so the UI action has a landing pad.
    func enqueueDownload(playlist: Playlist) {
        // TODO: #70 / #222 — download engine not yet wired.
        print("[AppModel] enqueueDownload(playlist:) not yet wired — see #70 / #222")
    }

    /// Present a rename prompt for a playlist.
    /// TODO: #75, #130 — rename UI sheet + `update_playlist` FFI not yet wired.
    func requestRename(playlist: Playlist) {
        // TODO: #75 / #130 — rename sheet + update_playlist FFI not yet wired.
        print("[AppModel] requestRename(playlist:) not yet wired — see #75 / #130")
    }

    /// Present a delete confirmation for a playlist.
    /// TODO: #75, #131 — delete confirm alert + `delete_playlist` FFI not yet
    /// wired.
    func requestDelete(playlist: Playlist) {
        // TODO: #75 / #131 — delete confirm + delete_playlist FFI not yet wired.
        print("[AppModel] requestDelete(playlist:) not yet wired — see #75 / #131")
    }

    /// Raise a delete-confirmation dialog for a playlist. Sets
    /// `playlistPendingDelete`, which `MainShell` observes to present a
    /// `.confirmationDialog` with clear "Delete <playlist name>?" copy.
    /// The actual delete happens in `performDeletePending()` once the user
    /// confirms.
    func confirmDelete(playlist: Playlist) {
        playlistPendingDelete = playlist
    }

    /// Execute the pending playlist deletion, if any. Called from the
    /// confirmation dialog's destructive button.
    /// TODO(#131): delete_playlist FFI not yet wired; for now, optimistically
    /// drop from the local `playlists` array so the UI can be tested.
    func performDeletePending() {
        guard let target = playlistPendingDelete else { return }
        playlistPendingDelete = nil
        playlists.removeAll { $0.id == target.id }
        // TODO(#131): delete_playlist FFI not yet wired — local drop only.
        print("[AppModel] performDeletePending(\(target.name)) local-only — see #131")
    }

    /// Dismiss the pending delete dialog without deleting anything.
    func cancelDeletePending() {
        playlistPendingDelete = nil
    }

    /// Duplicate a playlist: create a new playlist with the same tracks.
    /// TODO(#126): create_playlist + add_to_playlist FFIs not yet wired.
    func requestDuplicate(playlist: Playlist) {
        // TODO(#126): create_playlist + add_to_playlist FFIs not yet wired.
        print("[AppModel] requestDuplicate(playlist:) not yet wired — see #126")
    }

    /// Present a save panel and write the playlist to disk as an `.m3u8` file.
    /// TODO(#98): needs `playlist_tracks` (#125) to resolve file paths + the
    /// save panel + an m3u8 writer. Logging stub for now.
    func exportPlaylist(playlist: Playlist) {
        // TODO(#98): m3u8 export not yet wired — needs #125 + save panel.
        print("[AppModel] exportPlaylist(playlist:) not yet wired — see #98 / #125")
    }

    /// Rename a playlist in place from the playlist hero's click-to-edit
    /// title (#234). Updates the cached `Playlist` in `playlists` so the hero
    /// reflects the new name immediately.
    ///
    /// TODO: #130 — the `update_playlist` FFI / HTTP `POST /Items/{Id}` wrapper
    /// is still pending. Until it lands this is an in-memory-only rename: on
    /// the next library refresh the cached `Playlist` gets overwritten with
    /// whatever the server still has. That's acceptable for now — the
    /// interaction exercises the view plumbing, and the follow-up swap is a
    /// one-line change here.
    func renamePlaylist(_ playlist: Playlist, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != playlist.name else { return }
        // TODO: #130 — call `core.updatePlaylist(playlistId:, name:)` once the
        // FFI lands. For now, optimistically update the in-memory cache.
        print("[AppModel] renamePlaylist(\(playlist.id), \(trimmed)) not yet persisted — see #130")
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[idx] = Playlist(
            id: playlist.id,
            name: trimmed,
            trackCount: playlist.trackCount,
            runtimeTicks: playlist.runtimeTicks,
            imageTag: playlist.imageTag
        )
    }

    /// Update the description (Jellyfin `Overview`) for a playlist from the
    /// hero's click-to-edit description editor (#234). The core `Playlist`
    /// record doesn't expose `Overview` yet, so the new text lives in the
    /// in-memory `playlistDescriptions` map keyed by playlist id.
    ///
    /// TODO: #130 — switch this to `core.updatePlaylist(playlistId:, overview:)`
    /// once the FFI lands, and drop `playlistDescriptions` entirely in favour
    /// of a `description: Option<String>` field on `Playlist` in
    /// `core/src/models.rs`.
    func updatePlaylistDescription(_ playlist: Playlist, newDescription: String) {
        let trimmed = newDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        // TODO: #130 — persist via `core.updatePlaylist` once available.
        print("[AppModel] updatePlaylistDescription(\(playlist.id)) not yet persisted — see #130")
        if trimmed.isEmpty {
            playlistDescriptions.removeValue(forKey: playlist.id)
        } else {
            playlistDescriptions[playlist.id] = trimmed
        }
    }

    // MARK: - Playlist sharing

    /// Jellyfin web URL for a playlist, e.g.
    /// `https://server.example.com/web/#/details?id=<playlistId>`. The Jellyfin
    /// web UI uses the same `details` route for albums, artists, and playlists.
    func webURL(for playlist: Playlist) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        return URL(string: "\(base)/web/#/details?id=\(playlist.id)")
    }

    /// Copy the playlist's web URL to the system pasteboard.
    func copyShareLink(playlist: Playlist) {
        guard let url = webURL(for: playlist) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    /// Open the playlist in the Jellyfin web UI.
    func openInJellyfin(playlist: Playlist) {
        guard let url = webURL(for: playlist) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Track actions
    //
    // Backing calls for `TrackContextMenu`. Accept `[Track]` rather than a
    // single `Track` so the same surface handles single-row and multi-select
    // invocations — spec in #95 / #310 / #315. Most of these are TODO stubs
    // pending follow-up FFI work (queue primitives #282, favorites #133,
    // download engine #70, mark-played #133, song radio #144, metadata
    // editor #96).

    /// Insert a selection of tracks immediately after the currently-playing
    /// track.
    /// TODO(#282): queue "Up Next" insertion primitive. For now, behaves
    /// like `play(tracks:)` so the menu item does something.
    func playNext(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        // TODO(#282): queue "Up Next" insertion not yet wired.
        print("[AppModel] playNext(tracks:) not yet wired — see #282")
        play(tracks: tracks, startIndex: 0)
    }

    /// Append a selection of tracks to the end of the queue.
    /// TODO(#282): queue append primitive. For now, replaces the queue via
    /// `play(tracks:)` so the menu item has a landing pad.
    func addToQueue(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        // TODO(#282): queue append not yet wired.
        print("[AppModel] addToQueue(tracks:) not yet wired — see #282")
        play(tracks: tracks, startIndex: 0)
    }

    /// Kick off an Instant Mix ("song radio") seeded by a single track.
    /// TODO(#144): Instant Mix (polymorphic) FFI not yet wired.
    func startSongRadio(track: Track) {
        // TODO(#144): Instant Mix FFI not yet wired.
        print("[AppModel] startSongRadio(track:) not yet wired — see #144")
    }

    /// Append a selection of tracks to a user-picked playlist.
    /// TODO(#126): `add_to_playlist` FFI not yet wired.
    func addTracksToPlaylist(tracks: [Track], playlist: Playlist) {
        // TODO(#126): add_to_playlist FFI not yet wired.
        print("[AppModel] addTracksToPlaylist(\(tracks.count) tracks → \(playlist.name)) not yet wired — see #126")
    }

    /// Present a "new playlist" flow seeded with the given selection.
    /// TODO(#126): create_playlist FFI + sheet not yet wired.
    func requestAddTracksToPlaylist(tracks: [Track]) {
        // TODO(#126): create_playlist + picker sheet not yet wired.
        print("[AppModel] requestAddTracksToPlaylist(\(tracks.count) tracks) not yet wired — see #126")
    }

    /// Navigate to the album detail screen for this track's album.
    func goToAlbum(track: Track) {
        guard let albumID = track.albumId else { return }
        screen = .album(albumID)
    }

    /// Navigate to the artist detail screen for this track's artist.
    func goToArtist(track: Track) {
        guard let artistID = track.artistId else { return }
        screen = .artist(artistID)
    }

    /// Present the per-track info sheet (title, album, bitrate, people).
    /// TODO(#95): info sheet not yet implemented. Logging stub so ⌘I has a
    /// landing pad.
    func showTrackInfo(track: Track) {
        // TODO(#95): track info sheet not yet wired.
        print("[AppModel] showTrackInfo(track: \(track.name)) not yet wired — see #95")
    }

    /// Remove a selection of tracks from a specific playlist. Used by the
    /// multi-select context menu when scoped to a playlist detail view.
    /// TODO(#132): `remove_from_playlist` FFI not yet wired.
    func removeTracksFromPlaylist(tracks: [Track], playlist: Playlist) {
        // TODO(#132): remove_from_playlist FFI not yet wired.
        print("[AppModel] removeTracksFromPlaylist(\(tracks.count) from \(playlist.name)) not yet wired — see #132")
    }

    /// Toggle favorite across every track in the selection. If every track
    /// is already favorited, this unfavorites them all; otherwise favorites
    /// the un-favorited subset.
    /// TODO(#133): set_favorite / unset_favorite FFIs not yet wired.
    func toggleFavorite(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        // TODO(#133): set_favorite / unset_favorite FFIs not yet wired.
        print("[AppModel] toggleFavorite(tracks: \(tracks.count)) not yet wired — see #133")
    }

    /// Toggle the download state of every track in the selection.
    /// TODO(#70): download engine not yet wired.
    func toggleDownload(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        // TODO(#70): download engine not yet wired.
        print("[AppModel] toggleDownload(tracks: \(tracks.count)) not yet wired — see #70")
    }

    /// Mark or unmark every track in the selection as played.
    /// TODO(#133): mark_played / mark_unplayed FFIs not yet wired.
    func toggleMarkPlayed(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        // TODO(#133): mark_played / mark_unplayed FFIs not yet wired.
        print("[AppModel] toggleMarkPlayed(tracks: \(tracks.count)) not yet wired — see #133")
    }

    // MARK: - Track sharing

    /// Jellyfin web URL for a single track. Jellyfin's web UI uses the
    /// same `details` route for every item type, so this mirrors
    /// `webURL(for album:)` / `webURL(for playlist:)`.
    func webURL(for track: Track) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        return URL(string: "\(base)/web/#/details?id=\(track.id)")
    }

    /// Copy the track's web URL to the system pasteboard.
    func copyShareLink(track: Track) {
        guard let url = webURL(for: track) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    // MARK: - Genre actions
    //
    // Backing calls for `GenreContextMenu`. The core doesn't yet expose a
    // Genre type (genres are surfaced as bare strings on `Album`/`Artist`
    // today). All four actions are TODO stubs pending follow-up work
    // (#144 radio, #318 genre detail screen, #248 / #249 Home pinning).

    /// Navigate to the genre's browse view.
    /// TODO(#318): genre detail screen not yet implemented.
    func browseGenre(genre: String) {
        // TODO(#318): genre detail screen not yet implemented.
        print("[AppModel] browseGenre(\(genre)) not yet wired — see #318")
    }

    /// Kick off an Instant Mix seeded by a genre.
    /// TODO(#144): genre-seeded Instant Mix FFI not yet wired.
    func startGenreRadio(genre: String) {
        // TODO(#144): genre-seeded Instant Mix FFI not yet wired.
        print("[AppModel] startGenreRadio(\(genre)) not yet wired — see #144")
    }

    /// Shuffle every track tagged with the given genre.
    /// TODO(#318): genre-scoped track list FFI not yet wired.
    func shuffleGenre(genre: String) {
        // TODO(#318): genre-scoped track list FFI not yet wired.
        print("[AppModel] shuffleGenre(\(genre)) not yet wired — see #318")
    }

    /// Pin a genre tile to the Home screen so the user can one-click-browse.
    /// TODO(#248 / #249): Home personalization (pinned tiles) not yet wired.
    func pinGenreToHome(genre: String) {
        // TODO(#248): pinned tiles not yet wired.
        print("[AppModel] pinGenreToHome(\(genre)) not yet wired — see #248 / #249")
    }

    func pause() { audio.pause() }
    func resume() { audio.resume() }
    func stop() { audio.stop() }

    func skipNext() {
        if let next = core.skipNext() {
            playCurrent(next)
        } else {
            stop()
        }
    }

    func skipPrevious() {
        if let prev = core.skipPrevious() {
            playCurrent(prev)
        }
    }

    func setVolume(_ v: Float) { audio.setVolume(v) }

    /// Seek the current track by a relative offset (seconds). Negative rewinds,
    /// positive fast-forwards. Clamped to `[0, duration]` so the seek never
    /// overshoots the track's own bounds; routes through `audio.seek` exactly
    /// like the scrubber / `mediaSessionSeek` so the `MPNowPlayingInfoCenter`
    /// widget gets the same one-writer update. Wired to the ⌘⇧← / ⌘⇧→ menu
    /// shortcuts and the list row "skip back/forward" affordances. See #6.
    func seek(by delta: Double) {
        guard status.currentTrack != nil else { return }
        let duration = max(0, status.durationSeconds)
        let target = status.positionSeconds + delta
        let clamped = max(0, duration > 0 ? min(target, duration) : target)
        audio.seek(toSeconds: clamped)
    }

    func togglePlayPause() {
        switch status.state {
        case .playing: pause()
        case .paused: resume()
        case .ended, .stopped, .idle, .loading:
            // End-of-track or other non-active states: restart the current
            // track so ⌘-Space after a song ends does the obvious thing.
            if let track = status.currentTrack {
                playCurrent(track)
            }
        }
    }

    private func playCurrent(_ track: Track) {
        do {
            try audio.play(track: track)
        } catch {
            if handleAuthError(error) { return }
            errorMessage = "Playback failed: \(error.localizedDescription)"
        }
    }

    private func handleTrackEnded() {
        // Advance to the next track in the queue if there is one.
        if let next = core.skipNext() {
            playCurrent(next)
        }
    }

    // MARK: - Now Playing details

    /// Fetch detail fields (currently just `People`) for the track that is
    /// playing right now and publish the result on `currentTrackPeople` so
    /// the Now Playing credits block can render them. See #279.
    ///
    /// Safe to call repeatedly — if the current track hasn't changed since
    /// the last successful fetch, this is a no-op. On auth errors the
    /// central `handleAuthError` path triggers the re-login prompt; other
    /// errors are swallowed silently because Credits is a secondary
    /// widget and an empty state reads better than an error banner.
    func fetchCurrentTrackDetails() async {
        guard let track = status.currentTrack else {
            currentTrackPeople = []
            currentTrackPeopleForId = nil
            return
        }
        // Already have details for this track — skip.
        if currentTrackPeopleForId == track.id { return }
        let id = track.id
        do {
            let json = try await Task.detached(priority: .userInitiated) { [core] in
                try core.fetchItem(itemId: id, fields: ["People"])
            }.value
            // Ignore the response if the user skipped to a different track
            // while we were awaiting.
            guard status.currentTrack?.id == id else { return }
            currentTrackPeople = Self.parsePeople(from: json)
            currentTrackPeopleForId = id
        } catch {
            _ = handleAuthError(error)
            // Silent fallback — credits is a best-effort block.
        }
    }

    /// Parse Jellyfin's `Item.People` array out of the raw JSON returned by
    /// `core.fetchItem`. Each person comes back as
    /// `{ "Name": string, "Type": string, "Role": string, ... }`; only
    /// `Name` and `Type` are retained (see `Person`). Entries missing a
    /// non-empty `Name` are dropped so we don't render blank rows.
    static func parsePeople(from json: String) -> [Person] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["People"] as? [[String: Any]]
        else {
            return []
        }
        return raw.compactMap { entry in
            let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let type = (entry["Type"] as? String) ?? ""
            let rawId = (entry["Id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let id = rawId.isEmpty ? nil : rawId
            guard !name.isEmpty else { return nil }
            return Person(name: name, type: type, id: id)
        }
    }

    /// Load lyrics for the currently-playing track and publish them on
    /// `currentLyrics`. Supports both LRC (timestamped) and plain-text
    /// bodies — the parser detects the shape and `LyricsView` renders the
    /// right layout. See #91, #273, #287, #288.
    ///
    /// TODO(core-#162): wire to `core.track_lyrics(track_id)` once the FFI
    /// lands. Jellyfin exposes lyrics at `GET /Audio/{id}/Lyrics` (and as
    /// a `Lyrics` field on the item JSON when requested); the core is the
    /// right place to decide between the two and return a normalized
    /// string. Until that ships this method is a stub that clears any
    /// stale data and returns an empty result so the view renders its
    /// "No lyrics available" empty state.
    ///
    /// Safe to call repeatedly — short-circuits when the current track
    /// id already matches the last successful fetch. Cleared on track
    /// change by the polling loop (see `startPolling`).
    func fetchCurrentTrackLyrics() async {
        guard let track = status.currentTrack else {
            currentLyrics = nil
            currentLyricsForId = nil
            return
        }
        if currentLyricsForId == track.id { return }
        let id = track.id

        // TODO(core-#162): replace the stub with
        //   let raw = try core.trackLyrics(itemId: id)
        //   currentLyrics = LyricLine.parseLRC(raw)
        // For now we publish an empty array so the Lyrics tab renders
        // the "No lyrics available" empty state rather than a perpetual
        // loading spinner — unlocks the surrounding Now Playing UI
        // without blocking on the core FFI.
        guard status.currentTrack?.id == id else { return }
        currentLyrics = []
        currentLyricsForId = id
    }

    // MARK: - Status polling

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let before = self.status.currentTrack?.id
                let beforeQueuePos = self.status.queuePosition
                let beforeQueueLen = self.status.queueLength
                self.status = self.core.status()
                let after = self.status.currentTrack?.id
                // Trigger a details refetch when the track changes. Scoped
                // to the polling loop so skipping via the PlayerBar,
                // media keys, or end-of-track auto-advance all get it
                // for free.
                if before != after {
                    if after == nil {
                        self.currentTrackPeople = []
                        self.currentTrackPeopleForId = nil
                        self.currentLyrics = nil
                        self.currentLyricsForId = nil
                    } else {
                        Task { await self.fetchCurrentTrackDetails() }
                        Task { await self.fetchCurrentTrackLyrics() }
                    }
                }
                // Keep MediaSession's queue index in sync when a skip
                // happens. `AudioEngine.play(track:)` already fires
                // `trackChanged` for the new item; `queueChanged` handles
                // the case where the queue length shifts without a new
                // track starting (e.g. future `setQueue` on the current).
                // Elapsed time is intentionally NOT pushed on every tick
                // (see issue #48 — the widget interpolates from
                // `elapsed + wallclock * rate`).
                if beforeQueuePos != self.status.queuePosition
                    || beforeQueueLen != self.status.queueLength {
                    self.mediaSession.queueChanged()
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Queue inspector (BATCH-07a)

    /// Toggle the right-side Queue Inspector panel. Bound to the Cmd+Opt+Q
    /// keyboard shortcut via `MainShell`. See #79.
    func toggleQueueInspector() {
        isQueueInspectorOpen.toggle()
    }

    /// Reorder the user-added "Up Next" list. Uses the same `IndexSet` → Int
    /// contract as SwiftUI `List.onMove`, so the inspector can wire this up
    /// directly. See #80.
    ///
    /// Today this only reorders the in-app overlay because the core has no
    /// `reorder_queue` primitive. When that lands (TODO(core-#282)), this
    /// should also push the new order down to `core.setQueue` so the
    /// engine's view of "what plays next" matches the inspector.
    func moveUpNext(from source: IndexSet, to destination: Int) {
        upNextUserAdded.move(fromOffsets: source, toOffset: destination)
        // TODO(core-#282): push the reordered slice down to the core queue
        // once a `reorder_queue` primitive exists. For now, the overlay
        // drives the inspector and the core keeps its original order.
    }

    /// Remove one entry from the user-added "Up Next" list by its stable
    /// per-item `queueId`. Uses `queueId` rather than `track.id` so users
    /// can queue the same track twice and still remove a single instance.
    /// See #80.
    func removeFromUpNext(id: UUID) {
        upNextUserAdded.removeAll { $0.id == id }
        // TODO(core-#282): drop the corresponding entry in the core queue
        // once we have an addressable `remove_from_queue` primitive.
    }
}

// MARK: - Queue models (BATCH-07a)

/// One entry in the Queue Inspector's lists. Thin wrapper around `Track`
/// that carries a per-instance `queueId` so the same track can be queued
/// more than once and still be individually addressable by `onMove` /
/// remove. `Track.id` is the Jellyfin item id and would collide on repeats.
struct Queue: Identifiable, Hashable {
    /// Stable per-queue-instance id. Not the track id — see struct doc.
    let id: UUID
    /// Underlying audio track.
    let track: Track

    init(id: UUID = UUID(), track: Track) {
        self.id = id
        self.track = track
    }
}

/// Source that populated the current auto-queue tail — what the inspector's
/// "PLAYING FROM {source}" header describes. Kept minimal on purpose; #82
/// and BATCH-07b will flesh out the richer label / link treatment.
struct QueueContext: Hashable {
    /// Display name (e.g. album title, playlist name, artist name).
    let name: String
    /// Jellyfin item id for the source, when known. Nil for ad-hoc
    /// selections (e.g. shuffle-all-favorites) without a single target.
    let id: String?
    /// What kind of surface started playback. Drives the icon + route
    /// behavior the header uses when the user clicks the source label.
    let sourceType: ContextSourceType
}

/// Classification of what started the current playback. See `QueueContext`.
enum ContextSourceType: String, Hashable {
    case album
    case playlist
    case artist
    case genre
    case search
    case radio
    case other
}

/// One batch of tracks removed from a playlist, kept around long enough for
/// the `PlaylistDetailView` undo toast to restore them. See #74.
struct PendingRemoval {
    let playlistId: String
    let tracks: [Track]
}

// MARK: - Convenience

extension Track {
    var durationSeconds: Double {
        Double(runtimeTicks) / 10_000_000.0
    }
    var durationFormatted: String {
        let total = Int(durationSeconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Client-side genre record used by `InstantSearchResults` and the search
/// dropdown's genre row. Jellyfin returns genres as bare strings on
/// `Album`/`Artist` today, so an `id` is derived from the name until a
/// proper `MusicGenre` item shape lands in core (see `GenreContextMenu`'s
/// TODO for #318).
struct Genre: Hashable, Identifiable, Sendable {
    let id: String
    let name: String

    init(name: String) {
        self.name = name
        // Name doubles as id — genres are unique by label in Jellyfin's
        // surface and we don't have the real collection ids yet.
        self.id = name
    }
}

/// Heterogeneous "thing" returned by the instant-search dropdown. Wraps the
/// four core record types plus `Genre` so the dropdown's `onPickItem`
/// callback can carry enough context for routing without per-type
/// callbacks.
///
/// `title` / `playCount` are derived so the ranking algorithm in
/// `AppModel.pickTopResult` can stay generic.
enum SearchItem: Hashable, Sendable {
    case artist(Artist)
    case album(Album)
    case track(Track)
    case playlist(Playlist)
    case genre(Genre)

    var id: String {
        switch self {
        case .artist(let a): return "artist:\(a.id)"
        case .album(let a): return "album:\(a.id)"
        case .track(let t): return "track:\(t.id)"
        case .playlist(let p): return "playlist:\(p.id)"
        case .genre(let g): return "genre:\(g.id)"
        }
    }

    var title: String {
        switch self {
        case .artist(let a): return a.name
        case .album(let a): return a.name
        case .track(let t): return t.name
        case .playlist(let p): return p.name
        case .genre(let g): return g.name
        }
    }

    /// Human-readable type label rendered on the hero card. "Artist" /
    /// "Album" / "Track" / "Playlist" / "Genre" per the spec in #243.
    var typeLabel: String {
        switch self {
        case .artist: return "Artist"
        case .album: return "Album"
        case .track: return "Track"
        case .playlist: return "Playlist"
        case .genre: return "Genre"
        }
    }

    /// Play count used as the secondary ranking key. Only tracks carry
    /// one today; everything else returns 0 so the comparator still does
    /// the right thing in a generic `.min(by:)`.
    var playCount: UInt32 {
        if case .track(let t) = self { return t.playCount }
        return 0
    }
}

/// Aggregate payload for the instant-search dropdown. Split into typed
/// sections so the dropdown can render each without re-partitioning, and
/// carries a pre-ranked `topResult` so the hero card doesn't need to
/// re-run the ranker on every view update. See `AppModel.runInstantSearch`.
struct InstantSearchResults: Sendable {
    let topResult: SearchItem?
    let artists: [Artist]
    let albums: [Album]
    let tracks: [Track]
    let playlists: [Playlist]
    let genres: [Genre]

    static let empty = InstantSearchResults(
        topResult: nil,
        artists: [],
        albums: [],
        tracks: [],
        playlists: [],
        genres: []
    )

    /// True when every section is empty — the dropdown uses this to
    /// decide between rendering results vs. a minimal "no matches" state.
    var isEmpty: Bool {
        topResult == nil
            && artists.isEmpty
            && albums.isEmpty
            && tracks.isEmpty
            && playlists.isEmpty
            && genres.isEmpty
    }
}

/// Hydrated album fields fetched on demand by
/// `AppModel.loadAlbumDetail(albumId:)`. Lives in the AppModel file because
/// its parser does; the album detail screen is the only consumer today.
struct AlbumDetail: Equatable {
    /// First non-empty entry in Jellyfin's `Studios` array — treated as the
    /// record label in the liner-note section. `nil` when the field is
    /// absent or empty.
    let label: String?
    /// Album release date parsed from `PremiereDate` (falling back to
    /// `DateCreated`). `nil` when neither is parseable, in which case the
    /// liner-note section leans on the cached `Album.year` for "Released".
    let releaseDate: Date?
    /// Aggregated `People` array from the album item — composers,
    /// producers, mixers, engineers, etc. The album detail view groups
    /// these by role. Empty when the server didn't populate `People` (a
    /// surprising number don't).
    let people: [Person]
}

// MARK: - MediaSessionDelegate

/// Bridge between `MediaSession` (owns MPNowPlayingInfoCenter and
/// MPRemoteCommandCenter) and the rest of the app. Keeping the command
/// handlers here means a Bluetooth headset, Control Center click, or media
/// key all run the exact same code path as the on-screen buttons — no
/// duplicate transport logic. See issues #29 / #31.
extension AppModel: MediaSessionDelegate {
    var currentStatus: PlayerStatus { status }

    func mediaSessionTogglePlayPause() { togglePlayPause() }
    func mediaSessionPlay() {
        // Remote "play" may fire after a pause (resume) or at end-of-track
        // (restart). Reuse the existing togglePlayPause logic so the two
        // cases stay in one place.
        switch status.state {
        case .playing: return
        case .paused: resume()
        case .ended, .stopped, .idle, .loading:
            if let track = status.currentTrack {
                playCurrent(track)
            }
        }
    }
    func mediaSessionPause() { pause() }
    func mediaSessionStop() { stop() }
    func mediaSessionSkipNext() { skipNext() }
    func mediaSessionSkipPrevious() { skipPrevious() }
    func mediaSessionSeek(toSeconds seconds: Double) { audio.seek(toSeconds: seconds) }

    func mediaSessionArtworkURL(for track: Track, maxWidth: UInt32) -> URL? {
        imageURL(for: track.albumId ?? track.id, tag: track.imageTag, maxWidth: maxWidth)
    }
    func mediaSessionAuthorizationHeader() -> String? {
        try? core.authHeader()
    }
}
