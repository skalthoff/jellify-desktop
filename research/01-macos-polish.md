# Jellify macOS — SwiftUI + AppKit Polish Plan

Research target: take the M2 MVP (custom three-pane shell, no menu bar, no toolbar,
no shortcuts, no restoration) to Apple Music / Doppler / Marvis-Pro-level chrome
and interaction quality. Scope is **macOS shell / chrome / interaction layer only** —
not MediaPlayer/MPRemoteCommandCenter (separate agent), not distribution, not the
visual polish of individual screens beyond what the chrome dictates.

Current app entry (`macos/Sources/Jellify/JellifyApp.swift`) is a single
`WindowGroup` with `.windowToolbarStyle(.unifiedCompact)` but **no** `.commands {}`
block, no toolbar content, no scene storage, no NavigationStack, no focus values,
no `NSApplicationDelegateAdaptor`. The `AppModel` is `@MainActor @Observable` and
imports `JellifyCore` with `@preconcurrency`, which is the seam we have to keep
an eye on for Swift 6.

Issues below assume SwiftUI on macOS 14+ as the minimum deployment target
(NavigationSplitView, NavigationStack, `.searchable`, Transferable, restoration,
most of the focus-value API). Where an API needs 15+ we call it out.

---

### Issue 1: Adopt `NavigationSplitView` as the shell replacement for the custom HStack
**Labels:** `area:macos`, `kind:feat`, `priority:p0`
**Effort:** L
**Depends on:** -

