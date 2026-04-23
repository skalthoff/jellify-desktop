# Jellify Desktop — Issue Batch Plan

> Coordination artefact: how 320 open p0/p1 issues cluster into ~30 agent-batches so parallel workers don't clobber each other's files. Produced by the Issue Grouping Coordinator, source of truth is `gh issue list`.

## Summary

- **Total open issues:** 431 (149 p0 + 171 p1 + 111 p2).
- **Issues covered by this plan:** 110 (p0: ~85, p1: ~25). p2 intentionally deferred.
- **Issues skipped (in flight as open PRs #503–513):** #126, #127, #204, #229, #234, #249, #253, #259, #260, #263, #279 — ignored here.
- **Batch count:** 27 total — 18 p0-led batches + 9 high-value p1-led batches.
- **Rough agent-hours estimate:** ~62 agent-days across all batches (S=0.5d, M=1d, L=2d, XL=4d rollup). Agent-hours assume a single worker per batch; batches are independent and parallelisable except where flagged.

### Priority spread

p0 batches cover the macOS shell, Artist/Album/Playlist pages, MediaSession/MPRemoteCommand chain, Now Playing/Queue/Lyrics, Search + Command Palette, onboarding + settings, distribution pipeline, and the remaining p0 core/api methods. p1 batches pick up the highest-value follow-through (NSVisualEffect materials, a11y, perf/reliability, Linux + Windows bootstrap starts). Linux + Windows foundations are gated behind their respective bootstrap batches — don't ship port work until the bootstrap lands.

### Ordering + dependencies

1. **BATCH-01 (macOS Shell Foundation)** and **BATCH-02 (Command Menu + Keyboard Map)** are upstream prerequisites for nearly every other macOS batch. Ship first.
2. **BATCH-03 (MediaSession / MPRemoteCommandCenter)** gates Control Center + lock-screen behaviour and is a dependency for lyrics + queue work downstream.
3. **BATCH-11 (Core API — p0 playback + session)** gates anything that tries to report playback state or register the device profile, i.e. BATCH-03 must wait on its FFI surface.
4. **BATCH-24 (Core typed-enum + ItemsQuery refactor, #464/#465)** is a cross-cutting FFI change — it **blocks all downstream consumers until landed.** Scheduled but flagged.
5. All other batches are order-independent.

---

## BATCH-01 · macOS shell foundation (NavigationSplitView + toolbar + title bar)

- **Priority:** p0
- **Platform:** macos
- **Issues:**
  - #1: Adopt `NavigationSplitView` as the shell replacement for the custom HStack
  - #2: Adopt `.hiddenTitleBar` window style with `fullSizeContentView` so the sidebar runs edge-to-edge under the traffic lights
  - #3: Add a proper `.toolbar {}` with forward/back, sidebar toggle, and global search field
  - #4: Convert per-screen routing into a detail-column `NavigationStack` with typed `NavigationPath`
- **Files expected to touch:**
  - `macos/Sources/Jellify/Screens/MainShell.swift`
  - `macos/Sources/Jellify/JellifyApp.swift`
  - `macos/Sources/Jellify/AppModel.swift`
  - `macos/Sources/Jellify/Components/Sidebar.swift`
- **Rationale:** All four issues rebuild the same top-level shell. Splitting them yields unavoidable merge conflicts in `MainShell.swift` and `AppModel.swift`. One worker does the whole sitting-shell rewrite.
- **Suggested agent prompt:**
  > Implement issues #1, #2, #3, #4 together. Replace `macos/Sources/Jellify/Screens/MainShell.swift`'s bespoke `HStack { Sidebar; Divider; content }` with a SwiftUI `NavigationSplitView` (`.balanced`). Convert `AppModel.screen` routing into a typed `NavigationPath` driving the detail column's `NavigationStack`. Adopt `.hiddenTitleBar` + `fullSizeContentView` in `JellifyApp.swift` so the sidebar runs edge-to-edge under the traffic lights. Add a real `.toolbar {}` with: back/forward chevrons (wired to `NavigationPath` pop), sidebar toggle, and a global search field. Acceptance: sidebar selection drives detail column; back/forward works; no visual regression on login screen; `swift build` clean; smoke-test `./Scripts/make-bundle.sh && open build/Jellify.app` shows the new shell. Reference issue numbers in the PR title + body. Do NOT touch `AudioEngine.swift` or any `MediaSession` files.
- **Estimated effort:** ~1L + 2M + 1M = ~4 agent-days.

---

## BATCH-02 · macOS menu bar + Commands + keyboard map

- **Priority:** p0
- **Platform:** macos
- **Issues:**
  - #5: Ship the full macOS menu bar via `Commands` + `CommandGroup` + custom `CommandMenu`s
  - #6: Build the `Playback` CommandMenu with transport, seek, volume, and jump shortcuts matching Apple Music
  - #7: Wire Cmd+F, Cmd+L, Cmd+1..3, and tab-switch shortcuts through to AppModel + focus state
  - #8: Handle media keys (F7/F8/F9 and Bluetooth/headset transport) via the system remote command center
  - #104: Keyboard — global shortcut map
  - #105: Keyboard — list arrow key navigation with Return to play
- **Files expected to touch:**
  - `macos/Sources/Jellify/JellifyApp.swift`
  - `macos/Sources/Jellify/AppModel.swift`
  - `macos/Sources/Jellify/Components/TrackListRow.swift`, `TrackRow.swift`, `Sidebar.swift` (focus + list arrow nav)
  - `macos/Sources/JellifyAudio/MediaSession.swift` (new, or introduced here if BATCH-03 lands first — coordinate via #29)
- **Rationale:** The menu bar, `CommandMenu`s, and keyboard shortcuts all converge on `JellifyApp.swift`'s `.commands {}` block. Splitting them causes obvious conflicts; one worker builds the full shortcut map.
- **Suggested agent prompt:**
  > Implement issues #5, #6, #7, #8, #104, #105. Build the full macOS `.commands {}` block on the main `WindowGroup`: replace default menu bar with `Jellify`, `File`, `Edit`, `View`, `Playback`, `Window`, `Help` menus matching Apple Music's menu surface. Wire `CommandMenu("Playback")` with Space (play/pause), Cmd+→/← (next/prev), Cmd+↑/↓ (volume), Cmd+⇧+→/← (seek ±10s), Cmd+. (stop). Wire Cmd+F → focus search, Cmd+L → navigate-to-now-playing, Cmd+1/2/3 → sidebar tabs. Register media-key (F7/F8/F9) + Bluetooth/AirPods transport via `MPRemoteCommandCenter` (do NOT double-implement — share with BATCH-03 if landed). Make every list (`TrackListRow`, sidebar items) focusable: up/down navigate, Shift+arrow extends selection, Return plays, Space toggles play/pause, type-ahead within 500ms. Acceptance: menu bar populated; all keystrokes from issue #104 routed; `swift build` clean. Reference all 6 issue numbers in PR. Do NOT rewrite `AudioEngine.swift` transport internals — call into existing `core.play/pause/seek` APIs.
- **Estimated effort:** ~5M + 1M = ~6 agent-days. (Large batch — consider splitting if agent runs long.)

---

## BATCH-03 · MediaSession / MPNowPlayingInfoCenter / MPRemoteCommandCenter

- **Priority:** p0
- **Platform:** macos (audio)
- **Issues:**
  - #29: Introduce a MediaSession coordinator that owns MPNowPlayingInfoCenter updates
  - #30: Load and publish artwork to MPMediaItemArtwork
  - #31: Implement MPRemoteCommandCenter handlers (play, pause, togglePlayPause, next, previous, stop)
  - #32: Implement changePlaybackPositionCommand for scrubber in Control Center
  - #47: Audio session / background playback configuration (macOS)
  - #48: Elapsed-time sync strategy with MPNowPlayingInfoCenter
- **Files expected to touch:**
  - `macos/Sources/JellifyAudio/MediaSession.swift` (new file)
  - `macos/Sources/JellifyAudio/AudioEngine.swift`
  - `macos/Sources/Jellify/AppModel.swift` (wire subscription)
- **Rationale:** One coordinator object owns everything that talks to MediaPlayer.framework. Split work = split ownership = duplicate writers to `MPNowPlayingInfoCenter.default().nowPlayingInfo`, which breaks Control Center updates. Issue #29 says so explicitly.
- **Suggested agent prompt:**
  > Implement #29, #30, #31, #32, #47, #48 together. Create `macos/Sources/JellifyAudio/MediaSession.swift` as the **single** writer of `MPNowPlayingInfoCenter.default().nowPlayingInfo`. Hook it to `AudioEngine`'s track/position/rate changes. Wire `MPRemoteCommandCenter.shared()` closures for play, pause, togglePlayPause, next, previous, stop, `changePlaybackPositionCommand` (scrubber). Publish artwork via `MPMediaItemArtwork` with a URL-based loader that caches per `Track.id` and resizes via `core.imageUrl(itemId:tag:maxWidth:)`. Implement the elapsed-time sync pattern from issue #48 (only write `elapsed`+`rate` on pause/play/seek, not every tick). Document in a code comment that `AVAudioSession` is iOS-only and not applicable here. Acceptance: Control Center shows track art + title + artist; play/pause from Control Center works; scrubber is accurate. Reference all 6 issue numbers. Do NOT implement `likeCommand` / `shuffleCommand` / `repeatCommand` — those are separate batches (BATCH-14).
- **Estimated effort:** ~4M + 1S = ~4.5 agent-days.

---

## BATCH-04 · macOS Artist page (hero, top songs, discography, similar, about, follow, related)

- **Priority:** p0
- **Platform:** macos
- **Issues:**
  - #58: Artist page — hero header with shuffle-all and play-all
  - #60: Artist page — discography split by release type
  - #227: Artist hero band (design polish of #58)
  - #228: Play all / Shuffle / Follow / Radio transport
  - #232: Similar Artists row (p1 — included because it lives in the same view)
  - #231: About / bio (p1 — same view)
- **Skipped (in flight):** #229 → PR #512 top tracks.
- **Files expected to touch:**
  - `macos/Sources/Jellify/Screens/ArtistDetailView.swift` (new — does not exist today)
  - `macos/Sources/Jellify/Components/ArtistCard.swift` (reuse / extend)
  - `macos/Sources/Jellify/Components/HomeQuickTile.swift` or new `ArtistDiscographyRail.swift`
- **Rationale:** Six issues all touch one new view. Worker builds the full Artist page scaffold in one sitting. `#229` (top tracks) is already landed as PR #512, so the worker reads that PR as reference for style + data-access patterns.
- **Suggested agent prompt:**
  > Implement #58, #60, #227, #228, #231, #232. Create `macos/Sources/Jellify/Screens/ArtistDetailView.swift` (it doesn't exist yet). Structure: hero band (360pt, large artist image with gradient fade, artist name H1 overlay, listener stats subtitle), transport row (Play All / Shuffle / Follow / Radio per #228), Top Songs section (already built in PR #512 — call through to that component), Discography split by `AlbumType`: Albums / Singles & EPs / Compilations / Live / Appears On (#60 for heuristics), Similar Artists row (carousel of 140pt circular tiles), About / bio text section. Use existing `ArtistCard.swift` and `HomeQuickTile.swift` as precedent. Acceptance: route `AppModel.navigate(to: .artist(id))` shows the page; all sections populate; hero image falls back to `person.circle.fill` when the artist has no portrait. Reference all 6 issue numbers. Do NOT touch the Home or Album screens.
- **Estimated effort:** ~3M + 3S = ~4.5 agent-days.

---

## BATCH-05 · macOS Album page polish (credits, disc grouping, CTAs, hero)

- **Priority:** p0
- **Platform:** macos
- **Issues:**
  - #65: Album page — liner-note credits section
  - #66: Album page — disc number grouping
  - #70: Album page — Play, Shuffle, Radio, Download CTAs
  - #219: Album hero polish — stat strip typography
  - #222: Favorite / Download / Add-to-playlist actions (inline, sits next to CTA row)
- **Files expected to touch:**
  - `macos/Sources/Jellify/Screens/AlbumDetailView.swift`
- **Rationale:** All changes converge on `AlbumDetailView.swift`. Five issues = one view overhaul.
- **Suggested agent prompt:**
  > Implement #65, #66, #70, #219, #222 together in `macos/Sources/Jellify/Screens/AlbumDetailView.swift`. Hero: tighten typography per #219's stat strip spec; CTA row per #70 (Play / Shuffle / Radio / Download / `•••` overflow); favourite + add-to-playlist + download toggles per #222. Below hero: render tracks grouped by disc with sticky "DISC 1" / "DISC 2" small-caps headers (hidden if single-disc) per #66. Below tracklist: liner-note credits section (#65) with Released / Label / Format / Runtime / Tracks / Discs, aggregated composers/producers/mixers/engineers from track ID3 tags, shown as clickable chips that navigate to an artist page. Acceptance: both the multi-disc case (e.g. a deluxe edition) and single-disc case render correctly; keyboard focus reachable for each CTA; `swift build` clean. Reference all 5 issue numbers. Do NOT touch Artist or Home screens.
- **Estimated effort:** ~2S + 1M + 1M + 1S = ~3 agent-days.

---

## BATCH-06 · macOS Playlist page + CRUD (drag, remove, rename, duplicate, delete)

- **Priority:** p0
- **Platform:** macos
- **Issues:**
  - #71: Playlist — create dialog with instant name edit
  - #73: Playlist — drag-reorder tracks
  - #74: Playlist — remove tracks (multi-select)
  - #75: Playlist — rename, duplicate, delete
  - #235: Drag-reorder tracks (same-issue alt perspective)
  - #236: Add / remove tracks (same-issue alt perspective)
- **Skipped (in flight):** #72 Add-to-Playlist popover (PR #504), #234 hero (PR #511), #126 create_playlist (PR #503), #127 add_to_playlist (PR #504).
- **Files expected to touch:**
  - `macos/Sources/Jellify/Screens/PlaylistDetailView.swift` (new — does not exist)
  - `macos/Sources/Jellify/Components/Sidebar.swift` (inline rename)
  - `macos/Sources/Jellify/Components/PlaylistContextMenu.swift`
- **Rationale:** Six issues all modify playlist-detail ergonomics. Needs core APIs #128, #129, #130, #131 — coordinate with BATCH-10.
- **Suggested agent prompt:**
  > Implement #71, #73, #74, #75, #235, #236 together. **Depends on core APIs #128 (in PR #504? verify), #129, #130, #131** — if those aren't landed yet, add stubs calling through to `core.remove_from_playlist`, `core.move_playlist_item`, `core.update_playlist`, `core.delete_playlist` and annotate with `// TODO(core-#129)`. Create `macos/Sources/Jellify/Screens/PlaylistDetailView.swift`. In `Sidebar.swift`: Cmd+N creates a playlist inline in edit mode (#71); right-click → Rename (inline), Duplicate (copies tracks via `create_playlist` + `add_to_playlist`), Delete (confirm dialog) per #75. In `PlaylistDetailView`: Cmd+Click / Shift+Click multi-select, Delete/Backspace removes with undo toast (#74); rows draggable with grabber handle, drop indicator line, persists via `move_playlist_item` (#73 + #235); add/remove via per-row `-` button or drag-in from library (#236). Acceptance: all mutations round-trip to the server; undo works for 10s. Reference all 6 issue numbers. Do NOT rewrite the PlaylistHero — that's PR #511.
- **Estimated effort:** ~4M + 2S = ~5 agent-days. (Large — agent may split into two if needed.)

---

## BATCH-07 · macOS Queue inspector panel + context label

- **Priority:** p0
- **Platform:** macos
- **Issues:**
  - #79: Queue — right-side Up Next inspector panel
  - #80: Queue — drag reorder + remove within Up Next
  - #82: Queue — "Playing from [context]" persistent label
  - #282: Up Next vs Auto Queue separation
  - #283: Drag reorder within queue
  - #284: Queue actions — Clear / Save / Shuffle
- **Files expected to touch:**
  - `macos/Sources/Jellify/Components/QueueInspector.swift` (new)
  - `macos/Sources/Jellify/Screens/MainShell.swift` (inspector mount point, after BATCH-01 lands)
  - `macos/Sources/Jellify/AppModel.swift` (queue state + context metadata)
  - `macos/Sources/Jellify/Components/PlayerBar.swift` ("Playing from" label)
- **Rationale:** One right-side panel, three stacked sections, consistent drag model. Issues #79/80/82 from one source; #282/283/284 from another — collapsed to one batch to prevent two agents racing for the same file.
- **Suggested agent prompt:**
  > Implement #79, #80, #82, #282, #283, #284 together. Create `macos/Sources/Jellify/Components/QueueInspector.swift`: toggleable 320pt right-side panel. Structure: (1) Now Playing card at top with scrubber, (2) UP NEXT section (user-added queue, draggable via `.onMove`, remove with X on hover, #80 + #283, keyboard reorder via Opt+↑/↓), (3) PLAYING FROM {source} section (auto-queue, read-only, jump-to-only, #82 + #282). Header actions: Clear (confirm sheet "Clear N items?"), Save (modal → playlist name → `create_playlist` + `add_to_playlist`), Shuffle (in-place shuffle, keeps Now Playing first) per #284. Mount in `MainShell.swift` (requires BATCH-01's `NavigationSplitView` landed). Update `PlayerBar.swift` to also show the "Playing from {context}" label (clickable, navigates to source). Split queue state in `AppModel.swift` into `upNextUserAdded: [Queue]` + `upNextAutoQueue: [Queue]` + `currentContext: QueueContext?`. Acceptance: reorder persists in-app; Save → playlist round-trips; context label clickable. Reference all 6 issue numbers. Do NOT touch the full-screen player — that's BATCH-08.
- **Estimated effort:** ~2L + 2M + 2S = ~7 agent-days. (Large — consider splitting Now Playing + Up Next list and queue actions to separate PRs.)

---

## BATCH-08 · macOS Now Playing (full player) + lyrics view

- **Priority:** p0
- **Platform:** macos
- **Issues:**
  - #89: Lyrics — full-screen lyrics view with time sync
  - #91: Lyrics — inline mode in Now Playing (p1)
  - #272: Full player — queue drawer (p1)
  - #273: Full player — lyrics drawer (p1)
  - #278: Now Playing — About block
  - #287: Parse LRC / timed lyrics
  - #288: Auto-scroll + active line highlight
- **Skipped (in flight):** #279 Credits block (PR #508).
- **Files expected to touch:**
  - `macos/Sources/Jellify/Screens/NowPlayingView.swift` (new)
  - `macos/Sources/Jellify/Components/LyricsView.swift` (new)
  - `macos/Sources/JellifyCore/JellifyCore.swift` (if `track_lyrics` needs a thin wrapper — requires core #162)
- **Rationale:** A single full-screen Now Playing view with tabs/drawers for lyrics, queue, about, credits. Splitting = visual inconsistency between drawers.
- **Suggested agent prompt:**
  > Implement #89, #91, #272, #273, #278, #287, #288 together. Create `macos/Sources/Jellify/Screens/NowPlayingView.swift` + `macos/Sources/Jellify/Components/LyricsView.swift`. Takes over the detail column (not a modal). Layout: large album art left, right pane with a segmented picker toggling between Queue drawer (#272), Lyrics drawer (#273, inline mode #91), About block (#278) — Credits block is already done in PR #508, coexist with it. Lyrics parsing (#287): add `track_lyrics(track_id)` stub to core if core #162 isn't landed (`// TODO(core-#162)`); parse LRC timestamps `[mm:ss.ff]lyric` into `[(timestamp, line)]`. Auto-scroll (#288): tick every 200ms against `playerProgress`, active line = last whose timestamp ≤ now, `ScrollViewReader.scrollTo(.center)` with 300ms ease. Full-screen entry via quote-icon in PlayerBar or Cmd+Opt+L. Acceptance: lyrics scroll smoothly; non-LRC lyrics render as static text; Reduce Motion disables scroll animation. Reference all 7 issue numbers. Do NOT rewrite the Queue inspector — BATCH-07 owns that, reuse its component.
- **Estimated effort:** ~1L + 5M + 1S = ~7 agent-days. (Large — split lyrics + now-playing if agent runs long.)

---

## BATCH-09 · macOS Search (instant dropdown, full page, scope, recent, no-results)

- **Priority:** p0
- **Platform:** macos
- **Issues:**
  - #85: Search — instant-results dropdown with "Top Result" hero
  - #86: Search — full search results page
  - #241: Instant-search with debounced fetch
  - #242: Scope chips
  - #243: Top Result hero card
  - #244: Results sections layout
  - #245: No-results state (p1)
  - #246: Recent searches with per-item clear (p1)
- **Files expected to touch:**
  - `macos/Sources/Jellify/Screens/SearchView.swift`
  - `macos/Sources/Jellify/Components/SearchInstantDropdown.swift` (new)
  - `macos/Sources/Jellify/AppModel.swift` (search state + `recentSearches: [String]` in `@AppStorage`)
- **Rationale:** Eight issues all touch the same search flow (toolbar field → debounced instant dropdown → full results page). Splitting = wasted context.
- **Suggested agent prompt:**
  > Implement #85, #86, #241, #242, #243, #244, #245, #246 together. Build two pieces: (1) `SearchInstantDropdown.swift` anchored to the toolbar search field (requires BATCH-01's toolbar), shown while focused + query non-empty. 250ms debounce → `core.search(query)` (cancel previous in-flight). Sections: Top Result hero card (large thumbnail + type label + 52pt accent-circle play btn, ranking per #243), then Artists (6 circles), Albums (5-col grid), Tracks (up to 8 rows), Playlists (5-col grid), Genres (horizontal tile row). (2) `SearchView.swift` as the full page: tabs All/Artists/Albums/Tracks/Playlists/Genres, ~20 per category, paginated per-tab. Scope chips below the input (#242) filter the result set. Empty query state shows recent searches (last 10 in `@AppStorage`) with per-row clear + footer "Clear history" per #246. No-results state (#245) suggests "Try: artist name only" + "Search Jellyfin metadata" remote-search CTA. Acceptance: all sections render; Cmd+F opens dropdown; Return navigates to full page; tab state preserved on back-nav. Reference all 8 issue numbers. Do NOT touch the Command Palette — BATCH-12 owns that.
- **Estimated effort:** ~2L + 3M + 3S = ~8 agent-days. (Large — split instant dropdown vs full page if needed.)

---

## BATCH-10 · macOS Context menus (tracks, albums, artists, playlists, genres, multiselect)

- **Priority:** p0
- **Platform:** macos
- **Issues:**
  - #15: Add context menus to track rows, album cards, artist rows, and sidebar items
  - #95: Context menu — tracks
  - #96: Context menu — albums
  - #97: Context menu — artists
  - #98: Context menu — playlists (sidebar)
  - #310: Track context menu (duplicate of #95)
  - #314: Genre context menu (p1)
  - #315: Multiselect track context menu (p1)
- **Files expected to touch:**
  - `macos/Sources/Jellify/Components/AlbumContextMenu.swift`
  - `macos/Sources/Jellify/Components/ArtistContextMenu.swift`
  - `macos/Sources/Jellify/Components/PlaylistContextMenu.swift`
  - `macos/Sources/Jellify/Components/TrackContextMenu.swift` (new)
  - `macos/Sources/Jellify/Components/GenreContextMenu.swift` (new)
  - `macos/Sources/Jellify/Components/TrackListRow.swift`, `TrackRow.swift`, `AlbumCard.swift`, `ArtistCard.swift` (call sites)
- **Rationale:** One consistent context-menu story across all item types. Splitting = divergent menu order / action sets.
- **Suggested agent prompt:**
  > Implement #15, #95, #96, #97, #98, #310, #314, #315 together. Audit every existing `AlbumContextMenu.swift`, `ArtistContextMenu.swift`, `PlaylistContextMenu.swift` for completeness against the spec, add `TrackContextMenu.swift` + `GenreContextMenu.swift`. Menu orders (EXACT order; match Apple Music + Spotify convention):
  > - **Track**: Play (↩), Play Next, Add to Queue, — , Start Song Radio, Add to Playlist… (submenu), —, Go to Album, Go to Artist, Show Track Info, —, Favorite/Unfavorite, Download/Remove Download, Mark as Played/Unplayed, —, Copy Link, Share
  > - **Album**: Play, Shuffle, Play Next, Add to Queue, —, Start Album Radio, Add to Playlist →, —, Go to Artist, Go to Album, —, Favorite Album, Mark All as Played, —, Download, Edit Album…, Copy Link
  > - **Artist**: Play All, Shuffle All, Play Next, —, Start Artist Radio, —, Follow/Unfollow, Go to Artist Page, —, Copy Link, Share
  > - **Playlist (sidebar)**: Play, Shuffle, Play Next, Add to Queue, —, Rename (inline), Duplicate, Delete (confirm), —, Export as .m3u8…, Copy Link
  > - **Genre**: Browse genre, Start genre radio, Shuffle genre, —, Pin to Home
  > - **Multi-select track**: same as single but omits Go-to actions; adds Remove from Playlist when scoped to a playlist.
  >
  > Wire every menu via `.contextMenu { … }` on the relevant call-site view. Delete confirmation uses a `.confirmationDialog`. Acceptance: right-click any item type → menu appears with the exact order above. Reference all 8 issue numbers. Do NOT reimplement the playlist CRUD mutations — BATCH-06 owns those.
- **Estimated effort:** ~2S + 1M + 1M + 4S = ~4 agent-days.

---

## BATCH-11 · Core API — p0 playback + session registration + library resolution

- **Priority:** p0
- **Platform:** core
- **Issues:**
  - #128: Add `remove_from_playlist`
  - #138: Add `report_playback_started`
  - #142: Add `playback_info` (POST — canonical)
  - #157: Add library resolution (`/UserViews` + playlist library)
  - #169: Add `post_capabilities` (session registration)
  - #174: Add `DeviceProfile` model + default builder
- **Files expected to touch:**
  - `core/src/client.rs`
  - `core/src/models.rs`
  - `core/src/lib.rs` (UniFFI)
  - `core/src/tests.rs`
  - `macos/Sources/JellifyCore/Generated/` (regenerated bindings)
- **Rationale:** All six are new methods on `JellifyClient` + shared DTOs (`DeviceProfile`, `PlaybackInfoResponse`, `Library`). They touch the same client file and shared structs. Splitting = FFI regen conflicts.
- **Suggested agent prompt:**
  > Implement core issues #128, #138, #142, #157, #169, #174 together. Add to `core/src/client.rs`:
  > - `post_capabilities(caps: ClientCapabilities) -> Result<()>` (#169) — POST `/Sessions/Capabilities/Full`
  > - `playback_info(item_id: &str, opts: PlaybackInfoOpts) -> Result<PlaybackInfoResponse>` (#142) — POST `/Items/{id}/PlaybackInfo`
  > - `report_playback_started(info: PlaybackStartInfo) -> Result<()>` (#138) — POST `/Sessions/Playing`
  > - `user_views() -> Result<Vec<Library>>`, `music_library_id() -> Result<String>`, `playlist_library_id() -> Result<String>` (#157)
  > - `remove_from_playlist(playlist_id: &str, entry_ids: &[String]) -> Result<()>` (#128)
  >
  > Add `models.rs`: `DeviceProfile` + `default_macos_profile()` advertising FLAC/ALAC/MP3/AAC/Opus/OGG/WAV direct-play + MP3 320 transcode fallback (#174). Add `PlaybackStartInfo`, `PlaybackInfoOpts`, `PlaybackInfoResponse`, `MediaSourceInfo`, `Library`, `ClientCapabilities` wire structs with `#[serde(rename_all = "PascalCase")]`. Expose everything through UniFFI in `lib.rs`. Regenerate Swift bindings with `./Scripts/build-core.sh`. Add unit tests against recorded Jellyfin responses (existing harness in `core/src/tests.rs`). Acceptance: `cargo test --workspace` passes; Swift side sees new types; `swift build` in `macos/` is clean. Reference all 6 issue numbers. Do NOT add `instant_mix`, `similar_artists`, or any p1 endpoints — they're a separate batch.
- **Estimated effort:** ~3M + 3S = ~4.5 agent-days. **Upstream:** unblocks BATCH-03, BATCH-06, BATCH-14.

---

## BATCH-12 · macOS Command Palette (⌘K)

- **Priority:** p0
- **Platform:** macos
- **Issues:**
  - #305: Command palette shell + shortcut
  - #306: Palette — library search integration
  - #307: Palette — actions (verbs, not nouns)
  - #309: Palette — keyboard-only UX
  - #19: Build a Cmd+K command palette (spotlight-style) — p1 but same feature
  - #308: Palette — recent + pinned (p1)
- **Files expected to touch:**
  - `macos/Sources/Jellify/Components/CommandPalette.swift` (new)
  - `macos/Sources/Jellify/JellifyApp.swift` (Cmd+K binding + scene)
  - `macos/Sources/Jellify/AppModel.swift` (action registry)
- **Rationale:** One new component, one global shortcut. Splitting = divergent UX.
- **Suggested agent prompt:**
  > Implement #19, #305, #306, #307, #308, #309 together. Create `macos/Sources/Jellify/Components/CommandPalette.swift` as a full-screen overlay. Cmd+K toggles (bound globally in `JellifyApp.swift`'s `.commands {}`). Dim background to `scrim-76`. 18pt Figtree input, autofocus, 80ms debounce. Two result modes:
  > - Library search (#306): artists, albums, tracks, playlists via `core.search`; rows show type-icon + primary + secondary + hint ("↩ Play").
  > - Actions (#307): static verb list — Play, Play Next, Add to Queue, Go to Library, Go to Home, Go to Discover, Open Preferences, Toggle Shuffle, Toggle Repeat, Clear Queue, Download Current…
  >
  > Empty-query state (#308): last 5 executed commands + 5 pinned items (right-click pin). Keyboard-only UX (#309): ↑↓ navigate, ↩ execute, ⌘↩ new window, Esc closes, ⌘1–5 switches group filters (All / Artists / Albums / Tracks / Actions). All hints in 10pt `ink3` footer. Acceptance: Cmd+K anywhere opens palette; 80ms debounce visible; no mouse required; recent commands persist across launches via `@AppStorage`. Reference all 6 issue numbers. Do NOT touch the toolbar search (BATCH-09 owns that).
- **Estimated effort:** ~4M + 2S = ~5 agent-days.

---

## BATCH-13 · macOS Home screen carousels (Jump Back In, Recently Played, Recently Added, Quick Picks, Favorites)

- **Priority:** p0
- **Platform:** macos
- **Issues:**
  - #49: Home — layout scaffolding with sectioned carousels
  - #51: Home — "Jump Back In" row (last-played albums)
  - #52: Home — "Recently Played" row (tracks)
  - #54: Home — "Recently Added" row
  - #53: Home — "Quick Picks" (heavy rotation, last 30 days) (p1)
  - #55: Home — "Favorites" carousel with shuffle CTA (p1)
- **Skipped (in flight):** #204 Home greeting header (PR #509), #249 For You (PR #513), #253 Pinned stations (PR #506).
- **Files expected to touch:**
  - `macos/Sources/Jellify/Screens/HomeView.swift`
  - `macos/Sources/Jellify/Components/HomeQuickTile.swift` (reuse)
  - `macos/Sources/Jellify/AppModel.swift` (data fetches)
- **Rationale:** All six carousels are sibling rows on `HomeView`. Single view = single agent.
- **Suggested agent prompt:**
  > Implement #49, #51, #52, #53, #54, #55 together. In `macos/Sources/Jellify/Screens/HomeView.swift` (coexist with the greeting header from PR #509 and the Pinned Stations + For You rows from PRs #506/#513): build vertical stack of horizontally-scrollable carousels. Each section = header (title, optional subtitle, "See All" button) + 8–12 items in a row; row heights: 180pt albums/playlists, 220pt tracks-with-artwork, 140pt artists. Rows:
  > - Jump Back In (#51): `core.items_query().item_type(MusicAlbum).sort_by(DatePlayed).filter_is_played().limit(12)`; 180pt album tiles; click plays, double-click opens detail.
  > - Recently Played (#52): `core.items_query().item_type(Audio).sort_by(DatePlayed).limit(20)`; compact track rows with thumbnail.
  > - Recently Added (#54): `/Users/{userId}/Items/Latest?Limit=20`; NEW badge for items within last 7 days.
  > - Quick Picks (#53): `core.items_query().item_type(MusicAlbum).sort_by(PlayCount).filter(date_played > now - 30d).limit(12)`.
  > - Favorites (#55): random shuffled favorite albums, 12 visible, "Shuffle All Favorites" CTA → load all favorite tracks + shuffle.
  >
  > Use existing `HomeQuickTile.swift` + any new row component. Acceptance: scroll momentum + two-finger swipe work; SeeAll navigates to filtered library view. Reference all 6 issue numbers. Do NOT touch the greeting header (PR #509) or Pinned Stations (PR #506). If BATCH-24 (ItemsQuery) isn't landed, inline raw `GET /Items` calls with `// TODO(core-#465)` annotations.
- **Estimated effort:** ~2M + 1S + 2M + 1S = ~4 agent-days.

---

## BATCH-14 · MPRemoteCommand shuffle / repeat / favorite + core wiring

- **Priority:** p0 core blocker → p1 feature
- **Platform:** macos (audio) + core
- **Issues:**
  - #34: Wire shuffleCommand / repeatCommand (stateful toggles) — p1 but blocks polish
  - #35: Wire likeCommand / dislikeCommand to Jellyfin favorites — p1 but related
- **Files expected to touch:**
  - `core/src/player.rs` (extend `PlayerStatus` with `shuffle: bool`, `repeat_mode: RepeatMode`)
  - `core/src/client.rs` (add `set_favorite(item_id:, favorite:)`)
  - `core/src/lib.rs` (UniFFI re-export)
  - `macos/Sources/JellifyAudio/MediaSession.swift` (wire remote commands — coordinate with BATCH-03)
- **Rationale:** Both touch core's `PlayerStatus` + `MediaSession`. Same surface, two issues, pair them.
- **Suggested agent prompt:**
  > Implement #34 and #35 together. In `core/src/player.rs`: extend `PlayerStatus` with `shuffle: bool`, `repeat_mode: RepeatMode { Off, One, All }`. Add `core.set_shuffle(on: bool)` + `core.set_repeat_mode(mode:)`. In `core/src/client.rs`: add `set_favorite(item_id: &str, favorite: bool) -> Result<()>` calling POST/DELETE `/Users/{userId}/FavoriteItems/{itemId}`. Regenerate UniFFI bindings. In `macos/Sources/JellifyAudio/MediaSession.swift` (coordinate with BATCH-03 — do not duplicate MPRemoteCommand registration, extend what's there): wire `changeShuffleModeCommand` (map `MPShuffleType.items ↔ shuffle=true`), `changeRepeatModeCommand` (map all 3 modes), `likeCommand` (toggle favorite; `likeCommand.isActive = track.isFavorite` on track change), leave `dislikeCommand` disabled. Acceptance: Control Center shuffle/repeat toggles work; heart toggles the actual Jellyfin favourite; bindings pass `cargo test`; `swift build` clean. Reference both issue numbers.
- **Estimated effort:** ~2M = ~2 agent-days.

---

## BATCH-15 · macOS Empty states + error banners + loading skeletons

- **Priority:** p0
- **Platform:** macos
- **Issues:**
  - #99: Empty state — first-run (logged in, no library)
  - #100: Loading state — skeleton shimmer matching target grid
  - #101: Error state — network disconnected
  - #102: Error state — stream error / playback failure
  - #297: Empty favorites (p1)
  - #298: Empty downloads (p1)
  - #299: Empty playlist (p1)
  - #302: Stream failed (p1 — same area)
- **Files expected to touch:**
  - `macos/Sources/Jellify/Components/EmptyLibraryState.swift`
  - `macos/Sources/Jellify/Components/OfflineBanner.swift`
  - `macos/Sources/Jellify/Components/ServerUnreachableBanner.swift`
  - `macos/Sources/Jellify/Components/LoadingSkeleton.swift` (new)
  - `macos/Sources/Jellify/Components/StreamErrorToast.swift` (new)
  - `macos/Sources/Jellify/Components/EmptyStateView.swift` (new shared)
- **Rationale:** One shared `EmptyStateView` + one shared skeleton primitive + banner set, used everywhere. Splitting = duplicated primitives.
- **Suggested agent prompt:**
  > Implement #99, #100, #101, #102, #297, #298, #299, #302 together. Create `EmptyStateView.swift` as a shared component (illustration, headline, body copy, optional CTAs). Drive per-screen:
  > - First-run no-library (#99): turntable illustration, "No music yet," "Change Library" CTA.
  > - Empty favorites (#297): "No favorites yet." + heart glyph.
  > - Empty downloads (#298): "Nothing offline yet." + download glyph.
  > - Empty playlist (#299): "Empty playlist." + `+` glyph.
  >
  > Create `LoadingSkeleton.swift` with rectangles sized per use-case (180pt album tiles, 56pt track rows); 200ms linear gradient shimmer; Reduce Motion = static gray; crossfade to real content over 120ms on data arrival. Update `OfflineBanner.swift` for #101 (top-of-window "Can't reach [server]. Trying again…" + Retry). Create `StreamErrorToast.swift` for #102 + #302: "{Track} couldn't play. Skipping." + Retry + Go-to-track; PlayerBar flashes danger 10% tint. Do not silently advance. Acceptance: each empty state renders on the right screen; shimmer respects Reduce Motion; banners dismiss with flash on reconnect. Reference all 8 issue numbers. Do NOT add a full offline mode (that's #441, separate batch).
- **Estimated effort:** ~3S + 1M + 2S + 2S = ~3 agent-days.

---

## BATCH-16 · macOS Onboarding + login flow

- **Priority:** p0
- **Platform:** macos
- **Issues:**
  - #111: Onboarding — login screen with server discovery
  - #200: Login screen chrome + layout
  - #201: Inline server URL validation
  - #203: Login error + offline states (p1)
  - #291: Welcome step (p1)
  - #292: Connect server step (p1)
  - #293: First sync step + progress (p1)
- **Files expected to touch:**
  - `macos/Sources/Jellify/Screens/LoginView.swift`
  - `macos/Sources/Jellify/Screens/OnboardingView.swift` (new — 3-step flow)
  - `macos/Sources/Jellify/ServerReachability.swift` (URL validation)
- **Rationale:** All onboarding + login ergonomics in one place. Splitting = divergent look.
- **Suggested agent prompt:**
  > Implement #111, #200, #201, #203, #291, #292, #293 together. Build `OnboardingView.swift` as a 3-step flow: Welcome (#291 — jellyfish mark 120pt, "Welcome to Jellify" italic 48pt, tagline, Get Started CTA), Connect Server (#292 — same fields as login + helper "Your Jellyfin URL is the address you use to reach it from a browser" + Skip-explore-offline link), First Sync (#293 — "Loading your library" progress animated artists→albums→tracks→artwork, live counter "4,208 tracks · 312 artists · 586 albums", Continue to Home on completion). Rewrite `LoginView.swift` per #200: full-window `#0C0622` background, draggable title bar, centered 420×auto column, Figtree 40pt italic 800 brand, no sidebar/player bar. Server URL field: Bonjour/mDNS-discovered servers dropdown if any found on LAN (#111). Inline validation (#201): 400ms debounce → `core.public_info()` → "Jellyfin vX.Y.Z" on success, generic error on fail. Login errors (#203): 401 → shake password + "Wrong username or password"; offline → banner "No network"; repeated unreachable → "Last connected {date}. Trying offline mode." Acceptance: first launch shows Onboarding; logged-out subsequent launch shows Login directly. Reference all 7 issue numbers. Do NOT touch any Home/Library/Player screens.
- **Estimated effort:** ~2M + 1S + 4S = ~4 agent-days.

---

## BATCH-17 · macOS Preferences — remaining p0 sections

- **Priority:** p0
- **Platform:** macos
- **Issues:**
  - #114: Settings — top-level organization
  - #115: Settings — Server section
  - #116: Settings — Playback section
  - #117: Settings — Audio quality section
- **Skipped (in flight):** #259 Account (PR #507), #260 Playback (PR #505 — overlap risk, verify), #263 Appearance (PR #510).
- **Files expected to touch:**
  - `macos/Sources/Jellify/Screens/Preferences/PreferencesView.swift`
- **Rationale:** One `PreferencesView.swift` hosts all sections. PRs #505/507/510 already modify it — this batch picks up the sections not yet claimed.
- **Suggested agent prompt:**
  > Implement #114, #115, #116, #117 together. **First: read PRs #505, #507, #510 to see the shape already established in `macos/Sources/Jellify/Screens/Preferences/PreferencesView.swift`** — do NOT duplicate the Playback/Account/Appearance sections those PRs add. Build the top-level macOS System Settings-style organization (#114) with left sidebar sections: General, Server, Playback, Audio, Library, Appearance, Downloads, About. Fill in:
  > - Server section (#115): current URL, server name, server version, connected user avatar + name, "Switch Server" / "Sign Out" / "Change User" buttons.
  > - Playback section (#116): If PR #505 is landed, verify what's already there and fill gaps — Crossfade (Off / 1–12s slider), Gapless default-on, Normalization (Off / Track / Album — ReplayGain if tags), Pre-gain ±12dB, Stop after current.
  > - Audio quality section (#117): Streaming quality (Low 96 / Normal 192 / High 320 / Lossless / Original), Download quality (same), Transcoding preference (Direct Play when possible / Always Transcode).
  >
  > Acceptance: settings round-trip to `core.preferences_store`; `Cmd+,` opens the window. Reference all 4 issue numbers. If section boundaries conflict with open PRs, narrow scope to just General + Audio and note the overlap.
- **Estimated effort:** ~2M + 2S = ~3 agent-days.

---

## BATCH-18 · macOS Distribution pipeline part 1 (prerequisites, signing, notarization)

- **Priority:** p0
- **Platform:** macos (dist)
- **Issues:**
  - #175: Enroll in the Apple Developer Program and request a Developer ID Application certificate
  - #176: Register the bundle ID and reserve `jellify://` URL scheme
  - #177: Switch the bundler to a real Info.plist driven from a template
  - #178: Add entitlements file with the minimal hardened-runtime surface
  - #179: Build a universal xcframework (arm64 + x86_64)
  - #180: Standalone signing script — `macos/Scripts/sign.sh`
  - #181: Notarization script using `notarytool` + keychain profile
  - #182: DMG creation via `create-dmg`
- **Files expected to touch:**
  - `macos/Scripts/make-bundle.sh`
  - `macos/Scripts/build-core.sh`
  - `macos/Scripts/sign.sh` (new)
  - `macos/Scripts/notarize.sh` (new)
  - `macos/Scripts/make-dmg.sh` (new)
  - `macos/Resources/Info.plist` (new template)
  - `macos/Resources/Jellify.entitlements` (new)
- **Rationale:** Continuous scripting pipeline — bundle, sign, notarize, DMG. Must be consistent; one worker owns the whole chain.
- **Suggested agent prompt:**
  > Implement #175, #176, #177, #178, #179, #180, #181, #182 together. Note #175 is a non-engineering blocker (Apple Developer Program enrollment — multi-day lead time; add a block comment at the top of the plan pointing the user to do this manually) — produce everything else assuming certificate exists. Create `macos/Resources/Info.plist` as a template (not heredoc) with `org.jellify.desktop` bundle ID, `jellify://` URL scheme, copyright, version placeholders. Have `make-bundle.sh` use `plutil -replace` to inject `$VERSION` / `$BUILD` from env. Add `macos/Resources/Jellify.entitlements` with the minimal hardened-runtime surface (no entitlements = default, add only `com.apple.security.automation.apple-events` + `com.apple.security.network.client` as needed). Extend `build-core.sh` to build universal xcframework (arm64 + x86_64; use `lipo` to merge). Add `sign.sh` (codesigns inside-out with hardened runtime), `notarize.sh` (uses `xcrun notarytool submit --wait` with `NOTARY_PROFILE` env var), `make-dmg.sh` (uses `create-dmg` via brew). Acceptance: `./Scripts/make-bundle.sh && ./Scripts/sign.sh && ./Scripts/notarize.sh && ./Scripts/make-dmg.sh` produces a notarized stapled DMG on the reviewer's Mac. Document the Developer ID setup steps in `macos/DISTRIBUTION.md`. Reference all 8 issue numbers. Do NOT set up Sparkle or CI yet — those are BATCH-19.
- **Estimated effort:** ~5S + 4M = ~6.5 agent-days. Large — split into two PRs if agent runs long (bundle+entitlements, then sign+notarize+dmg).

---

## BATCH-19 · macOS Distribution pipeline part 2 (Sparkle, GitHub Release, CI)

- **Priority:** p0
- **Platform:** macos (dist)
- **Issues:**
  - #183: App icon pipeline — SVG → `.iconset` → `.icns`
  - #184: Integrate Sparkle 2 as a Swift Package dependency
  - #185: Generate EdDSA signing keypair for Sparkle and store it
  - #186: `appcast.xml` generation and GitHub Pages hosting
  - #188: GitHub Release automation with `gh release create`
  - #189: GitHub Actions release workflow on tag push
  - #190: GitHub Actions secrets inventory + rotation runbook
- **Files expected to touch:**
  - `macos/Package.swift` (Sparkle dep)
  - `macos/Scripts/make-iconset.sh` (new)
  - `macos/Scripts/generate-appcast.sh` (new)
  - `.github/workflows/macos-release.yml` (new)
  - `macos/DISTRIBUTION.md` (extend)
  - `design/icons/jellify-app.svg` (verify exists / request)
- **Rationale:** Downstream of BATCH-18. Auto-update + release automation, one coherent pipeline.
- **Suggested agent prompt:**
  > Implement #183, #184, #185, #186, #188, #189, #190 together. **Depends on BATCH-18 (sign/notarize/dmg scripts).** Add `make-iconset.sh`: source `design/icons/jellify-app.svg` → sips-rendered `.iconset` → `iconutil -c icns` → bundle icon at the right path. Add Sparkle 2 via SPM in `macos/Package.swift` (from 2.6.0). Document keypair generation (`./Sparkle/bin/generate_keys`; private in login keychain). Add `generate-appcast.sh` producing `appcast.xml` signed with EdDSA, hosted on `gh-pages`. Add `.github/workflows/macos-release.yml`: trigger on `v*` tag push, run on `macos-14` (Apple Silicon), cache cargo, build universal xcframework, call sign → notarize → DMG → `gh release create vX.Y.Z --title "Jellify X.Y.Z" --notes-file CHANGELOG` with DMG as asset, regenerate + publish appcast. Inventory all required secrets in `macos/DISTRIBUTION.md` (`APPLE_DEVELOPER_ID_CERT_P12`, `APPLE_NOTARY_PROFILE`, `SPARKLE_ED25519_PRIVATE`, `GITHUB_TOKEN`) with rotation instructions. Acceptance: `git tag v0.1.0 && git push --tags` triggers a green CI run that produces a GitHub Release with signed DMG + updates the appcast. Reference all 7 issue numbers. Do NOT touch app code.
- **Estimated effort:** ~1S + 2M + 1M + 1M + 1L + 1S = ~6 agent-days.

---

## BATCH-20 · Perf — artwork loading + virtualized grid

- **Priority:** p0
- **Platform:** perf / macos
- **Issues:**
  - #426: Replace `AsyncImage` with Nuke for artwork loading
  - #427: Size-hinted thumbnail URLs + decode downscaling
  - #428: Virtualized library grid with correct recycling
- **Files expected to touch:**
  - `macos/Sources/Jellify/Components/Artwork.swift`
  - `macos/Sources/Jellify/Components/AlbumCard.swift`
  - `macos/Sources/Jellify/Components/ArtistCard.swift`
  - `macos/Sources/Jellify/Screens/LibraryView.swift`
  - `macos/Package.swift` (Nuke dep)
- **Rationale:** All three issues target artwork rendering perf. Interconnected: new loader → size-hinted URLs → virtualized grid. Split work = inconsistent cache key space.
- **Suggested agent prompt:**
  > Implement #426, #427, #428 together. Add Nuke to `macos/Package.swift`. Replace `SwiftUI.AsyncImage` in `Artwork.swift` with a Nuke-backed `LazyImage` variant that supports disk cache, deduplication, background decode, memory-pressure eviction. Add size hints: propagate a `targetPixelSize` parameter (180pt grid = ~360px @2x / 540px @3x; 48pt row = ~96px @2x) and append `maxWidth=N` to `imageURL(...)` accordingly. Downscale decoded images to display size (not source size) via Nuke's `ImageProcessors.Resize`. Virtualize `LibraryView.swift`'s grid: use `LazyVGrid` inside `ScrollView` but remove per-cell `@State var isHovering` (moves to one shared modifier) to prevent live view-tree holding 10k cells — track hover at the container level and publish via env. Acceptance: scroll a 5k-album library at 120fps on M1 Mac Mini; memory cap stable; no stutter on initial decode. Reference all 3 issue numbers.
- **Estimated effort:** ~2M + 1S = ~2.5 agent-days.

---

## BATCH-21 · Reliability — retry + re-auth + stall recovery

- **Priority:** p0
- **Platform:** reliability / core + macos
- **Issues:**
  - #438: Retry layer with exponential backoff + jitter on `reqwest`
  - #439: AVPlayer stall recovery + user-visible retry
  - #440: Detect 401 and silently re-auth with keyring credentials
- **Files expected to touch:**
  - `core/src/client.rs` (retry middleware + 401 interceptor)
  - `core/src/storage.rs` (re-read keyring on 401)
  - `macos/Sources/JellifyAudio/AudioEngine.swift` (stall observation)
- **Rationale:** Three reliability patches across the HTTP + player stack. Related; share infra (error classification, retry policy).
- **Suggested agent prompt:**
  > Implement #438, #439, #440 together. In `core/src/client.rs`: add a `reqwest` middleware that classifies response → retriable (timeouts, 5xx except 501, 429 honouring `Retry-After`, conn-reset, conn-refused) vs terminal. Backoff: exponential 0.2s → 0.4s → 0.8s → 1.6s with ±15% jitter, max 3 attempts. Log each retry at `tracing::warn`. On 401, call `storage::refresh_token_from_keyring()` (re-read credentials, POST `/Users/AuthenticateByName`, retry the original request once). If keyring re-auth fails, surface `JellifyError::AuthExpired` for the UI to prompt re-login. In `macos/Sources/JellifyAudio/AudioEngine.swift`: observe `player.timeControlStatus`. When `.waitingToPlayAtSpecifiedRate` persists > 5s, surface a toast "Stalled, retrying..." and call `player.replaceCurrentItem(with: AVPlayerItem(url: currentURL))` to restart the stream. Max 2 auto-retries before surfacing "Couldn't play, tap to retry." Acceptance: kill the network mid-stream → player recovers within 10s; invalidate the token server-side → subsequent API calls succeed silently. Reference all 3 issue numbers.
- **Estimated effort:** ~3M = ~3 agent-days.

---

## BATCH-22 · a11y — VoiceOver labels + focus + Dynamic Type

- **Priority:** p0
- **Platform:** macos (a11y)
- **Issues:**
  - #331: Give every icon-only Button a VoiceOver label
  - #332: Make the progress bar an accessible Slider with scrub + value
  - #334: Logical tab order + Shift-Tab reverse traversal
  - #337: Dynamic Type — Figtree + scaledFont
  - #343: Toolbar, menu bar, and window menu accessibility
- **Files expected to touch:**
  - `macos/Sources/Jellify/Components/PlayerBar.swift`
  - `macos/Sources/Jellify/Components/TrackRow.swift`, `TrackListRow.swift`, `AlbumCard.swift`, `ArtistCard.swift`
  - `macos/Sources/Jellify/Theme/Theme.swift` (Font scaling)
  - `macos/Sources/Jellify/Screens/MainShell.swift` (tab order)
- **Rationale:** Cross-cutting a11y audit. One worker sweeps the codebase once; splitting = missed surfaces.
- **Suggested agent prompt:**
  > Implement #331, #332, #334, #337, #343 together. Audit every icon-only `Button` in the macOS sources — if a button's child is an `Image(systemName:)`, it must have `.accessibilityLabel("Play" / "Pause" / "Next" etc.)` bound to semantic state (not the SF symbol name). In `PlayerBar.swift`: replace the bespoke progress-bar (`GeometryReader` + two `Capsule`s, lines 79–88) with a real `Slider` bound to `playerProgress`, with `.accessibilityLabel("Playback position")` + value formatted as "0:34 of 3:42". In `Theme/Theme.swift`: refactor `Theme.font(_:weight:italic:)` to use `.scaledFont(name:size:)` so Text scales with the user's Text Size preference. In `MainShell.swift`: ensure logical tab order — sidebar first, then primary content, then toolbar, then player bar. Reverse traversal (Shift+Tab) must mirror forward. Ensure toolbar items (including ones added in BATCH-01), the menu bar (BATCH-02), and window-control menu all expose accessibility labels + roles. Acceptance: enable VoiceOver → every control announced with a human label; enable System Settings > Display > Larger Text → every Text scales; Tab/Shift+Tab cycles the full interactive surface. Reference all 5 issue numbers. Do NOT touch `AudioEngine.swift` internals.
- **Estimated effort:** ~5M = ~5 agent-days.

---

## BATCH-23 · i18n — xcstrings + Figtree glyph fallback + Rust error localization

- **Priority:** p0
- **Platform:** macos (i18n)
- **Issues:**
  - #345: Move every user-facing string to `Localizable.xcstrings`
  - #347: Figtree glyph coverage fallback chain
  - #351: Localize error messages (not from Rust core)
- **Files expected to touch:**
  - `macos/Sources/Jellify/Resources/Localizable.xcstrings` (new)
  - Every Swift file with user-facing `Text("...")` / `Button("...")` — broad sweep
  - `macos/Sources/Jellify/Theme/Theme.swift` (font fallback chain)
- **Rationale:** Big sweep — must be one worker to avoid duplicate keys + inconsistent naming. Figtree fallback + error localization naturally sit with the catalog creation.
- **Suggested agent prompt:**
  > Implement #345, #347, #351 together. Create `macos/Sources/Jellify/Resources/Localizable.xcstrings` (String Catalog). Sweep every hardcoded `Text("…")`, `Button("…", …)`, `TextField` prompt, `.accessibilityLabel`, `.accessibilityHint`, alert/confirmation strings. Replace with `LocalizedStringKey`s or explicit `String(localized:)`. Use stable semantic keys (e.g. `player.play`, `error.auth.expired`, `onboarding.welcome.title`). In `Theme/Theme.swift`: build a fallback font chain for Figtree so Cyrillic/Greek/Hebrew/Arabic/Thai/CJK characters render via the system default — use `CTFontCreateWithCharacterSet` or fall through to `Font.system(size:)` when non-Latin chars detected. In the UI layer, build a `JellifyErrorPresenter` that maps every `JellifyError` UniFFI variant to a localized string key (don't pass the Rust `Display` output through). Acceptance: `Localizable.xcstrings` has every user-facing string keyed; switch language in Xcode's preview → labels translate via the catalog (en only seeded; scaffold for other locales); rendering a Russian artist name does not show tofu boxes. Reference all 3 issue numbers. Do NOT add RTL layouts or translations for other locales — that's #346 / #348, p1.
- **Estimated effort:** ~1L + 1M + 1M = ~4 agent-days.

---

## BATCH-24 · Core refactor — typed enums + ItemsQuery builder (FFI-WIDE)

- **Priority:** p1 but **critical dependency** for many batches
- **Platform:** core
- **Issues:**
  - #464: Add typed enums for `ItemKind`, `ImageType`, `ItemSortBy`, `SortOrder`, `ItemField`
  - #465: Introduce `ItemsQuery` builder
  - #462: Refactor `search` to use typed item-kind filter
  - #466: Add `UserItemData` model and propagate into Album/Artist
  - #467: Add structured error mapping for auth vs rate-limit vs not-found
- **Files expected to touch:**
  - `core/src/wire.rs` or `core/src/enums.rs` (new)
  - `core/src/client.rs`
  - `core/src/models.rs`
  - `core/src/lib.rs` (UniFFI)
  - `macos/Sources/JellifyCore/Generated/` (regenerated)
- **Rationale:** **BLOCKS all downstream consumers until landed.** Any macOS batch touching `items_query` / `search` / `UserItemData` has to either wait for this or use stubs. Ship early and coordinate.
- **Suggested agent prompt:**
  > Implement #464, #465, #462, #466, #467 together. Create `core/src/enums.rs`: `ItemKind { Audio, MusicAlbum, MusicArtist, Playlist, Genre, ... }`, `ImageType { Primary, Backdrop, Thumb, Logo, ... }`, `ItemSortBy { Name, DateCreated, DatePlayed, PlayCount, Album, AlbumArtist, ... }`, `SortOrder { Asc, Desc }`, `ItemField { Overview, Genres, ChildCount, People, MediaStreams, ... }`. All `#[serde(rename_all = "PascalCase")]`. Create `core/src/query.rs` with `ItemsQuery` fluent builder (parent_id, user_id?, types: Vec<ItemKind>, sort_by: Vec<ItemSortBy>, sort_order, limit, offset, is_favorite, genre_ids, artist_ids, album_artist_ids, years, search_term, fields, etc.); `ItemsQuery::fetch(client) -> Result<Items<RawItem>>`. Refactor `albums`, `artists`, `album_tracks`, `search` to be thin wrappers on top. Add `UserItemData { is_favorite, played, play_count, playback_position_seconds, last_played_at, likes, rating }`, attach `user_data: Option<UserItemData>` to `Album`, `Artist`, `Track`. Refactor `JellifyError` into structured variants: `Auth`, `RateLimit { retry_after: Option<Duration> }`, `NotFound`, `Network`, `Server { status, body }`. Regenerate UniFFI bindings. **Annotate commit / PR with: "BREAKING: blocks consumers until all dependents migrate. Coordinate with batches BATCH-11, BATCH-13, BATCH-26."** Acceptance: `cargo test` passes; no string literals for `IncludeItemTypes`/`SortBy`/`Fields` remain in `client.rs`; Swift bindings compile. Reference all 5 issue numbers.
- **Estimated effort:** ~4S + 1M = ~3 agent-days.

---

## BATCH-25 · NSVisualEffect + hover/focus polish + window state

- **Priority:** p1
- **Platform:** macos
- **Issues:**
  - #16: Replace bespoke hover/selection colors with macOS-native hover and focus rings where appropriate
  - #17: Wrap `NSVisualEffectView` to provide the translucent sidebar + translucent player-bar materials
  - #27: Plug in `NSApplicationDelegateAdaptor` for dock menu, tab customization, and wake-from-sleep reconnect
  - #28: Per-window Settings via `Settings` scene + focused bindings, with `Cmd+,` standard shortcut
  - #323: Window restoration
  - #9: Plumb `@FocusedValue` / `focusedSceneValue` so menu items drive the focused window's AppModel
  - #10: Restore window size, position, sidebar visibility, inspector visibility, and last-viewed screen across launches
- **Files expected to touch:**
  - `macos/Sources/Jellify/Components/VisualEffectView.swift` (new NSViewRepresentable)
  - `macos/Sources/Jellify/Components/Sidebar.swift` / `PlayerBar.swift`
  - `macos/Sources/Jellify/JellifyApp.swift` (AppDelegate, FocusedValue)
  - `macos/Sources/Jellify/AppDelegate.swift` (new)
- **Rationale:** All polish around the native-macOS feel of the shell. Related — same worker owns `JellifyApp.swift` modifications.
- **Suggested agent prompt:**
  > Implement #9, #10, #16, #17, #27, #28, #323 together. **Depends on BATCH-01 landed.** Create `VisualEffectView.swift` as an `NSViewRepresentable` wrapping `NSVisualEffectView` with configurable material (`.sidebar` / `.hudWindow` / `.contentBackground`) + `blendingMode` + `state`. Use it in `Sidebar.swift` and `PlayerBar.swift` to get real Apple Music-style translucent materials. In `TrackRow.swift` / `AlbumCard.swift`: drop bespoke `@State var isHovering` → `Theme.rowHover` approach where a native focus ring suffices; keep custom hover only where the focus ring doesn't fit. Add `AppDelegate.swift` (`NSApplicationDelegateAdaptor`): implement `applicationDockMenu(_:)`, `NSWindow.allowsAutomaticWindowTabbing = true`, observe `NSWorkspace.willSleepNotification` → pause playback, `didWakeNotification` → reconnect to server. Wire `@FocusedValue`/`focusedSceneValue` (#9): define `FocusedValueKey`s for `AppModel`, expose in each `WindowGroup` scene, consume in every menu action. Add `Settings` scene (#28) for per-window preferences bindings — `Cmd+,` opens preferences. Verify window restoration (#10 + #323) — `WindowGroup` on macOS 14+ restores automatically; just remove `.defaultSize` once state is stored. Acceptance: sidebar feels like Apple Music; File → New Window makes two independent windows; Cmd+, opens Settings; close + relaunch → size/position/sidebar-visibility restored. Reference all 7 issue numbers. Do NOT reintroduce the menu bar — BATCH-02 owns that.
- **Estimated effort:** ~1S + 2S + 2M + 1M + 1S + 1M = ~4.5 agent-days.

---

## BATCH-26 · Core API — instant mix, similar, suggestions, genres, lyrics, artist detail (p1 fills)

- **Priority:** p1
- **Platform:** core
- **Issues:**
  - #144: Add `instant_mix`
  - #145: Add `suggestions`
  - #146: Add `similar_artists` / `similar_albums` / `similar_items`
  - #149: Add `frequently_played_tracks`
  - #151: Add `genres`
  - #152: Add `items_by_genre`
  - #156: Add `artist_detail`
  - #162: Add `lyrics`
- **Files expected to touch:**
  - `core/src/client.rs`
  - `core/src/models.rs`
  - `core/src/lib.rs`
- **Rationale:** Eight simple-effort (S) read-only endpoints on `JellifyClient`. Same file, batch together.
- **Suggested agent prompt:**
  > Implement core #144, #145, #146, #149, #151, #152, #156, #162 together. All are new methods on `JellifyClient` in `core/src/client.rs`. Each follows the established pattern: `pub async fn name(&self, args...) -> Result<ReturnType>` + wire struct + UniFFI export. Coordinate with BATCH-24 — if `ItemsQuery` has landed, use it; otherwise raw query-string with `// TODO(core-#465)`. Add unit tests against recorded Jellyfin responses. Acceptance: `cargo test --workspace` passes; macOS side sees the new methods via regen. Reference all 8 issue numbers.
- **Estimated effort:** ~8S = ~4 agent-days.

---

## BATCH-27 · Linux bootstrap (blocks all Linux work)

- **Priority:** p0 (bootstrap) + blocks everything Linux
- **Platform:** linux
- **Issues:**
  - #390: Bootstrap `linux/` Cargo crate with gtk-rs + libadwaita dependencies
  - #391: Configure `build.rs` + gresource pipeline
  - #392: `adw::Application` main entry + single-instance handling
  - #393: Custom `JellifyWindow` GObject subclass via `glib::subclass`
  - #394: Embed `JellifyCore` as a shared `Rc`-wrapped model on the main loop
  - #395: Wrap core models as `gio::ListModel`-compatible GObjects
- **Files expected to touch:**
  - `linux/Cargo.toml` (new as workspace member)
  - `linux/src/main.rs` (new)
  - `linux/src/window.rs`, `window.ui` (new)
  - `linux/src/model.rs` (new)
  - `linux/resources/resources.gresource.xml` (new)
  - `linux/build.rs` (new)
  - Root `Cargo.toml` (add `linux` to workspace members)
- **Rationale:** **Everything Linux is blocked until this batch lands.** Bootstrap must be one PR so the skeleton is internally consistent.
- **Suggested agent prompt:**
  > Implement Linux bootstrap #390, #391, #392, #393, #394, #395 together. Create `linux/` as a workspace member producing `jellify-desktop` binary. Add dependencies pinned to GNOME-46: `gtk4`, `libadwaita`, `gio`, `glib`, `glib-build-tools` (build-dep), `tokio`, `jellify_core` (workspace). Write `build.rs` to compile `resources.gresource.xml`. `main.rs` boots an `adw::Application` with app-id `org.jellify.Desktop`, `ApplicationFlags::HANDLES_OPEN`, primary-instance registration. Create `window.rs` + `window.ui` (XML composite template) — `JellifyWindow` GObject subclass with `AdwNavigationView` + `AdwHeaderBar` fields. Create `model.rs`: `AppModel` owning `Arc<JellifyCore>` + `gio::ListStore` backings for albums/artists/queue + `glib::Property`-derived Signals. Create wrapper GObjects in `model.rs` for `Album`, `Artist`, `Track` using `glib::Properties` derive so `gtk::GridView`/`ListView` can render them natively. Acceptance: `cd linux && cargo build` produces a runnable (even if mostly-empty) window; primary-instance enforcement works (second `jellify-desktop` invocation raises the first). Reference all 6 issue numbers. **Do not yet implement any screens — that's a follow-up batch.**
- **Estimated effort:** ~2M + 4S = ~4 agent-days. **Upstream:** unblocks all Linux batches.

---

## BATCH-28 · Windows bootstrap (blocks all Windows work)

- **Priority:** p0 (bootstrap) + blocks everything Windows
- **Platform:** windows + core
- **Issues:**
  - #360: Create `windows/` solution skeleton targeting WinAppSDK 1.8
  - #361: Bump core to uniffi-rs 0.29 and lock UniFFI toolchain
  - #362: Build script — produce `jellify_core.dll` for x64 and arm64
  - #363: Generate C# UniFFI bindings and wrap in `Jellify.Core`
  - #364: Dependency injection + app host
  - #365: Navigation frame + shell with NavigationView
- **Files expected to touch:**
  - `windows/` (new directory tree: Jellify.App/, Jellify.Core/, Jellify.sln)
  - `windows/tools/build-core.ps1`, `gen-bindings.ps1` (new)
  - `Cargo.toml` root (bump uniffi 0.28 → 0.29)
  - `core/src/lib.rs` (fix uniffi breaking changes)
- **Rationale:** **Blocks all Windows work.** Must be one PR for internal consistency — bumping uniffi affects macOS bindings too, so coordinate carefully.
- **Suggested agent prompt:**
  > Implement Windows bootstrap #360, #361, #362, #363, #364, #365 together. **Note: #361 (uniffi 0.28 → 0.29) affects macOS bindings too.** First: bump `Cargo.toml` to `uniffi = "0.29"`; fix the breaking changes (mostly function-signature rename, error-type wrapping); regenerate macOS Swift bindings + verify `macos/` still builds. Then: create `windows/` directory tree — `Jellify.sln` + `Jellify.App.csproj` (`net8.0-windows10.0.22621.0`, `<WindowsPackageType>MSIX</WindowsPackageType>`, `<UseWinUI>true</UseWinUI>`, `<EnableMsixTooling>true</EnableMsixTooling>`) + `Jellify.Core.csproj` (wraps UniFFI-generated C# bindings). Write `windows/tools/build-core.ps1` to build `jellify_core.dll` for `x86_64-pc-windows-msvc` + `aarch64-pc-windows-msvc`. Write `windows/tools/gen-bindings.ps1` using `uniffi-bindgen-cs` (binstall). In `Jellify.App/App.xaml.cs`: `HostApplicationBuilder` with DI registrations for `IJellyfinClient`, `IQueueStore`, `IPlaybackStateStore`, view models (`LoginViewModel`, `HomeViewModel`, `LibraryViewModel`). Add `ShellPage.xaml` with a `NavigationView` (left pane) + `Frame` (content); wire `INavigationService.NavigateTo<TViewModel>(object? param = null)`. Acceptance: `windows/build-core.ps1 && windows/gen-bindings.ps1 && dotnet build windows/Jellify.sln` all succeed; `./Jellify.App.exe` launches an empty shell window with a sidebar placeholder. Reference all 6 issue numbers. **Do not yet build the login, player, or any screens — those are follow-up batches.**
- **Estimated effort:** ~2M + 1L + 2M + 1S = ~6 agent-days. **Upstream:** unblocks all Windows batches. Large — consider splitting at the uniffi-bump boundary if agent runs long.

---

## Not yet batched / deferred

- **p2 issues (111 total):** not included. Revisit after these 27 batches land.
- **Issues in flight (11):** #126, #127, #204, #229, #234, #249, #253, #259, #260, #263, #279 — leave to open PRs.
- **Single-issue p0s worth noting:** #11 (multi-window) is pre-requisited by BATCH-25; small on its own but best rolled into BATCH-25's follow-up PR if scope allows.
- **Performance / reliability remainders (p1):** #430, #432, #433, #435, #441, #442, #443, #444, #448 — cluster into a BATCH-29 once the p0s are done.
- **Follow-up Linux batches (post-bootstrap):** screens + GStreamer + MPRIS2 + Flatpak. Gated behind BATCH-27.
- **Follow-up Windows batches (post-bootstrap):** login, player service, SMTC, MSIX, signing, CI. Gated behind BATCH-28.

## Agent-hours rollup

| Batch | Effort (days) |
|---|---:|
| BATCH-01 Shell foundation | 4 |
| BATCH-02 Menu bar + keyboard | 6 |
| BATCH-03 MediaSession | 4.5 |
| BATCH-04 Artist page | 4.5 |
| BATCH-05 Album page polish | 3 |
| BATCH-06 Playlist CRUD | 5 |
| BATCH-07 Queue inspector | 7 |
| BATCH-08 Now Playing + lyrics | 7 |
| BATCH-09 Search | 8 |
| BATCH-10 Context menus | 4 |
| BATCH-11 Core API p0 | 4.5 |
| BATCH-12 Command palette | 5 |
| BATCH-13 Home carousels | 4 |
| BATCH-14 Shuffle/repeat/favorite | 2 |
| BATCH-15 Empty/error/loading | 3 |
| BATCH-16 Onboarding | 4 |
| BATCH-17 Preferences fills | 3 |
| BATCH-18 Dist part 1 | 6.5 |
| BATCH-19 Dist part 2 | 6 |
| BATCH-20 Perf artwork | 2.5 |
| BATCH-21 Reliability | 3 |
| BATCH-22 a11y core | 5 |
| BATCH-23 i18n | 4 |
| BATCH-24 Core enums/ItemsQuery (FFI) | 3 |
| BATCH-25 NSVisualEffect + window state | 4.5 |
| BATCH-26 Core p1 fills | 4 |
| BATCH-27 Linux bootstrap | 4 |
| BATCH-28 Windows bootstrap | 6 |
| **Total** | **~131 agent-days** |

Revised estimate: ~131 agent-days across 27 batches. Running all batches serially by one worker = ~6 calendar months. Running 4 independent workers in parallel (respecting the BATCH-01 / BATCH-02 / BATCH-11 / BATCH-24 / BATCH-27 / BATCH-28 prerequisites) → ~6 calendar weeks of wall-clock for the whole p0 + high-value p1 surface.
