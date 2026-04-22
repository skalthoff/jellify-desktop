# Performance, Reliability, and Observability

Research brief for `jellify-desktop` (Rust core + SwiftUI + AVPlayer macOS shell) covering the work needed to make the app stable, fast, and debuggable at scale. Current state (M2 MVP): plays music; the library call is a single `list_albums(0, 200)`; artwork uses `SwiftUI.AsyncImage` directly; the `AppModel` polls `core.status()` every 0.5s on a `Timer`; `storage.rs` has minimal indices; `error.rs` has a flat set of typed errors with no retry layer and no panic hook.

Real Jellyfin libraries trend towards 50k tracks / 5k albums / 1k artists / 10+ GB of artwork. The goals below target those scales.

---

## Performance

### Issue 1: Replace `AsyncImage` with Nuke for artwork loading
**Labels:** `area:perf`, `kind:feat`, `priority:p0`
**Effort:** M

`SwiftUI.AsyncImage` has known problems for anything beyond a handful of images: no deduplication, no disk cache, re-downloads on re-identity, decodes on the main thread, and no memory-pressure eviction. At 5k album cards this is a GPU+main-thread bottleneck on library open.

Adopt [Nuke](https://github.com/kean/Nuke) (Swift-native, zero-dep, widely used, actively maintained). Nuke gives us `ImagePipeline` with: automatic request coalescing (same URL in-flight once), two-tier cache (`ImageCache` in memory + `DataCache` on disk), off-main decode, Core Animation-safe decompression, progressive JPEG, cancellation when `NukeUI.LazyImage` leaves the viewport, and memory-pressure notifications wired to purge.

Implementation:
- Add `NukeUI` (built-in `LazyImage` + `FetchImage`) via SwiftPM.
- Wrap in `JellifyArtwork(itemID:tag:size:)` that builds the size-hinted URL via `core.image_url(item_id, tag, max_width: 2 * pointSize * screenScale)` — Jellyfin already supports `maxWidth`/`quality`, use it.
- Configure `ImagePipeline.shared` once on launch with `dataCache: DataCache(name: "com.jellify.images", sizeLimit: 500 MB)` and an LRU `ImageCache(costLimit: 100 MB, countLimit: 200)`.
- Set `request.processors = [ImageProcessors.Resize(size: targetPointSize, contentMode: .aspectFill)]` so we never hold full-res bitmaps for a 180-pt cell.
- Add `Jellify` directory to `Library/Caches` for on-device eviction behaviour.

Acceptance: library grid scroll sustains 60 fps (90 fps on ProMotion) at 5k albums; memory delta for artwork cache ≤ 150 MB; a warm library open shows ≥ 80% of visible thumbnails within 200 ms.

### Issue 2: Size-hinted thumbnail URLs + decode downscaling
**Labels:** `area:perf`, `kind:chore`, `priority:p0`
**Effort:** S

Current `Artwork.swift` calls `imageURL(maxWidth: 400)` for a 180-pt grid cell. On a ProMotion 2× display that is fine; on 3× (hypothetical future iPadOS Catalyst target) or small tiles (48-pt list rows) we overpay. Decoding a 400-px JPEG through `AsyncImage` lands a 400×400×4 = 640 KB decoded bitmap in RAM; 5k of those is 3.2 GB.

- Accept a `CGSize` in `Artwork` and compute `pixelWidth = ceil(size.width * NSScreen.main.backingScaleFactor)`. Round up to the nearest Jellyfin-friendly bucket (96, 160, 240, 400, 800, 1600) so the server cache hits on a small set of URLs.
- Always pass Jellyfin `quality=80` for list thumbs, `quality=90` for hero images.
- Use `ImageProcessors.Resize` in Nuke to make the final bitmap exactly `pointSize × 2`.

Acceptance: p50 thumbnail byte size < 15 KB at 160 px; p50 decoded bitmap < 200 KB per image.

### Issue 3: Virtualized library grid with correct recycling
**Labels:** `area:perf`, `kind:feat`, `priority:p0`
**Effort:** M

`LazyVGrid` inside a `ScrollView` is lazy but re-evaluates `body` aggressively and re-creates view trees when `model.albums` is a value-type array that mutates. With 10k items, hover tracking (`isHovering` `@State` on every `AlbumCard`) keeps a live `View` per row, driving quadratic re-layout costs when scrolling fast.

Steps:
- Scope `@State private var isHovering` to only the row currently under the cursor — hoist hover tracking to a single parent `@State var hoveredID: String?`.
- Identify items with stable `Identifiable` IDs (`album.id`, already string-stable) and use `ForEach(albums) { ... }` instead of `\.id`.
- Move the per-card `Button { model.play(album:) }` inner closure out of the main `VStack` — wrap it in `.onTapGesture` with `.modifierKeyAlternate`. `Button` adds AX scope and tracks `isPressed`, both non-zero.
- Consider `List` with `.listStyle(.plain)` for the flat all-albums view — it has better NSTableView-backed recycling on macOS, at the cost of grid layout. Fall back to manual paging via `ScrollView(.vertical) { LazyVStack(pinnedViews: []) { ForEach(chunks) { row in HStack { cells } } } }` to flatten into vertical rows (cheaper than `LazyVGrid` in practice — see [this post](https://fatbobman.com/en/posts/lazyvgrid-performance)).
- Benchmark with `Instruments → SwiftUI` template + Hitches instrument; target ≤ 2 hitches / 10 s scroll on M1 baseline.

Acceptance: at 10k items, sustained scroll at target refresh rate with zero dropped frames past the 500 ms warm-up.

### Issue 4: Library pagination + prefetch
**Labels:** `area:perf`, `kind:feat`, `priority:p0`
**Effort:** M

`AppModel.refreshLibrary` calls `listAlbums(offset: 0, limit: 200)`. Hardcoded. On large libraries we need pagination.

Plan:
- Extend core `albums()` with `total_record_count` — the Jellyfin response already contains `TotalRecordCount`, we drop it today (`#[allow(dead_code)]`). Surface it on a new `PaginatedList<Album>` UniFFI struct.
- Add `AppModel.loadMoreAlbums()` that tracks `loadedCount` and `totalCount`, appends a batch of 100 on scroll-near-end.
- Detect scroll-near-end with `.onAppear { if item == albums.suffix(20).first { await model.loadMoreAlbums() } }` on the grid cell. Avoid `GeometryReader`/contentOffset tricks — they break on `.searchable` insets.
- Debounce duplicate loads while one is in flight (`isLoadingMore` flag).
- For the "ALL ALBUMS" view, prefer `StartIndex` + `Limit` + `SortBy=SortName`; for "Recently Added" use `SortBy=DateCreated,SortOrder=Descending`.

Acceptance: first paint of library in ≤ 400 ms regardless of library size; `cargo test` coverage for paginated fetch.

### Issue 5: SQLite index + pragma audit for large libraries
**Labels:** `area:perf`, `kind:chore`, `priority:p1`
**Effort:** S

`migrations/001_initial.sql` only indices `play_history(track_id)` and `play_history(played_at)`. As `track_cache`, `album_cache`, `artist_cache` grow (and as we add favorites / playlist tables) we need more.

Add (in a new `002_indices.sql` migration):
- `CREATE INDEX idx_play_history_completed ON play_history(completed, played_at DESC);` — for "recently played" filtered to completed listens.
- `CREATE INDEX idx_track_cache_updated ON track_cache(updated_at);` — for stale-revalidation batch selects.
- `CREATE INDEX idx_album_cache_updated ON album_cache(updated_at);`
- When we add favorites/playlists: `idx_favorites_track`, `idx_playlist_items_playlist_pos`.

Verify with `EXPLAIN QUERY PLAN` in a debug harness. Also tune pragmas:
- Already set: `journal_mode=WAL`, `synchronous=NORMAL` (good for our use case — survives crash, not power loss).
- Add: `cache_size = -20000` (~20 MB page cache), `temp_store = MEMORY`, `mmap_size = 268435456` (256 MB; read-only mmap for seq scans).
- Add `PRAGMA optimize;` on app shutdown and once after the first-time full library dump.

Acceptance: `SELECT * FROM album_cache ORDER BY updated_at DESC LIMIT 100` runs in < 5 ms at 10k rows on a cold cache.

### Issue 6: Database-backed library cache with background revalidation
**Labels:** `area:perf`, `kind:feat`, `priority:p0`
**Effort:** L

Today the library is fetched fresh every launch. On a 50k-track server with 1500-ms roundtrips over a wi-fi link the user stares at a spinner. The fix is a cache-first, revalidate-in-background strategy.

Design:
- Persist `albums`, `artists`, `tracks` metadata into `album_cache` / `artist_cache` / `track_cache` as JSON rows (already schema-prepared) the first time we fetch them. Keyed by ID, with `updated_at`.
- On app launch: emit cached rows to the UI immediately (< 50 ms path via `core.list_cached_albums(limit)`), then asynchronously fetch from the server. Diff (by ID + a hash of the `Etag` / `DateLastMediaAdded` / `DateModified` field Jellyfin returns) and push only changed rows through a `core.library_changes` event channel.
- Jellyfin exposes `Users/{userId}/Items?IncludeItemTypes=MusicAlbum&Fields=DateLastMediaAdded&MinDateLastSaved=<iso8601>` — use the `MinDateLastSaved` filter for delta sync. Store the server's `last_successful_sync` timestamp per user in `settings`.
- Add a `JellifyLibrary` service in Rust that wraps `JellyfinClient + Database`. SwiftUI observes via an async stream surfaced over UniFFI (`uniffi::CallbackInterface`).

Acceptance: warm launch shows the library in < 150 ms; background revalidation completes in < 3 s for a 5k-album library; delta sync transfers ≤ 1% of the full payload on a no-op day.

### Issue 7: Cold-start time budget + Instruments tracepoints
**Labels:** `area:perf`, `kind:chore`, `priority:p1`
**Effort:** M

We have no measurement for "launch to playable". Establish the budget and instrument it.

- Add `os_signpost` intervals around: `launch`, `swiftui_first_frame`, `core_init`, `credentials_load`, `library_cache_paint`, `library_server_sync`.
- Add a Rust-side `tracing` span for `JellifyCore::new`, `login`, `listAlbums`; forward to the Swift `Logger` via a subscriber (Issue 25).
- Run under Instruments Time Profiler + Points of Interest. Establish a CI-runnable perf check via `xcrun xctrace record` in a headless harness (no UI) measuring `core_init`.
- Budget: cold launch (unsigned, un-notarized dev build) to first interactive pixel < 800 ms on M1; signed release build < 600 ms. Time to "click play on a cached album" < 1.2 s cold, < 400 ms warm.

Acceptance: budgets documented in `docs/perf-budgets.md`; Instruments template `.tracetemplate` committed; signposts visible in the System Trace instrument.

### Issue 8: Remove synchronous `core.status()` polling, use an event stream
**Labels:** `area:perf`, `kind:feat`, `priority:p1`
**Effort:** M

`AppModel.startPolling` fires a 500-ms `Timer` that calls `core.status()` on the main queue, triggering `@Observable` downstream re-renders twice a second, even while the app is backgrounded, even while idle. The core status only *actually* changes on state transitions (play/pause/track end) plus a position tick from AVPlayer's own `addPeriodicTimeObserver` we already have.

Replace the poll with:
- A `uniffi::CallbackInterface PlayerObserver` the Rust core invokes on state transitions (already mutation points: `mark_state`, `set_current`, `clear`).
- Drop the `Timer` entirely. The position is already observed by AVPlayer's periodic observer; we can update `status.positionSeconds` there and coalesce into a published `@Observable` once per UI frame using `.animation(.linear(duration: 0.5))`.
- While the window is in the background (`NSApp.occlusionState` does not contain `.visible`), stop updating the UI-side `status` entirely.

Acceptance: idle CPU drops to ≤ 0.3% on an M1 in background, ≤ 1% in foreground with no playback. No wakeups from the `Timer`.

### Issue 9: Adopt `URLCache`/Nuke disk cache for Jellyfin JSON responses
**Labels:** `area:perf`, `kind:chore`, `priority:p2`
**Effort:** S

Orthogonal to library cache (Issue 6): make the underlying HTTP layer honor `Cache-Control` / `ETag` from Jellyfin so that re-opening a screen doesn't re-fetch. `reqwest` alone doesn't cache — wrap with `reqwest-middleware` + `http-cache-reqwest` in front of the `Client`.

Constraints: do not cache auth'd streaming URLs; restrict to `GET Users/*/Items`, `Artists/*`, `Items/*/Images/*`.

Acceptance: identical consecutive requests served from local cache with an `age` log header and no network hop (verified with Wireshark or the network debug panel from Issue 23).

### Issue 10: Memory footprint budget + pressure handling
**Labels:** `area:perf`, `kind:chore`, `priority:p1`
**Effort:** M

AVPlayer alone has a baseline of 15–25 MB per active item (sample buffers, decoder state). Our image cache (Issue 1) targets 100 MB in-memory. The Rust core's in-memory library cache + queue is another 20 MB at 50k tracks. We have no strict budget or pressure response.

Plan:
- Register `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])` on the main queue. On `.warning`: drop image cache to 50 MB, drop un-visible album track caches from `AppModel.albumTracks`, flush `track_cache` rows older than 7 days. On `.critical`: additionally evict the full Nuke `ImageCache`, tear down any second AVPlayer prefetched for gapless.
- Add a Rust-side `JellifyCore::trim_memory(level)` entry point that the Swift handler calls to clear in-core caches.
- Ship a debug Heap-allocations Instruments baseline run for a 5k-album library; budget steady-state < 150 MB.

Acceptance: `footprint` column in Xcode debug navigator stays < 150 MB during a 5-minute listen session; pressure callbacks reduce to < 80 MB in < 500 ms.

### Issue 11: Battery / energy profiling
**Labels:** `area:perf`, `kind:chore`, `priority:p2`
**Effort:** S

Profile with Xcode's Energy gauge + Instruments Energy Log on a MacBook battery, one hour of continuous playback, window not frontmost.

Targets (guided by [Apple's energy best practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-OSX/EnergyEfficiencyPlaybackAudioOSX.html)):
- Average energy impact **Low** on the battery usage graph.
- 0 timer wakeups when paused (post-Issue 8).
- No GPU activity when the window is occluded.

Deliverable: a playbook in `docs/energy.md` that says "before a release, run this 1-hour harness, paste the graph."

### Issue 12: First-launch "empty cache" UX
**Labels:** `area:perf`, `kind:feat`, `priority:p2`
**Effort:** S

Before the library cache (Issue 6) has anything, the first launch stares at a spinner for several seconds. Show:
- A skeleton grid of placeholder `Artwork`s using the existing deterministic gradient + album name shimmer.
- A sticky progress bar at the top showing `Loading library (347 / 5000)`.
- Let the user click into **Search** immediately — it doesn't require a full library.

Acceptance: time-to-first-interaction < 200 ms even on a cold cache. No full-screen spinner.

---

## Reliability

### Issue 13: Retry layer with exponential backoff + jitter on `reqwest`
**Labels:** `area:reliability`, `kind:feat`, `priority:p0`
**Effort:** M

Current `client.rs` has zero retries. A transient 502 from Jellyfin or a carrier wi-fi blip on a bus commute tanks the library load.

Classify:
- Retriable: timeouts, 5xx (except 501), 429 (honour `Retry-After`), `connection reset`, `connection refused`, DNS `temporary failure`.
- Non-retriable: 400/401/403/404/422, TLS handshake failure (likely config), `invalid url`.

Implement with `reqwest-middleware` + `reqwest-retry` + `http-cache-reqwest` (one stack). Policy: `ExponentialBackoff { retries: 3, min_delay: 200ms, max_delay: 3s, jitter: full }`. Wrap the shared `Client` once in `JellyfinClient::new`.

Different endpoints get different policies:
- Auth endpoints: no retry on 401; we want the user to see the bad password once.
- `Items` listings: retry 3 times.
- `Audio/.../universal` (stream URL): URL is generated, never fetched server-side by us; no retry needed.
- `POST PlayingItems/Progress`: retry but dedupe via a local `(track_id, progress_ticks)` idempotency cache — we don't want 5 progress rows.

Acceptance: chaos test with wiremock returning 502 on 30% of requests — library load still succeeds in < 5 s. Unit tests for each error category in `tests.rs`.

### Issue 14: AVPlayer stall recovery + user-visible retry
**Labels:** `area:reliability`, `kind:feat`, `priority:p0`
**Effort:** M

`automaticallyWaitsToMinimizeStalling = true` is set, which helps, but we never handle the `AVPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate` transition ourselves. After a long stall the player just hangs silently.

Plan:
- Observe `player.timeControlStatus` and `player.reasonForWaitingToPlay`. If waiting for > 5 s: trigger a retry (preserve current position, rebuild `AVPlayerItem` with the same URL + auth header, `seek(to: savedTime)`, `play()`).
- Observe `AVPlayerItem.status` — on `.failed`, inspect `error` and show a user-facing toast: "Couldn't play track — tap to retry". Keep the queue intact; don't auto-skip on failure (that's worse than stopping).
- Observe `AVPlayerItem.isPlaybackLikelyToKeepUp`. When it flips `false`, log a `Logger` event with the current bitrate + position + server round-trip time so we can diagnose from user logs.
- On total giveup (3 failed retries), advance to next track and surface a persistent error banner.

Acceptance: pulling the ethernet cable mid-track results in "Reconnecting..." state within 3 s and successful resume when the cable is plugged back in. Breaking the stream URL (simulated 401) shows a retry button and does not spin forever.

### Issue 15: Detect 401 and silently re-auth with keyring credentials
**Labels:** `area:reliability`, `kind:feat`, `priority:p0`
**Effort:** M

Jellyfin access tokens can be invalidated server-side (admin reset, token rotation, user re-auth from another device). Today a 401 surfaces as `JellifyError::Server { status: 401, ... }` and we just show the message.

- Intercept 401 in the reqwest middleware chain (Issue 13). If the response came from a session-bearing endpoint, clear `self.token` and invoke `refresh_session()`.
- `refresh_session()` reads `server_url`, `username` from `settings`, pulls the password from `keyring`, calls `authenticate_by_name` again, stores the new token in the keyring.
- If keyring-stored creds are missing, surface a `JellifyError::ReauthRequired` variant and the Swift side routes back to `LoginView` with the server URL pre-filled.
- Add a simple race guard: a `Mutex<Option<JoinHandle>>` for the in-flight refresh; concurrent callers await the same handle.

Acceptance: invalidating a token on the server and then clicking "Play" results in a silent re-auth and successful playback, with no visible state change beyond a 500-ms blip.

### Issue 16: Offline graceful degradation
**Labels:** `area:reliability`, `kind:feat`, `priority:p1`
**Effort:** M

When the Jellyfin server is unreachable on launch (VPN off, server down, captive portal), today we get a big error modal.

- If `public_info` fails on startup but we have a cached library (Issue 6), enter **offline mode**: show cached library, disable "play" on non-offline tracks with a muted look + tooltip "Server unreachable", keep Settings, Search (over local cache), Queue operable.
- Add a top-bar banner "Offline — [Reconnect]". Reconnect triggers a `public_info` probe; on success, dismiss and re-enable.
- Poll reachability at a slow cadence (15 s, with exponential backoff up to 2 min) using `SCNetworkReachability` / `NWPathMonitor` rather than hammering the server.

Acceptance: airplane-mode launch opens into a usable read-only library in < 500 ms. Re-enabling Wi-Fi restores normal operation within 30 s with no user action.

### Issue 17: Sentry crash reporting (opt-in)
**Labels:** `area:reliability`, `area:observability`, `kind:feat`, `priority:p1`
**Effort:** M

Rust panics across UniFFI **unwind** by default with `panic = "unwind"`, but the panic becomes a `uniffi::UnexpectedUniFFICallbackError` on the Swift side — we lose the backtrace. And we have no crash reporter at all.

Plan:
- Add `sentry-cocoa` SDK to Swift. Gate `SentrySDK.start` behind a user-visible "Send crash reports" toggle in Settings (off by default; opt-in). Strip PII aggressively: no IP (`options.sendDefaultPii = false`), no server URL in `dsn` extras, scrub `request.url` of query strings, scrub breadcrumbs that carry track/album/artist names.
- Rust side: `std::panic::set_hook` that serializes `PanicInfo { message, location, backtrace }` and forwards to Swift via a `uniffi::CallbackInterface CrashReporter`. Swift captures to Sentry as a synthetic `NSError` with the Rust backtrace as a breadcrumb.
- Optionally swap to `panic = "abort"` in release for determinism and use a `sentry-rust` integration that writes a native minidump — but this is complicated in a UniFFI static lib; **not recommended** for v1.
- Sample rate: `options.tracesSampleRate = 0.0` (no perf traces yet); `options.sampleRate = 1.0` for errors (they're rare).

Acceptance: panicking a `debug_assert!` in a dev build fires a Sentry event containing the Rust file + line + message. Setting toggle off prevents any network traffic to Sentry.

### Issue 18: Structured logging with `tracing` + `os_log` bridge
**Labels:** `area:reliability`, `area:observability`, `kind:feat`, `priority:p1`
**Effort:** M

`tracing` is already a workspace dep. It's used nowhere. `os_log` / Swift `Logger` is also unused. Both should be the standard.

Plan:
- In `core/`, add a `tracing_subscriber::Registry` with an `EnvFilter` and a custom `tracing_subscriber::Layer` that maps `tracing::Event` → Swift `Logger.log(level:message:)` via a UniFFI callback. One subsystem `com.jellify.core`; categories per module: `client`, `storage`, `player`, `auth`.
- Instrument: every public `JellyfinClient` fn with `#[tracing::instrument(skip(self, password))]`, every DB migration, every retry.
- Swift side: category loggers: `Logger(subsystem: "com.jellify.macos", category: "app" / "audio" / "ui")`.
- Respect `JELLIFY_LOG=debug,jellify_core::client=trace` on launch. In release builds, default to `warn`.
- Add a "Show Logs" menu item (Help → Show Logs) that opens Console.app filtered to our subsystems, or exports a bundle of the last 500 lines.

Acceptance: logs are queryable via `log stream --subsystem com.jellify.core` and contain span timings. A 1-hour session produces < 2 MB of on-disk log data.

### Issue 19: Human-readable error surface across the FFI
**Labels:** `area:reliability`, `kind:chore`, `priority:p1`
**Effort:** S

`JellifyError` already uses `#[uniffi(flat_error)]` which gives us `error.localizedDescription` with the `Display` output. But messages like `"network error: operation timed out"` are not user-friendly, and `"server returned an error: 401 "` leaks status codes into the UI.

- Add a `user_message()` method on `JellifyError` that returns a localized, action-oriented string:
  - `Network(_)` → `"We can't reach your server. Check your internet connection and try again."`
  - `Server { status: 401, .. }` → `"Your session expired. Please sign in again."`
  - `Server { status: 5xx, .. }` → `"Your Jellyfin server is having trouble. Try again in a moment."`
  - `Credentials(_)` → `"We couldn't save your credentials to the Keychain."`
  - `Audio(_)` → `"Playback failed. The track may be in an unsupported format."`
- Translation via a `Localizable.strings` on the Swift side; Rust returns a stable key + optional context.
- Keep the verbose `Display` for logs.

Acceptance: no surfaced error message contains the substring "error", an HTTP status code, or a stack trace.

### Issue 20: UniFFI panic hook vs abort — document + test
**Labels:** `area:reliability`, `kind:chore`, `priority:p2`
**Effort:** S

Rust panics across FFI: UniFFI's generated Swift bindings wrap every call in a `rust_call` that catches unwinds and surfaces them as a thrown `UniFFI.InternalError`. But if we land on `panic = "abort"` accidentally (e.g., via a workspace override) the whole app goes down.

- Confirm `Cargo.toml` `[profile.release] panic = "unwind"` (unset → default unwind).
- Add a `#[test] fn panics_surface_as_errors` that calls `uniffi::deps::static_assertions::assert_eq!` against a panicking callback and asserts the Swift-layer test catches it as a thrown error.
- Document in `CONTRIBUTING.md`: no `.unwrap()` in library paths; use `expect("context")` only when invariant is guaranteed by construction; use `?` elsewhere.

Acceptance: triggering a panic in a non-critical path surfaces as an error banner, not a crash. CI enforces `#![deny(clippy::unwrap_used)]` in `core/src/lib.rs`.

### Issue 21: Graceful shutdown — flush DB, stop AVPlayer, persist queue
**Labels:** `area:reliability`, `kind:feat`, `priority:p2`
**Effort:** S

On `applicationShouldTerminate` / `NSApp.terminate`, we currently yank AVPlayer out from under its observer, leak the keyring connection, and don't persist the user's queue.

- Register `NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification)` that: calls `audio.stop()`, calls `core.persist_queue()` (new Rust entry point — writes the current queue snapshot to `settings` as JSON), `PRAGMA optimize` + `wal_checkpoint(TRUNCATE)` on the SQLite connection.
- On next launch, if a persisted queue exists: restore silently but do NOT auto-play. Show a toast "Resume where you left off?" with a play button.
- Handle force-quit-while-downloading (when we add downloads): the download worker writes to a `.part` file + `download_state` table row; on restart, any row with `state IN ('downloading', 'pending')` resumes via HTTP `Range`.

Acceptance: `kill -9` mid-playback followed by a fresh launch does not corrupt the DB (WAL recovery is transparent), restores queue state, and allows one-click resume.

### Issue 22: Network reachability + adaptive bitrate hint
**Labels:** `area:reliability`, `kind:feat`, `priority:p2`
**Effort:** S

Today `stream_url` always asks for 320 kbps. Over a tethered cellular connection, the first 8 seconds of every track is a blank stare.

- Use `NWPathMonitor.currentPath.isExpensive` and `.usesInterfaceType(.cellular)`/`(.wiredEthernet)` to pick a bitrate class on each `play(track:)`:
  - Ethernet / Wi-Fi (unmetered): 320 kbps, direct container list.
  - Wi-Fi metered / cellular: 192 kbps, force `TranscodingContainer=mp3` to minimize variance.
  - Offline-cached: local file URL.
- Expose `core.stream_url_with_quality(track_id, QualityHint)` and call from `AudioEngine.play`.

Acceptance: a bandwidth-limited test (using `nettop` or a packet filter) starts playback in < 2 s on a 2 Mbps link.

---

## Observability

### Issue 23: In-app debug panel (⌘⇧D)
**Labels:** `area:observability`, `kind:feat`, `priority:p1`
**Effort:** M

A hidden, always-available panel — opened via the menu bar or ⌘⇧D — that shows live state for bug reports.

Sections:
- **Session**: server URL, user ID (hashed), token expiry if any.
- **Player**: current track, AVPlayer state, `reasonForWaitingToPlay`, `accessLog.events` count, buffered ranges.
- **Queue**: full queue with indices, current index highlighted.
- **Cache**: Nuke memory cache size, disk cache size + file count, SQLite DB size.
- **Network**: last 20 API calls with URL (query stripped if sensitive), status, duration, retry count.
- **Logs**: tail of the last 100 `tracing` events.
- **Actions**: "Copy diagnostic bundle" (JSON) to clipboard, "Clear image cache", "Clear DB cache", "Force library resync", "Dump goroutines" (Rust task list via `tokio_console` integration optional).

Do NOT surface raw passwords, tokens, or content metadata (track names/artist) outside the "Session" tab unless the user pastes the diagnostic bundle.

Acceptance: the first message in bug reports becomes "Please paste your ⌘⇧D bundle"; users can produce it in one step.

### Issue 24: Telemetry (opt-in, content-free)
**Labels:** `area:observability`, `kind:feat`, `priority:p2`
**Effort:** M

We need anonymized crash-rate / retention / performance data to prioritize work. Privacy must come first.

- Ship [TelemetryDeck](https://telemetrydeck.com) (Swift SDK, EU-hosted, SHA-256 user ID, aggregated). Free tier suits an early-stage OSS project. Alternative: self-hosted PostHog.
- Opt-in on first launch (not opt-out). Off by default. Clear toggle in Settings → Privacy with a one-paragraph explainer listing exactly what we send.
- **Allowed metrics**: app version, OS version, launch count, session duration, track-play-count (no IDs), library-size bucket (e.g. `<1k`, `1k-5k`, `5k-20k`, `20k+`), cold-start duration, library-load duration, error counts by category.
- **Forbidden**: track names, album names, artist names, genres, server URL, IP, user name, lyrics, any free-text the user typed.
- Derive the anonymous user ID from `hash(hardwareUUID + salt)` where `salt` is a per-install random stored in UserDefaults — so reinstalls are treated as new users, and it's impossible to correlate with Jellyfin identities.

Acceptance: privacy audit checklist committed. Running the app offline with telemetry enabled does not queue any events (no fallback IPC or file write).

### Issue 25: Performance metrics (cold-start, first-frame) + opt-in upload
**Labels:** `area:observability`, `kind:chore`, `priority:p2`
**Effort:** S

Building on Issue 24's transport, emit:
- `launch.cold_duration_ms` (from process start to first frame — via `ProcessInfo.systemUptime` or `QuartzCore.CACurrentMediaTime`).
- `library.first_paint_duration_ms`.
- `library.sync_duration_ms`, bucketed by library size.
- `player.time_to_first_byte_ms`, `player.time_to_first_audio_ms` (from `AVPlayerItem.accessLog`).
- `player.stall_count_per_session`.
- `api.p50_latency_ms`, `api.error_rate`.

Locally: always log to `os_log`. Upload: only if Issue 24's telemetry toggle is on.

Acceptance: dashboard in TelemetryDeck with p50/p90 cold-start time. We can detect regressions in a release.

### Issue 26: Feature flags (static file + in-app toggles)
**Labels:** `area:observability`, `kind:feat`, `priority:p2`
**Effort:** S

Runtime toggles for experimental work without shipping a new binary.

Simplest workable design:
- A `~/Library/Application Support/Jellify/flags.json` that `JellifyCore` reads on startup + on SIGUSR1 (so a power user can edit it live).
- Schema: `{ "crossfade_ms": 0, "gapless_playback": false, "debug_panel_enabled": true, "library_delta_sync": true, ... }`.
- Expose via Settings → Experiments → (hidden unless `debug_panel_enabled`) with toggles for each.
- No remote config / no server roundtrip. Keeping it local avoids a privacy vector and a failure mode.

When we need remote: layer a `flags_remote.json` fetched over HTTPS from a CDN-backed GitHub-hosted file with the same schema; local flags always win.

Acceptance: enabling `gapless_playback` via the config file takes effect on next launch with no code change. Flags that reference unknown keys are ignored (no crashes).

### Issue 27: `AVPlayerItem.accessLog` → tracing span
**Labels:** `area:observability`, `kind:chore`, `priority:p2`
**Effort:** S

`AVPlayerItem.accessLog()` is a goldmine: `numberOfStalls`, `indicatedBitrate`, `observedBitrate`, `downloadOverdue`, server address. We ignore it.

On `AVPlayerItemNewAccessLogEntryNotification`, extract the latest `AVPlayerItemAccessLogEvent` and emit a structured `tracing` event with those fields. This surfaces straight into the debug panel (Issue 23) and, if opted in, metrics upload (Issue 25).

Acceptance: the debug panel "Player" section shows live bitrate and stall count.

### Issue 28: Privacy-safe breadcrumb pipeline
**Labels:** `area:observability`, `kind:chore`, `priority:p2`
**Effort:** S

Both Sentry (Issue 17) and telemetry (Issue 24) have breadcrumb systems. If they ever accidentally capture `Track.name` we have a privacy incident.

- Add a `PrivacyScrub` helper that runs over any breadcrumb dictionary before it goes to either transport. It whitelists keys (`action`, `screen`, `duration_ms`, `error_category`) and drops everything else.
- Never log `Track`, `Album`, `Artist`, or `User` structs directly via `Debug`; they should have `#[derive(Debug)]` stripped or a redacted `Display` impl for logs.
- Unit test: feed a populated breadcrumb through the scrub, assert the output contains only whitelisted keys.

Acceptance: CI check greps the codebase for `track.name`, `album.name`, `artist.name`, `user.name` inside any `tracing::info!` / `breadcrumb` call and fails if found.

### Issue 29: CI perf regression gate
**Labels:** `area:perf`, `area:observability`, `kind:chore`, `priority:p2`
**Effort:** M

Once we have budgets (Issue 7) and metrics (Issue 25), prevent regressions.

- `bun test`-style `cargo bench` suite for the Rust core: measure `list_albums` decode, `Database::open`, query p99.
- macOS CI job that runs the `SmokeTest` binary against a `wiremock` fixture of a 5k-album Jellyfin, asserts `library.sync_duration_ms < 3000` and `core_init_ms < 100`.
- Results archived per-commit in `gh-pages` as simple JSON; a small script compares PR vs `main` and comments if any metric regressed > 10%.

Acceptance: PR flow blocks regressions automatically; humans are not the perf watchdog.

### Issue 30: Help → Diagnostic bundle export
**Labels:** `area:observability`, `kind:feat`, `priority:p2`
**Effort:** S

One-click "Export diagnostics" in Help menu produces a `jellify-diagnostics-<date>.zip` containing:
- Redacted app logs (last 24 h).
- DB schema + row counts (no row content).
- Debug panel snapshot.
- `system_profiler SPSoftwareDataType`, `SPHardwareDataType`.
- Current flags.json (sensitive fields redacted).

Users can attach this to a GitHub issue without manually fishing through `~/Library/Logs`.

Acceptance: the zip is < 1 MB, contains no passwords/tokens/content names, and opens in a standard archive viewer.

---

## Summary of priorities

- **P0 (M3 blockers for realistic libraries)**: #1 Nuke images, #3 virtualized grid, #4 pagination, #6 library cache + revalidation, #13 retry layer, #14 stall recovery, #15 silent reauth.
- **P1 (pre-v1 quality bar)**: #5 DB indices, #7 cold-start instrumentation, #8 drop polling, #10 memory pressure, #16 offline mode, #17 Sentry, #18 structured logs, #19 user-readable errors, #23 debug panel.
- **P2 (polish / nice to have)**: #2 size-hinted thumbs (low effort, bump to P1 if we keep AsyncImage temporarily), #9 HTTP cache, #11 energy, #12 cold-cache UX, #20 panic hygiene, #21 shutdown, #22 adaptive bitrate, #24 telemetry, #25 perf upload, #26 feature flags, #27 access log, #28 privacy scrub, #29 perf CI, #30 diagnostic bundle.

Total: 30 issues.