- Current `MainShell` renders a raw `HStack { Sidebar; Divider; content }`. This means we get none of the free macOS behavior: toolbar unification over the sidebar, system sidebar toggle, proportional resize, full-height sidebar with transparent titlebar, automatic accent-tinted selection.
- Replace with a two- or three-column `NavigationSplitView` (sidebar / content / optional right panel for Up Next + Details inspector). Sidebar visibility state bound to a `@State var sidebar: NavigationSplitViewVisibility = .automatic` so it can be toggled from menu + Cmd+Ctrl+S.
- Use `.navigationSplitViewStyle(.balanced)` to give proportional resize (Apple's default for three-column layouts). Use `.navigationSplitViewColumnWidth(min: 200, ideal: 252, max: 320)` to keep the custom-branded sidebar at its design width while still allowing drag-resize — the system can choose to ignore but honoring is the norm on macOS 14+.
- Keep the brand header + server-footer from the current `Sidebar` as leading/footer `Section`s inside a `List` selection-bound to the screen enum.
- `List(selection: $model.screen)` gives us system row hover, focus ring, type-ahead — all free. Wire purple brand colors via `.tint(Theme.accent)`.
- Acceptance: sidebar toggles via system chevron, via Cmd+Ctrl+S, and via menu item. Dragging the splitter resizes proportionally. Right column (Up Next/details) uses `.inspector` on macOS 14+ and hides cleanly.

### Issue 2: Adopt `.hiddenTitleBar` window style with `fullSizeContentView` so the sidebar runs edge-to-edge under the traffic lights
**Labels:** `area:macos`, `kind:polish`, `priority:p0`
**Effort:** M
**Depends on:** 1

- Design (see `design/project/Jellify Desktop.html`) has the sidebar going all the way to the top of the window with the traffic lights floating over it — the same look as Apple Music, Music for Classical, Reeder, Spark. Today we use `.windowToolbarStyle(.unifiedCompact)` but no `windowStyle`, so we get the default titled bar carving out a strip above the sidebar.
- Add `.windowStyle(.hiddenTitleBar)` to the `WindowGroup` in `JellifyApp.swift`. This sets `titlebarAppearsTransparent = true` and inserts `.fullSizeContentView` into the `styleMask` automatically, letting our content flow under the traffic lights.
- Keep `.windowToolbarStyle(.unifiedCompact)` so `.toolbar {}` content (Issue 6) still lands in the correct unified strip.
- Content behind traffic lights is our sidebar, which is always dark, so contrast is not a problem, but we still need to reserve ~74px of leading space at the top of the sidebar for the lights. Do this with a `.safeAreaPadding(.top, 28)` on the sidebar's brand header when on macOS only.
- References: [NSWindow.titlebarAppearsTransparent](https://developer.apple.com/documentation/appkit/nswindow/titlebarappearstransparent), Luka Kerr's NSWindowStyles showcase.

### Issue 3: Add a proper `.toolbar {}` with forward/back, sidebar toggle, and global search field
**Labels:** `area:macos`, `kind:feat`, `priority:p0`
**Effort:** M
**Depends on:** 1, 4

- With `NavigationSplitView` + `NavigationStack` in the detail column (Issue 4), expose a real unified toolbar:
  - `ToolbarItem(placement: .navigation)`: back `chevron.left` and forward `chevron.right` buttons driven by the detail-column `NavigationPath`. Disabled when stack is empty / at end.
  - `ToolbarItem(placement: .navigation)`: `Button("Toggle Sidebar")` bound to the split-view visibility so users who hide the sidebar have a reliable way back.
  - `ToolbarItem(placement: .principal)` *or* `.automatic`: the current context title ("Library", album name when drilled in, etc.) — read from focused-scene value so it stays accurate across drill-down.
  - `ToolbarItem(placement: .primaryAction)`: inline search `TextField` using `.searchable(text:, placement: .toolbar, prompt: "Artists, albums, tracks…")`. Honor Cmd+F to focus (Issue 7).
- Style the toolbar's `TextField` with Figtree via `Theme.font(13, weight: .medium)` and our purple border; macOS 14's `.searchable` accepts custom prompt views. Do **not** custom-draw the whole toolbar — we lose customization, drag, and unification.
- Acceptance: toolbar is draggable (window moves when dragged by empty toolbar space), items customize via right-click "Customize Toolbar…", unified strip's translucency matches Apple Music when sidebar is visible.

### Issue 4: Convert per-screen routing into a detail-column `NavigationStack` with typed `NavigationPath`
**Labels:** `area:macos`, `kind:feat`, `priority:p0`
**Effort:** M
**Depends on:** 1

- `AppModel.screen` is a single enum today. Once we have sidebar selection driving the top-level choice, the **detail** column needs a drill-down stack so Album → Artist → Track-info → Back works naturally and the toolbar's forward/back reflects real history.
- Introduce `@State private var detailPath = NavigationPath()` in `MainShell` (or store it on `AppModel` if we need cross-scene access for menu commands). Hold one path per top-level nav (Home, Library, Search) to match Apple Music's "each tab has its own history".
- Use `.navigationDestination(for: Album.self) { AlbumDetailView(…) }` / `for: Artist.self` / `for: Track.self` instead of switching on `AppModel.Screen`.
- Pipe through focused-scene values so menu commands like "Go Back" (Cmd+[), "Go Forward" (Cmd+]), "Show in Library" (Cmd+L) can call `.path.removeLast()` / append.
- Reference WWDC22 "The SwiftUI cookbook for navigation" for the canonical stack+path pattern.

### Issue 5: Ship the full macOS menu bar via `Commands` + `CommandGroup` + custom `CommandMenu`s
**Labels:** `area:macos`, `kind:feat`, `priority:p0`
**Effort:** L
**Depends on:** 4, 7, 11

- Currently `JellifyApp` has no `.commands {}` block — we get only the default Apple-supplied menus, no Playback menu, no Jellify-specific items. This is the biggest gap vs. Apple Music.
- Add a dedicated `JellifyCommands: Commands` struct that composes:
  - **Jellify menu** (app name): `CommandGroup(replacing: .appInfo) { Button("About Jellify") { openWindow(id: "about") } }`, then the default Services/Hide/Quit.
  - **File menu** — `CommandGroup(replacing: .newItem) { Button("New Window") { openWindow(id: "main") }.keyboardShortcut("n") }`, `Button("New Mini Player")` (Issue 12, Cmd+Shift+M), `Divider()`, `Button("Sign Out…") { model.logout() }`, `Button("Switch Server…")`, `Divider()`, `Button("Close Window").keyboardShortcut("w")` (default handles this).
  - **Edit menu** — keep default pasteboard/undo, append `CommandGroup(after: .pasteboard) { Button("Find") { /* focus toolbar search */ }.keyboardShortcut("f") }`.
  - **View menu** — `CommandGroup(before: .toolbar) { Toggle("Show Sidebar", isOn: sidebarBinding).keyboardShortcut("s", modifiers: [.command, .control]); Toggle("Show Up Next", isOn: inspectorBinding).keyboardShortcut("u", modifiers: [.command, .option]); Button("Full Player").keyboardShortcut("f", modifiers: [.command, .shift]); Button("Tweaks…") }`.
  - **CommandMenu("Playback")** — see Issue 6 for the full list.
  - **CommandMenu("Controls")** — Shuffle toggle, Repeat mode cycle, Favorite (love) current track.
  - **CommandMenu("Go")** — Back (Cmd+[), Forward (Cmd+]), Home (Cmd+1), Library (Cmd+2), Search (Cmd+3), Now Playing (Cmd+L).
  - **Window menu** — `CommandGroup(after: .windowArrangement) { Button("Minimize").keyboardShortcut("m"); Button("Zoom"); Button("Mini Player").keyboardShortcut("m", modifiers: [.command, .option]) }`.
  - **Help menu** — `CommandGroup(replacing: .help) { Button("Jellify Help") { openURL(docsURL) }; Button("Keyboard Shortcuts").keyboardShortcut("?", modifiers: [.command]); Button("Report Issue…") }`.
- Pipe all actions through `@FocusedValue(\.appModel)` so per-window state is respected. Fallback to `NSApp.keyWindow` model when no scene is focused.
- References: [CommandGroup](https://developer.apple.com/documentation/swiftui/commandgroup), [Customizing the macOS menu bar in SwiftUI — danielsaidi.com](https://danielsaidi.com/blog/2023/11/22/customizing-the-macos-menu-bar-in-swiftui).

### Issue 6: Build the `Playback` CommandMenu with transport, seek, volume, and jump shortcuts matching Apple Music
**Labels:** `area:macos`, `kind:feat`, `priority:p0`
**Effort:** M
**Depends on:** 5

- Model the `Playback` menu and shortcuts to match Apple Music's published shortcut set exactly, so users with muscle memory feel at home:
  - Play/Pause — Space (no modifier). SwiftUI: `.keyboardShortcut(.space, modifiers: [])`. Action calls `model.togglePlayPause()`.
  - Stop — Cmd+Period. `.keyboardShortcut(".", modifiers: .command)`.
  - Next Track — Right Arrow when a row is focused; also Cmd+→ (Apple Music uses plain →, but we need to not steal focus nav in lists; use Cmd+→ for the global menu and allow plain → inside track lists via `onKeyPress`).
  - Previous Track — Cmd+←.
  - Next Album — Cmd+Opt+→ (Apple Music: Option-Cmd-Right).
  - Previous Album — Cmd+Opt+←.
  - Seek Forward 10s — Cmd+Shift+→.
  - Seek Backward 10s — Cmd+Shift+←.
  - Volume Up / Down — Cmd+↑ / Cmd+↓.
  - Mute — Cmd+Opt+↓ (ours; Music uses no shortcut).
  - Increase/Decrease Rating — Cmd+0 through Cmd+5 (future, once we ship favorites/ratings).
  - Shuffle — Cmd+Shift+S.
  - Repeat cycle — Cmd+Shift+R.
  - Show Queue — Cmd+Opt+U (matches Music's "Show Queue").
  - Love Current Track — Cmd+L (conflicts with "Show in Library" which is also Cmd+L in Music; pick one — recommend Cmd+Shift+L for Love to free Cmd+L for "Show in Library").
- All items `.disabled(model.status.currentTrack == nil)` where appropriate.
- References: [Keyboard shortcuts in Music on Mac — support.apple.com](https://support.apple.com/guide/music/keyboard-shortcuts-mus1019/mac), WWDC20 "Commands in SwiftUI".

### Issue 7: Wire Cmd+F, Cmd+L, Cmd+1..3, and tab-switch shortcuts through to AppModel + focus state
**Labels:** `area:macos`, `kind:feat`, `priority:p0`
**Effort:** M
**Depends on:** 3, 5

- Cmd+F: focus the toolbar search field. Use `@FocusState private var searchFocused: Bool` on the search field and flip it from a menu action.
- Cmd+L: "Show the currently playing song in the list" — mirrors Apple Music. Switch the sidebar to Library, push AlbumDetail for the current track's album onto the nav path, scroll to and select the current track's row. Expose a `func revealCurrentTrack()` on `AppModel`.
- Cmd+1 / Cmd+2 / Cmd+3: switch top-level sidebar selection to Home / Library / Search. Store the map `[Character: AppModel.Screen]` once.
- Cmd+[ / Cmd+]: go back / forward in the detail `NavigationPath`. Bind via focused value (Issue 10).
- Cmd+T: new tab within the current window. `NSWindow.tabbingMode = .preferred` via the `NSApplicationDelegateAdaptor` + a menu item calling `NSApp.keyWindow?.addTabbedWindow(newWindow, ordered: .above)`. This gives users the standard Safari-style window-tab group for free.
- Default focus: when the app launches, focus should land on the sidebar list so type-ahead works. Use `.focusedSceneValue(\.appModel, model)` on the root view plus `.focusable()` on the sidebar list.

### Issue 8: Handle media keys (F7/F8/F9 and Bluetooth/headset transport) via the system remote command center
**Labels:** `area:macos`, `kind:feat`, `priority:p0`
**Effort:** M
**Depends on:** -

- Apple Music claims the system media-key handler by default. Any serious Mac music app must register with `MPRemoteCommandCenter` so F7/F8/F9, AirPods double-tap, and Bluetooth headset controls land in our app when we're the "focused now-playing app". This is technically MediaPlayer framework territory (owned by the other agent) but the SwiftUI-side glue lives here: we need to make sure `AppModel.togglePlayPause`, `skipNext`, `skipPrevious`, seek handlers are exposed as `@MainActor` functions the MediaPlayer agent can call, and that on login success we poke the agent to install remote handlers.
- Provide a thin internal `PlaybackRemote` protocol in `JellifyAudio` the MediaPlayer integration can conform to, keeping this module decoupled. Issue exists primarily to flag the contract and make sure it's not dropped; the MediaPlayer agent will own the actual `MPRemoteCommandCenter.shared()` wiring.
- Reference: [MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter).

### Issue 9: Plumb `@FocusedValue` / `focusedSceneValue` so menu items drive the focused window's AppModel
**Labels:** `area:macos`, `kind:feat`, `priority:p1`
**Effort:** M
**Depends on:** 5

- Menus live on the app; state lives in each window. Without focused values, a menu click (Play, Shuffle, Go Back) goes to... nothing. The canonical pattern:
  ```swift
  struct AppModelKey: FocusedValueKey { typealias Value = AppModel }
  extension FocusedValues { var appModel: AppModel? {
      get { self[AppModelKey.self] }; set { self[AppModelKey.self] = newValue }
  } }
  ```
  Then on `RootView`: `.focusedSceneValue(\.appModel, model)`. In `JellifyCommands`: `@FocusedValue(\.appModel) var appModel`. Every button in the menu becomes `Button("Play") { appModel?.togglePlayPause() }.disabled(appModel == nil)`.
- Do the same for navigation path (`focusedSceneValue(\.detailPath, $detailPath)` passes a `Binding<NavigationPath>` so Back/Forward in the menu can mutate the current window's stack).
- Do the same for the toolbar's search focus state so Cmd+F works from any window.
- Reference: [The SwiftUI cookbook for focus — WWDC23](https://developer.apple.com/videos/play/wwdc2023/10162/), [SwiftUI FocusedValue, macOS Menus, and the Responder Chain — philz.blog](https://philz.blog/swiftui-focusedvalue-macos-menus-and-the-responder-chain/).

### Issue 10: Restore window size, position, sidebar visibility, inspector visibility, and last-viewed screen across launches
**Labels:** `area:macos`, `kind:feat`, `priority:p1`
**Effort:** M
**Depends on:** 1

- `WindowGroup` auto-restores size/position on macOS 14+ — we just need to not opt out. Verify by removing our `.defaultSize` only takes effect when there is no stored state.
- Per-scene UI we care about but isn't the default (`NavigationSplitViewVisibility`, inspector open/closed, current sidebar selection, last-visited album ID) should use `@SceneStorage`:
  ```swift
  @SceneStorage("sidebar.visibility") private var sidebarVis: NavigationSplitViewVisibility = .automatic
  @SceneStorage("inspector.shown") private var inspectorShown = false
  @SceneStorage("nav.top") private var topSelection = "library"
  ```
  `@SceneStorage` only supports `Bool/Int/Double/String/URL/Data`, so encode the enum as `rawValue` (String).
- App-wide prefs that should survive across all scenes (last server URL, last username, volume) belong in `@AppStorage` backed by `UserDefaults`.
- For the detail `NavigationPath`, use `NavigationPath.Codable` + `@SceneStorage` with a `Data` blob. Track IDs in the path must be `Codable` — they already are (`Album.id: String`).
- Add `.restorationBehavior(.automatic)` (the default) to the main `WindowGroup`, and `.restorationBehavior(.disabled)` to the About window and Mini Player (Issue 12) so those don't reopen unexpectedly.
- Reference: [Customizing window styles and state-restoration behavior in macOS](https://developer.apple.com/documentation/SwiftUI/Customizing-window-styles-and-state-restoration-behavior-in-macOS), [WWDC24 "Tailor macOS windows with SwiftUI"](https://developer.apple.com/videos/play/wwdc2024/10148/).

### Issue 11: Support multiple main windows via File > New Window + File > New Tab, each with independent state
**Labels:** `area:macos`, `kind:feat`, `priority:p1`
**Effort:** M
**Depends on:** 9, 10

- `WindowGroup` already permits multiple windows; we just need the menu items and to make sure `AppModel` is per-window, not a singleton. Today it's created once in `JellifyApp.init()` — that's fine for session/login state, but playback state per-window would be weird (second window would play its own audio over the first). Decision: **session + playback are global**; **navigation state is per-window**. Extract `NavState` to a scene-scoped `@State` struct; keep `AppModel` global via `.environment(model)`.
- Tabbing: set `NSApplicationDelegate.applicationDidFinishLaunching` to `NSWindow.allowsAutomaticWindowTabbing = true`, then File > New Tab (Cmd+T) opens a tab in the current window group. File > New Window (Cmd+N) uses `openWindow(id: "main")` from `@Environment(\.openWindow)`.
- Verify `Merge All Windows` and `Move Tab to New Window` work (they come for free from `NSWindow.tabbingMode`).
- Reference: [Multi window SwiftUI macOS app working with menu commands — Medium](https://ondrej-kvasnovsky.medium.com/multi-window-swiftui-macos-app-working-with-menu-commands-4aff7d6c3bd6).

### Issue 12: Ship a Mini Player as a separate borderless `UtilityWindow` (macOS 15+) / `NSPanel` (14)
**Labels:** `area:macos`, `kind:feat`, `priority:p1`
**Effort:** L
**Depends on:** 9

- Apple Music's Option-Cmd-M mini player: ~300×80, always on top, stays across spaces, no traffic-light chrome. Our version: borderless, shows artwork + title/artist + transport, subscribes to the same `AppModel` via environment.
- On macOS 15+: add a second scene `UtilityWindow("Mini Player", id: "mini-player") { MiniPlayerView().environment(model) }.windowStyle(.plain).windowResizability(.contentSize).defaultWindowPlacement { ... center bottom }.restorationBehavior(.disabled)`. `UtilityWindow` gives floating-above-other-windows and auto-hide-when-app-inactive for free, plus the window appears under the View menu rather than Window menu.
- On macOS 14: fall back to an `NSPanel` wrapped via `NSViewControllerRepresentable`. Subclass: `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `isMovableByWindowBackground = true`, `hidesOnDeactivate = false` (controversial — Apple Music hides, Spotify doesn't; recommend an `@AppStorage` toggle in Settings).
- Menu wiring: `Window > Mini Player` toggles via `openWindow(id: "mini-player")` / `dismissWindow(id:)`. Shortcut Cmd+Option+M (matches Music's Option-Cmd-M).
- Reference: [How to create a SwiftUI floating window in macOS 15 — polpiella.dev](https://www.polpiella.dev/creating-a-floating-window-using-swiftui-in-macos-15), [SwiftUI Floating Panel: NSPanel Patterns for macOS Apps — fazm.ai](https://fazm.ai/blog/swiftui-floating-panel).

### Issue 13: Drag-reorder Up Next queue rows via Transferable + `draggable`/`dropDestination`
**Labels:** `area:macos`, `kind:feat`, `priority:p1`
**Effort:** M
**Depends on:** -

- Once we ship the Up Next inspector, users will expect to drag rows to reorder. Use modern API:
  ```swift
  List {
      ForEach(queue) { track in TrackRow(…)
          .draggable(track) { TrackDragPreview(track) }
      }
      .onMove { src, dst in model.reorderQueue(from: src, to: dst) }
  }
  ```
  `Track` must conform to `Transferable`. Provide both a canonical UTI (`public.jellify.track`) and a `ProxyRepresentation` fallback for text so dragging to TextEdit drops the track title.
- For reordering inside `LazyVStack` (since `List` inside inspectors has layout quirks on macOS 14), use a manual `DropDelegate` that updates `@State var draggingID: String?` and swaps rows on hover.
- Reference: [Moving List Items Using Drag and Drop in SwiftUI Mac Apps — swiftdevjournal.com](https://www.swiftdevjournal.com/moving-list-items-using-drag-and-drop-in-swiftui-mac-apps/), [Enabling drag reordering in SwiftUI lazy grids — danielsaidi.com](https://danielsaidi.com/blog/2023/08/30/enabling-drag-reordering-in-swiftui-lazy-grids).

### Issue 14: Export a dragged track to Finder as a file promise or `.m3u` reference
**Labels:** `area:macos`, `kind:feat`, `priority:p2`
**Effort:** L
**Depends on:** 13

- Power-user feature Doppler and Swinsian support: drag a track out of the library onto the desktop → get a playable file (or, since ours is streaming, an `.m3u` referencing the Jellyfin stream URL, or a `.webloc` to the album's web player page). Start with `.m3u` for simplicity.
- Use `NSFilePromiseProvider` via `NSViewRepresentable` since SwiftUI's `Transferable` doesn't yet support file promises cleanly (as of macOS 14). Conform a wrapper to `NSFilePromiseProviderDelegate` and return a temporary URL for the generated `.m3u`.
- Alternatively expose as Transferable `FileRepresentation(exportedContentType: .m3uPlaylist)` which writes a temp file on demand — simpler, still gets the drop-to-Finder UX.
- Acceptance: drag any row from AlbumDetailView onto Finder → resulting `.m3u` opens in VLC and streams. Drag multiple selected rows → multi-track `.m3u`.
- Reference: [SwiftUI on macOS: Drag and drop — eclecticlight.co](https://eclecticlight.co/2024/05/21/swiftui-on-macos-drag-and-drop-and-more/).

### Issue 15: Add context menus to track rows, album cards, artist rows, and sidebar items
**Labels:** `area:macos`, `kind:feat`, `priority:p0`
**Effort:** M
**Depends on:** 4

- Every clickable thing needs a right-click menu. Use SwiftUI's `.contextMenu { … }` modifier which on macOS 14+ maps to a proper `NSMenu`.
- **Track rows**: Play, Play Next, Play Last (Add to Queue), Go to Album, Go to Artist, Add to Playlist > submenu of user playlists, Favorite / Unfavorite, Copy Share Link, Show in Jellyfin (opens server URL), Divider, Info (Cmd+I).
- **Album cards**: Play Album, Shuffle Album, Play Next, Go to Artist, Add to Library (already is), Copy Link, Info.
- **Artist rows**: Play Top Tracks, Shuffle, Go to Artist, Copy Link.
- **Playlist rows in sidebar**: Play, Shuffle, Rename, Duplicate, Delete, Edit Details.
- Multi-selection: for `List` with `selection: Set<Track.ID>`, wrap `.contextMenu(forSelectionType: Track.ID.self) { ids in … }` so right-clicking on a selection gets bulk actions (added in macOS 13).
- All actions should also have keyboard shortcuts advertised in the menu item (so users learn them): e.g. `Button("Play Next") { … }.keyboardShortcut("n", modifiers: [.option])`.

### Issue 16: Replace bespoke hover/selection colors with macOS-native hover and focus rings where appropriate
**Labels:** `area:macos`, `kind:polish`, `priority:p1`
**Effort:** S
**Depends on:** 1

- `TrackRow` currently handles `@State var isHovering` with `.onHover` and paints `Theme.rowHover`. That's fine for custom-styled rows but we lose keyboard focus ring and VoiceOver. Fix:
  - Give each row `.focusable()` and draw selection/focus states based on `@FocusState`. Use `.contentShape(.interaction, RoundedRectangle(cornerRadius: 6))` so the focus ring matches the visual shape (via the custom shape API added in macOS 14).
  - Respect `@Environment(\.isHoverEffectEnabled)` and the motion-reduction accessibility flag — disable the scale/translate on hover for users with `Reduce Motion`.
  - For album cards: add a subtle hover zoom (`.scaleEffect(isHovering ? 1.02 : 1.0)`) with `.animation(.easeOut(duration: 0.12), value: isHovering)` — matches Apple Music's card hover.
- Reference: [Custom hover effects in SwiftUI — swiftwithmajid.com](https://swiftwithmajid.com/2024/09/03/custom-hover-effects-in-swiftui/), [The SwiftUI cookbook for focus — WWDC23](https://developer.apple.com/videos/play/wwdc2023/10162/).

### Issue 17: Wrap `NSVisualEffectView` to provide the translucent sidebar + translucent player-bar materials
**Labels:** `area:macos`, `kind:polish`, `priority:p1`
**Effort:** S
**Depends on:** 2

- SwiftUI's built-in `Material.bar`, `.thinMaterial`, etc. work but give a neutral-colored blur. Apple Music's sidebar is `NSVisualEffectView.Material.sidebar` with `blendingMode = .behindWindow` — a specific material that subtly tints toward the desktop wallpaper. Same for the bottom player bar using `.hudWindow` or `.headerView` material.
- Add a reusable helper:
  ```swift
  struct VisualEffectBackground: NSViewRepresentable {
      var material: NSVisualEffectView.Material
      var blending: NSVisualEffectView.BlendingMode = .behindWindow
      func makeNSView(context: Context) -> NSVisualEffectView {
          let v = NSVisualEffectView()
          v.material = material; v.blendingMode = blending
          v.state = .followsWindowActiveState
          v.isEmphasized = true
          return v
      }
      func updateNSView(_ v: NSVisualEffectView, context: Context) {
          v.material = material; v.blendingMode = blending
      }
  }
  ```
- Use `.background(VisualEffectBackground(material: .sidebar))` under the sidebar and `.background(VisualEffectBackground(material: .hudWindow, blending: .withinWindow))` under `PlayerBar`.
- Keep our purple-tint overlays at low alpha (~0.08) on top of the vibrancy so the brand reads through without killing the wallpaper blur.
- Reference: [NSVisualEffectView.Material.sidebar](https://developer.apple.com/documentation/AppKit/NSVisualEffectView/Material-swift.enum/sidebar), [Visual Effect Views in SwiftUI — alanquatermain.me](https://alanquatermain.me/programming/swiftui/2019-11-18-VisualEffectView/).

### Issue 18: Add trackpad haptics via `NSHapticFeedbackManager` for transport buttons and level changes
**Labels:** `area:macos`, `kind:polish`, `priority:p2`
**Effort:** S
**Depends on:** -

- macOS-only; no-op on external keyboards without Force Touch trackpads. Add a small helper:
  ```swift
  enum Haptic {
      static func level()     { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
      static func alignment() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
      static func generic()   { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
  }
  ```
- Fire `Haptic.generic()` on Play/Pause toggle, `Haptic.alignment()` on scrubber snap-to-chapter, `Haptic.level()` on volume step-change from Cmd+↑/↓, and when a drag-reorder snaps to a new row.
- Respect `UIAccessibility.isReduceMotionEnabled` equivalent — macOS doesn't have that exact flag, but check `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` and skip haptics then.
- Reference: [Developer Guide about Haptics on Apple Platforms — blog.eidinger.info](https://blog.eidinger.info/haptics-on-apple-platforms).

### Issue 19: Build a Cmd+K command palette (spotlight-style) for jumping to any artist/album/playlist/command
**Labels:** `area:macos`, `kind:feat`, `priority:p1`
**Effort:** L
**Depends on:** 5, 7

- Modern desktop-app table stakes (Raycast, Spotlight, Arc, Linear, Spotify Quick Search). Open with Cmd+K anywhere in the app, presents a floating rounded panel centered on the window.
- Architecture: separate `Window("Command Palette", id: "palette")` with `.windowStyle(.plain)`, `.windowLevel(.floating)`, `.windowResizability(.contentSize)`, `.defaultLaunchBehavior(.suppressed)` (macOS 15) so it doesn't reopen at launch. Dismiss on `.onExitCommand` (Escape) or on loss of focus.
- Content: `TextField` at top, then a `List` of results grouped by type (Commands, Artists, Albums, Tracks, Playlists). Drive results via an async `AppModel.paletteSearch(query:)` that merges:
  - static commands pulled from the `Commands` tree,
  - local library fuzzy matches,
  - remote `core.search` results (debounced 250ms).
- Up/Down arrow + Return to activate; Cmd+1/2/3/… to jump to numbered groups.
- Reference: [DSFQuickActionBar — github.com/dagronf](https://github.com/dagronf/DSFQuickActionBar) as a prior-art reference (don't pull in the package, but mirror the interaction).

### Issue 20: Full-screen mode: correct traffic-light handling, toolbar auto-hide, chrome behavior
**Labels:** `area:macos`, `kind:polish`, `priority:p2`
**Effort:** S
**Depends on:** 2, 3

- Enter full-screen (green traffic light / `Cmd+Ctrl+F`) → traffic lights gone, toolbar should slide up when the cursor hits the top edge. Because we used `.hiddenTitleBar` + `.windowToolbarStyle(.unifiedCompact)`, we already get this; verify sidebar and PlayerBar stay put and nothing reserves space for the hidden menu bar.
- Add a view-menu item "Enter Full Screen" that calls `NSApp.keyWindow?.toggleFullScreen(nil)` with shortcut Cmd+Ctrl+F (don't override, the system provides it, but we want the menu item present for discoverability).
- Confirm that when we use Cmd+Shift+F for "Full Player" (big now-playing view, Issue 21), there's no conflict — full-screen OS shortcut is Cmd+Ctrl+F.

### Issue 21: Implement a "Full Player" now-playing view activated via Cmd+Shift+F, with blurred artwork backdrop
**Labels:** `area:macos`, `kind:feat`, `priority:p2`
**Effort:** L
**Depends on:** 17

- Modal full-window take-over (not OS full-screen) that mirrors Apple Music's Cmd+Shift+F: giant artwork centered, track title + artist, scrubber, lyrics if available, transport, queue on the side.
- Present as a `.sheet(isPresented:)` bound to `@SceneStorage("fullPlayer.shown")`, or push onto the detail stack — sheet is more faithful to Apple Music which overlays the window.
- Background: repeat the artwork blurred at 40px radius + 40% dim, matching Music's aesthetic.
- Escape closes, Cmd+Shift+F toggles. Menu item under View.

### Issue 22: Customize Dock tile: high-quality icon, dock menu with transport, badge for active downloads/syncs
**Labels:** `area:macos`, `kind:polish`, `priority:p2`
**Effort:** M
**Depends on:** -

- Ship a proper `.icns` built from the design's jellyfish glyph at all sizes (16, 32, 128, 256, 512, 1024, plus @2x). Produced via `iconutil` from a `.iconset`.
- Implement dock menu — right-clicking the dock icon gives Play/Pause, Next, Previous, Recent Albums (submenu of last 5 visited). `NSApplicationDelegate.applicationDockMenu(_:)` returns an `NSMenu` that we build from current `AppModel.status` plus a small recent-history list.
- Badge: when a background sync or download is running, `NSApp.dockTile.badgeLabel = "\(pendingCount)"`. Clear on completion.
- Reference: [NSDockTile](https://developer.apple.com/documentation/appkit/nsdocktile), [DSFDockTile — github.com/dagronf](https://github.com/dagronf/DSFDockTile).

### Issue 23: Plan Swift 6 strict-concurrency migration; document the UniFFI blocker and interim Sendable wrappers
**Labels:** `area:macos`, `kind:chore`, `priority:p2`
**Effort:** M
**Depends on:** -

- We're on Swift 5 language mode because UniFFI 0.28's generated types aren't `Sendable` — specifically `JellifyCore`, `Track`, `Album`, `Session`, etc., which we freely pass across `Task.detached` today. Plan:
  1. Keep `@preconcurrency import JellifyCore` for now (already done in several files).
  2. File/follow an upstream UniFFI issue tracking Sendable annotations on generated records (they're plain structs, just need the annotation). Track: [mozilla/uniffi-rs](https://github.com/mozilla/uniffi-rs).
  3. Write a local `JellifySendable.swift` that declares unchecked conformance for the generated types we pass across actors:
     ```swift
     extension Track: @unchecked Sendable {}
     extension Album: @unchecked Sendable {}
     extension Session: @unchecked Sendable {}
     // etc.
     ```
     Valid because the generated structs contain only value types (strings, ints, arrays of other records).
  4. Flip `swift-tools-version` language mode to 6 in `Package.swift` once the wrappers compile cleanly under `-strict-concurrency=complete`.
  5. Convert `AppModel.pollTimer: Timer?` to a `Task { while !Task.isCancelled { … } }` since `Timer` closures are non-Sendable; this also avoids the current pattern of a `Timer` hopping onto `@MainActor` via a nested `Task`.
- Acceptance: package builds under Swift 6 language mode with zero warnings and full strict concurrency. Do not block M3 on this; target M4.
- Reference: [Adopting strict concurrency in Swift 6 apps](https://developer.apple.com/documentation/swift/adoptingswift6).

### Issue 24: Show "Keyboard Shortcuts" help window exposing the full shortcut map, filterable by menu
**Labels:** `area:macos`, `kind:feat`, `priority:p2`
**Effort:** S
**Depends on:** 5

- Users ask "what are all the shortcuts?" — Apple Music has no such screen; Doppler does. Add a second `Window("Keyboard Shortcuts", id: "shortcuts-help")` scene that renders a searchable two-column list: left is the action name, right is the shortcut rendered with proper symbol glyphs (⌘⇧⌥⌃).
- Source of truth: a single `AppShortcuts.swift` file containing `struct Shortcut { id: String; name: String; section: Section; key: KeyEquivalent; modifiers: EventModifiers }`. Feed the same struct to the menu command builder (Issue 5) so menu + help window never drift.
- Triggered from Help > Keyboard Shortcuts, Cmd+? (Cmd+Shift+/ on US keyboards).

### Issue 25: Add a dedicated "About Jellify" window via `CommandGroup(replacing: .appInfo)` with version, build, server, credits
**Labels:** `area:macos`, `kind:polish`, `priority:p2`
**Effort:** S
**Depends on:** 5

- Default SwiftUI About is a flat panel with icon + version. Custom one lets us show connected server, user, acknowledgements, and a link to the GitHub repo.
- `Window("About Jellify", id: "about") { AboutView() }.windowStyle(.hiddenTitleBar).windowResizability(.contentSize).restorationBehavior(.disabled).commandsRemoved()`. The `.commandsRemoved()` keeps this window out of the Window menu.
- Hook the About menu item: `CommandGroup(replacing: .appInfo) { Button("About Jellify") { openWindow(id: "about") } }`.
- Reference: [Create a fully custom About window for a Mac app in SwiftUI — nilcoalescing.com](https://nilcoalescing.com/blog/FullyCustomAboutWindowForAMacAppInSwiftUI/).

### Issue 26: Ensure accessibility: VoiceOver labels on transport, focus order in sidebar, keyboard-only reachability
**Labels:** `area:macos`, `kind:polish`, `priority:p1`
**Effort:** M
**Depends on:** 16

- Audit per screen:
  - `PlayerBar`'s play button is currently an `Image` inside a `Button` with no label — VoiceOver reads "button". Add `.accessibilityLabel("Play") / "Pause"` bound to `model.status.state`, `.accessibilityValue("\(Int(pct*100)) percent played")` on the progress bar.
  - Sidebar nav rows: `.accessibilityAddTraits(.isHeader)` on section headers, `.accessibilityHint("Switches to \(label) view")` on nav items.
  - Track rows: `.accessibilityElement(children: .combine)` so VoiceOver reads "Track N, Title, Artist, 3 minutes 42 seconds". Action: VoiceOver rotor "play" action → call `onPlay`.
  - Sliders: default SwiftUI `Slider` is already accessible; ensure the custom capsule-progress in `PlayerBar` exposes a `Slider` under the hood (or wrap it in one with `.accessibilityRepresentation { Slider(...) }`).
- Keyboard-only test: tab order should be sidebar → toolbar → content → player bar. Sidebar rows focusable; album cards focusable; track rows focusable. Space plays the focused track.

### Issue 27: Plug in `NSApplicationDelegateAdaptor` for dock menu, tab customization, and wake-from-sleep reconnect
**Labels:** `area:macos`, `kind:chore`, `priority:p1`
**Effort:** S
**Depends on:** -

- We currently have no AppDelegate, so we can't set `NSWindow.allowsAutomaticWindowTabbing`, we can't implement `applicationDockMenu`, we can't react to `NSWorkspace.willSleepNotification` to pause / `didWakeNotification` to reconnect.
- Add:
  ```swift
  final class JellifyAppDelegate: NSObject, NSApplicationDelegate {
      weak var model: AppModel?
      func applicationDidFinishLaunching(_: Notification) {
          NSWindow.allowsAutomaticWindowTabbing = true
      }
      func applicationDockMenu(_: NSApplication) -> NSMenu? { /* Issue 22 */ }
      // + NSWorkspace sleep/wake observers → model.pause() / model.reconnect()
  }
  ```
  Bind via `@NSApplicationDelegateAdaptor(JellifyAppDelegate.self) var appDelegate` in `JellifyApp`.
- Have the delegate publish the `AppModel` reference back from `init` so it can reach state without a global.

### Issue 28: Per-window Settings via `Settings` scene + focused bindings, with `Cmd+,` standard shortcut
**Labels:** `area:macos`, `kind:feat`, `priority:p1`
**Effort:** M
**Depends on:** 5

- macOS convention: settings live in a separate window opened with Cmd+, via the Jellify > Settings menu (SwiftUI wires this automatically if you use the `Settings` scene).
- Add:
  ```swift
  Settings {
      TabView {
          GeneralSettingsView().tabItem { Label("General", systemImage: "gear") }
          PlaybackSettingsView().tabItem { Label("Playback", systemImage: "play") }
          ServerSettingsView().tabItem { Label("Server", systemImage: "server.rack") }
          AdvancedSettingsView().tabItem { Label("Advanced", systemImage: "terminal") }
      }
      .frame(width: 560, height: 380)
      .environment(model)
  }
  ```
- Route "Switch Server…" and "Tweaks…" menu items to open Settings with a specific tab pre-selected via `@SceneStorage("settings.activeTab")`.
- All user prefs that live here should be `@AppStorage` (app-wide) unless they're intentionally per-window (none today, but mini-player "always on top" could be an exception).

---

## Quick prioritization summary

**P0 (ship before GA — without these we feel like a web app wrapper):**
1 NavigationSplitView shell · 2 hidden title bar · 3 toolbar · 4 NavigationStack drill-down · 5 full menu bar · 6 Playback menu · 7 core shortcuts · 8 media-key contract · 15 context menus

**P1 (meaningful polish for 1.0):**
9 FocusedValue plumbing · 10 state restoration · 11 multi-window/tab · 12 mini player · 13 queue reorder · 16 hover/focus · 17 visual-effect views · 19 Cmd+K palette · 26 accessibility · 27 AppDelegate · 28 Settings scene

**P2 (nice-to-have for a ".1" release):**
14 drag-to-Finder export · 18 haptics · 20 full-screen tweaks · 21 Full Player view · 22 dock icon/menu/badge · 23 Swift 6 migration · 24 shortcuts help · 25 custom About
