import AppKit
import Foundation
import Observation
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
    let network: NetworkMonitor
    let serverReachability: ServerReachability

    // MARK: - Session
    var session: Session?
    var serverURL: String = ""
    var username: String = ""

    // MARK: - Navigation
    enum Screen: Hashable { case home, discover, library, search, settings, album(String), artist(String), playlist(String) }
    var screen: Screen = .library

    /// Toggled by the ⌘F menu command to request that `SearchView` move
    /// keyboard focus into its text field. `SearchView` observes changes and
    /// resets the flag after focusing so subsequent ⌘F presses fire again
    /// even when already on the Search screen.
    var requestSearchFocus: Bool = false

    // MARK: - Library
    var albums: [Album] = []
    var artists: [Artist] = []
    var albumTracks: [String: [Track]] = [:]          // albumID → tracks
    var recentlyPlayed: [Track] = []
    var searchResults: SearchResults?
    var searchQuery: String = ""

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
    /// Server-reported total recently-played count (listening history size).
    var recentlyPlayedTotal: UInt32 = 0
    /// Server-reported total for the current search query across all item kinds.
    var searchResultsTotal: UInt32 = 0

    /// A follow-up albums page is in flight. Views check this to suppress
    /// duplicate near-end triggers and to show a bottom spinner.
    var isLoadingMoreAlbums: Bool = false
    /// A follow-up artists page is in flight. See `isLoadingMoreAlbums`.
    var isLoadingMoreArtists: Bool = false
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

    // MARK: - Loading / errors
    var isLoggingIn = false
    var isLoadingLibrary = false
    var errorMessage: String?

    /// Set when a core call fails because the server rejected our token
    /// (HTTP 401) or the core reports no-longer-authenticated. Drives the
    /// modal prompt in `MainShell`. Reset after the user dismisses the sheet
    /// or signs back in. Auto-reauth (reissuing credentials silently) is
    /// tracked separately in #440 — this flag only powers the prompt.
    var authExpired: Bool = false

    init() throws {
        let core = try JellifyCore(
            config: CoreConfig(dataDir: "", deviceName: "Jellify macOS")
        )
        self.core = core
        self.audio = AudioEngine(core: core)
        self.network = NetworkMonitor()
        self.serverReachability = ServerReachability()
        self.status = core.status()
        self.audio.onTrackEnded = { [weak self] in
            self?.handleTrackEnded()
        }
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

    func logout() {
        audio.stop()
        try? core.logout()
        session = nil
        albums = []
        artists = []
        albumTracks = [:]
        recentlyPlayed = []
        searchResults = nil
        searchQuery = ""
        resetPaginationState()
        stopPolling()
    }

    /// Drop the stored access token (keychain + in-memory session) without
    /// clearing the remembered server URL / username, so the user can re-auth
    /// against the same server by re-entering only their password. Called
    /// when the user taps "Sign in" on the auth-expired sheet. Note: the
    /// caller still owns toggling `authExpired` off and nilling `session`.
    func forgetToken() {
        audio.stop()
        try? core.logout()
        albums = []
        artists = []
        albumTracks = [:]
        recentlyPlayed = []
        searchResults = nil
        searchQuery = ""
        resetPaginationState()
        stopPolling()
    }

    /// Clear all pagination counters and in-flight flags. Kept in one place
    /// so the two clear-the-session entry points (`logout`, `forgetToken`)
    /// stay in sync.
    private func resetPaginationState() {
        albumsTotal = 0
        artistsTotal = 0
        recentlyPlayedTotal = 0
        searchResultsTotal = 0
        isLoadingMoreAlbums = false
        isLoadingMoreArtists = false
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
        do {
            // Fetch albums and artists in parallel. Previously the two calls
            // were sequential, doubling time-to-first-paint on every fresh
            // session. `async let` lets both round-trips overlap; the
            // `await` below resolves when both complete. The smaller
            // `libraryInitialPageSize` (100 vs. the old 200) is a further
            // first-paint win — the grid fills the viewport with 100 and
            // `loadMoreAlbums` takes over when the user scrolls.
            async let albumsPage = Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
                try core.listAlbums(offset: 0, limit: libraryInitialPageSize)
            }.value
            async let artistsPage = Task.detached(priority: .userInitiated) { [core, libraryInitialPageSize] in
                try core.listArtists(offset: 0, limit: libraryInitialPageSize)
            }.value
            let (albums, artists) = try await (albumsPage, artistsPage)
            self.albums = albums.items
            self.albumsTotal = albums.totalCount
            self.artists = artists.items
            self.artistsTotal = artists.totalCount
            serverReachability.noteSuccess()
        } catch {
            if handleAuthError(error) { return }
            if ServerReachability.shouldCount(error: error) {
                serverReachability.noteFailure()
            }
            self.errorMessage = "Library load failed: \(error.localizedDescription)"
        }
        await refreshRecentlyPlayed()
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

    /// Switch to the Search screen and request keyboard focus in the search
    /// field. Called from the ⌘F menu command.
    func focusSearch() {
        screen = .search
        requestSearchFocus = true
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

    /// Toggle the favorite flag for an album on the Jellyfin server.
    /// TODO: #133, #222 — wire through `set_favorite` / `unset_favorite` on
    /// the core once the FFI surface exists.
    func toggleFavorite(album: Album) {
        // TODO: #133 / #222 — set_favorite FFI not yet wired.
        print("[AppModel] toggleFavorite(album:) not yet wired — see #133 / #222")
    }

    /// Enqueue a download of every track on the album.
    /// TODO: #70, #222 — there is no download engine yet; this is a logging
    /// stub so the UI action has a landing pad.
    func enqueueDownload(album: Album) {
        // TODO: #70 / #222 — download engine not yet wired.
        print("[AppModel] enqueueDownload(album:) not yet wired — see #70 / #222")
    }

    /// Present an "Add all to playlist" destination picker.
    /// TODO: #72, #126, #222 — playlist picker sheet + create-playlist API.
    func requestAddToPlaylist(album: Album) {
        // TODO: #72 / #126 / #222 — playlist picker sheet not yet implemented.
        print("[AppModel] requestAddToPlaylist(album:) not yet wired — see #72 / #126 / #222")
    }

    /// Navigate to the artist detail screen for this album's artist, if known.
    func goToArtist(album: Album) {
        guard let artistID = album.artistId else { return }
        screen = .artist(artistID)
    }

    /// Kick off an Instant Mix ("album radio") seeded by this album.
    /// TODO: #144, #327 — Instant Mix endpoint + modal not yet wired.
    func startAlbumRadio(album: Album) {
        // TODO: #144 / #327 — Instant Mix FFI not yet wired.
        print("[AppModel] startAlbumRadio(album:) not yet wired — see #144 / #327")
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

    /// Play the artist's top tracks (play-count-weighted).
    /// TODO: #229 — Top Tracks endpoint not yet wired.
    func playTopTracks(artist: Artist) {
        // TODO: #229 — Top Tracks endpoint not yet wired.
        print("[AppModel] playTopTracks(artist:) not yet wired — see #229")
    }

    /// Toggle the favorite flag for an artist on the Jellyfin server.
    /// TODO: #133, #64 — wire through `set_favorite` / `unset_favorite` on
    /// the core once the FFI surface exists.
    func toggleFavorite(artist: Artist) {
        // TODO: #133 / #64 — set_favorite FFI not yet wired.
        print("[AppModel] toggleFavorite(artist:) not yet wired — see #133 / #64")
    }

    /// Toggle the follow flag for an artist.
    /// TODO: #64, #228 — follow/unfollow semantics + core support TBD.
    func toggleFollow(artist: Artist) {
        // TODO: #64 / #228 — follow/unfollow not yet wired.
        print("[AppModel] toggleFollow(artist:) not yet wired — see #64 / #228")
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
    // Most of these are TODO stubs pending follow-up FFI work (the core does
    // not yet expose playlist-tracks lookup, queue-append, favorites, playlist
    // mutation, or a download engine). The UI component (`PlaylistContextMenu`)
    // is wired up now so that when each backing endpoint lands the action just
    // needs its stub swapped for a real call.

    /// Fetch a playlist's tracks and start playback from the top.
    /// TODO: #125 — the core does not yet expose `playlist_tracks`. Until it
    /// does, this is a logging stub so the UI action has a landing pad.
    func play(playlist: Playlist) {
        // TODO: #125 — playlist_tracks FFI not yet wired.
        print("[AppModel] play(playlist:) not yet wired — see #125")
    }

    /// Shuffle a playlist — once `playlist_tracks` lands, this should load the
    /// track list, randomise it, and play from the top (matching `shuffle(album:)`).
    /// TODO: #125 — see `play(playlist:)`.
    func shuffle(playlist: Playlist) {
        // TODO: #125 — playlist_tracks FFI not yet wired.
        print("[AppModel] shuffle(playlist:) not yet wired — see #125")
    }

    /// Insert a playlist's tracks immediately after the currently-playing track.
    /// TODO: #125, #282 — needs both `playlist_tracks` and an `insertNext`
    /// queue primitive. For now, a logging stub.
    func playNext(playlist: Playlist) {
        // TODO: #125 / #282 — playlist_tracks + Up Next insertion not yet wired.
        print("[AppModel] playNext(playlist:) not yet wired — see #125 / #282")
    }

    /// Append a playlist's tracks to the end of the queue.
    /// TODO: #125, #282 — needs both `playlist_tracks` and an `appendToQueue`
    /// queue primitive. For now, a logging stub.
    func addToQueue(playlist: Playlist) {
        // TODO: #125 / #282 — playlist_tracks + queue append not yet wired.
        print("[AppModel] addToQueue(playlist:) not yet wired — see #125 / #282")
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

    // MARK: - Status polling

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.status = self.core.status()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
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
