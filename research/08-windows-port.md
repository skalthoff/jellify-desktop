# Jellify Windows Port — Issue Roadmap

This roadmap takes `windows/` (currently an empty placeholder) to parity with the macOS MVP and on to Apple Music–level polish. The stack is WinUI 3 (Windows App SDK 1.8.x stable, latest as of March 2026) on `net8.0-windows10.0.22621.0`, MVVM via `CommunityToolkit.Mvvm`, audio via `Windows.Media.Playback.MediaPlayer` + `MediaPlaybackList`, and the Rust core embedded through UniFFI C# bindings.

**Research notes (current as of 2026-04):**
- **WinAppSDK 1.8.5** is current stable (released March 18, 2026). 1.7.9 is the long-tail LTS option. 2.0 is experimental only — stick with 1.8.x.
- **uniffi-bindgen-cs** (NordSecurity) is at `v0.10.0+v0.29.4` — still 0.x, no stability guarantees, but tracks uniffi-rs 0.29. Our core is pinned to `uniffi = 0.28`, so we will need to bump the core to 0.29 (see W-M1 Issue 2).
- **Visual Studio 2026** ships single-project MSIX tooling built in.
- **Self-contained WinAppSDK** (`WindowsAppSDKSelfContained=true`) avoids the Runtime installer prerequisite — required for unpackaged distribution.
- **MediaPlayer + SMTC** integrate automatically in packaged apps. MediaBinder + IRandomAccessStream is the canonical pattern for auth-header stream loading.
- **Velopack** (Rust-based Squirrel successor) is the recommended non-Store auto-updater in 2026.

Milestones:
- **W-M1** — Scaffold + Rust core binding (Issues 1–6)
- **W-M2** — Core screens MVP, login → play (Issues 7–15)
- **W-M3** — Polish parity with macOS M3 (Issues 16–23)
- **W-M4** — Distribution: MSIX + auto-update (Issues 24–28)

---

## W-M1: Scaffold + Rust core binding

### Issue 1: Create `windows/` solution skeleton targeting WinAppSDK 1.8
**Labels:** `area:windows`, `kind:chore`, `priority:p0`
**Effort:** M

Stand up the C# solution under `windows/` so everything else can layer on. Target `net8.0-windows10.0.22621.0` (min Win10 1809 / build 17763, effectively Win11 for Mica). Use plural `<RuntimeIdentifiers>win-x64;win-arm64</RuntimeIdentifiers>` and add `<UseRidGraph>true</UseRidGraph>` to avoid the 1.5-era RID-graph regression. Add `<WindowsAppSDKSelfContained>true</WindowsAppSDKSelfContained>` so unpackaged `.exe` builds don't require the Runtime installer.

Structure:
```
windows/
  Jellify.sln
  src/
    Jellify.App/              # WinUI 3 app (Microsoft.WindowsAppSDK)
    Jellify.Core/             # P/Invoke + UniFFI wrapper around jellify_core.dll
    Jellify.Player/           # MediaPlayer + SMTC + MediaPlaybackList
    Jellify.Domain/           # DTOs, VMs, navigation contracts
  tools/
    build-core.ps1
    gen-bindings.ps1
```

NuGet floor: `Microsoft.WindowsAppSDK 1.8.250312004` (or latest 1.8.x at time of work), `CommunityToolkit.Mvvm 8.x`, `Microsoft.Extensions.DependencyInjection 8.0`, `Microsoft.Extensions.Hosting 8.0`.

Acceptance: `dotnet build windows/Jellify.sln` succeeds on `windows-latest`; `dotnet run --project windows/src/Jellify.App -c Debug` launches a bare WinUI 3 window on a Win11 VM.

### Issue 2: Bump core to uniffi-rs 0.29 and lock UniFFI toolchain
**Labels:** `area:windows`, `area:core`, `kind:chore`, `priority:p0`
**Effort:** M

`uniffi-bindgen-cs v0.10.0` tracks uniffi-rs 0.29.4; the workspace `Cargo.toml` pins `uniffi = "0.28"`. Bump to `0.29` in `Cargo.toml` and fix the small breaking changes (mostly `FfiConverter` trait edits). Re-run the macOS build to verify no regression there. Document the toolchain triple in `CONTRIBUTING.md`: Rust ≥ 1.88 (uniffi-bindgen-cs requirement), cargo-ndk not needed on Windows.

Acceptance: `cargo build -p jellify_core --target x86_64-pc-windows-msvc` succeeds on CI; macOS xcframework still builds.

### Issue 3: Build script — produce `jellify_core.dll` for x64 and arm64
**Labels:** `area:windows`, `area:core`, `kind:chore`, `priority:p0`
**Effort:** M

Add `windows/tools/build-core.ps1` that runs `cargo build --release -p jellify_core --target x86_64-pc-windows-msvc` and `aarch64-pc-windows-msvc`, then copies `jellify_core.dll` + `jellify_core.dll.lib` to `windows/src/Jellify.Core/native/{win-x64,win-arm64}/`. Wire via MSBuild `<None Include="...dll" CopyToOutputDirectory="PreserveNewest"/>` scoped per-RID. Add a `BeforeBuild` target that invokes the script if the DLL is missing or stale (mtime vs `core/src/**`).

Cross-compile to arm64 from an x64 host using `rustup target add aarch64-pc-windows-msvc` — no LLVM shenanigans needed.

Acceptance: Fresh clone → `dotnet build` on x64 produces `jellify_core.dll` in `bin\Debug\net8.0-windows10.0.22621.0\win-x64\native\`; arm64 publish produces the arm64 variant.

### Issue 4: Generate C# UniFFI bindings and wrap in `Jellify.Core`
**Labels:** `area:windows`, `area:core`, `kind:feat`, `priority:p0`
**Effort:** L

Install `uniffi-bindgen-cs` as a binstall. Add `windows/tools/gen-bindings.ps1`:
```
uniffi-bindgen-cs \
  --library target\release\jellify_core.dll \
  --out-dir windows\src\Jellify.Core\Generated \
  --config uniffi.toml
```

Add `uniffi.toml` with `[bindings.csharp]` section setting `namespace = "Jellify.Core.Native"` and `library_name = "jellify_core"`. The generated bindings require `<AllowUnsafeBlocks>true</AllowUnsafeBlocks>` in the csproj — set that.

Wrap the generated types in hand-written idiomatic C# facades (`JellyfinClient`, `QueueStore`, `PlaybackStateStore`) that live in `Jellify.Core/` (not `Generated/`) so we can shape the public API without fighting the generator. Regenerate as a CI step; commit the generated files so the build doesn't require `uniffi-bindgen-cs` on every dev machine.

Acceptance: Unit test in `windows/tests/Jellify.Core.Tests/` instantiates a `JellyfinClient`, calls `ping()` via wiremock, and asserts success.

### Issue 5: Dependency injection + app host
**Labels:** `area:windows`, `kind:feat`, `priority:p0`
**Effort:** S

In `App.xaml.cs`, build a `HostApplicationBuilder`, register `IJellyfinClient`, `IQueueStore`, `IPlaybackStateStore`, `IPlayerService` (to be added in Issue 10), all view models (as `Transient`), and the `NavigationService` (Issue 6). Use `Ioc.Default.ConfigureServices(...)` from CommunityToolkit.Mvvm so VMs can resolve via `App.Services.GetRequiredService<T>()` outside the XAML activation path.

Acceptance: Smoke test resolves `MainViewModel` through the container and renders the main window.

### Issue 6: Navigation frame + shell with NavigationView
**Labels:** `area:windows`, `kind:feat`, `priority:p0`
**Effort:** M

Implement `ShellPage.xaml` containing a `NavigationView` (left pane) + `Frame` (content). Add `INavigationService.NavigateTo<TViewModel>(object? param = null)` that resolves the page type via a VM→Page registry and calls `Frame.Navigate`. Back stack: use `Frame.CanGoBack` / `GoBack`, hook the X1/mouse-back button (`PointerDevice.PointerButtonPressedChanged` on `Window.Content`) and `Alt+Left` via `KeyboardAccelerator`. Persist last-visited page id in local settings for next-launch restore.

Acceptance: Navigating to 3 placeholder pages, then back-button, traces the expected VM lifecycle.

---

## W-M2: Core screens MVP — login → play

### Issue 7: Custom Mica title bar with Windows 11 caption buttons
**Labels:** `area:windows`, `kind:feat`, `priority:p1`
**Effort:** M

Set `Window.SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base }` and `AppWindow.TitleBar.ExtendsContentIntoTitleBar = true`. Set `WindowCaptionBackground` and `WindowCaptionBackgroundDisabled` to `Transparent` in `App.xaml`. Implement a custom `<Grid x:Name="AppTitleBar">` row with app icon, title text, and a central drag region; call `SetTitleBar(AppTitleBar)`. Let the system render the minimize/maximize/close buttons by leaving `AppWindow.TitleBar.ButtonBackgroundColor = Transparent` — on Win11 this produces the native fluent caption buttons for free.

Fall back to the drawn-by-us title bar on Win10 (no Mica) — detect via `Environment.OSVersion` and swap the backdrop to `DesktopAcrylicBackdrop`.

Acceptance: On Win11, dragging the title bar region moves the window; double-click maximizes; min/max/close buttons show the correct theme color. Mica tint is visible through the sidebar.

### Issue 8: Theme system — 5 Jellify presets × 3 modes (dark/oled/light)
**Labels:** `area:windows`, `kind:feat`, `priority:p1`
**Effort:** L

Port `macos/Sources/Jellify/Theme/Theme.swift` tokens to a WinUI `ResourceDictionary.ThemeDictionaries` structure. Presets (matches Tamagui/macOS): `purple` (default, `#0C0622` bg / `#887BFF` primary / `#CC2F71` accent), `blue`, `teal`, `red`, `gold`. Modes: Light, Dark, OLED (pure black bg overrides). Expose `JellifyBrandBackgroundBrush`, `JellifyBrandPrimaryBrush`, `JellifyAccentBrush`, `JellifyInkBrush`, `JellifyInk2Brush`, `JellifyInk3Brush`, `JellifyBorderBrush` as `{ThemeResource}` entries.

Implementation: generate 5 sets of 3 `ResourceDictionary` files (`Theme.Purple.Dark.xaml`, etc.) and swap at runtime by rebuilding `Application.Resources.MergedDictionaries` and walking the visual tree resetting `RequestedTheme`. Persist selection via `ApplicationData.Current.LocalSettings`.

Mica tint: Mica uses the `SolidBackgroundFillColorBase` theme color — override that in each preset dictionary to get brand-tinted Mica.

Acceptance: Settings combo box switches preset and mode live without app restart; all 15 combinations render correctly; screenshot diff against macOS theme reference.

### Issue 9: Login screen
**Labels:** `area:windows`, `kind:feat`, `priority:p0`
**Effort:** M

Port `macos/Sources/Jellify/Screens/LoginView.swift`. Form: server URL (`TextBox` with `InputScope="Url"`), username, password (`PasswordBox`). Submit button triggers `IJellyfinClient.Authenticate`. On success, store token via Credential Manager (Issue 19) and `NavigateTo<HomeViewModel>`. Show validation errors inline (`InfoBar` with `Severity="Error"`). Remember last server URL.

Discovery: if the user types `http://` without a port, try both `:8096` and the entered value.

Acceptance: Can connect to a local demo Jellyfin instance and land on Home.

### Issue 10: Player service — MediaPlayer + MediaPlaybackList + auth
**Labels:** `area:windows`, `kind:feat`, `priority:p0`
**Effort:** XL

Implement `IPlayerService` backed by `Windows.Media.Playback.MediaPlayer`. Queue modeling: one `MediaPlaybackList` whose `Items` are `MediaPlaybackItem`s. Each `MediaPlaybackItem` wraps a `MediaSource` built from `MediaSource.CreateFromMediaBinder(binder)`, where `binder.Binding` handler resolves the audio URL on-demand from the Rust core and attaches an `HttpRandomAccessStream` with the `Authorization` / `X-Emby-Token` headers. Use `MediaBindingEventArgs.GetDeferral()` during async stream resolution.

Set `playbackList.MaxPrefetchTime = TimeSpan.FromSeconds(30)` for prefetch. Set `AutomaticallyLoadedNextTrackProperties = MediaPlaybackAutomaticPropertiesGroup.Artist | Title | AlbumArtist | AlbumTrackNumber` so SMTC metadata swaps at track boundaries.

Gapless: `MediaPlaybackList` provides gapless playback natively for MP3/AAC where LAME/iTunSMPB metadata is present; for FLAC it's inherently gapless. No extra work needed — verify with a known gapless album (e.g., Dark Side of the Moon).

Populate `MediaPlaybackItem.GetDisplayProperties()` with track title, artist, album, `AlbumArt` via `MediaItemDisplayProperties.Thumbnail = RandomAccessStreamReference.CreateFromUri(artworkUri)` so SMTC renders artwork.

Acceptance: Play an album end-to-end, verify gapless between tracks, Skip Next/Prev work, volume changes persist across app restart.

### Issue 11: System Media Transport Controls integration
**Labels:** `area:windows`, `kind:feat`, `priority:p0`
**Effort:** S

Most of this is automatic — `MediaPlayer` instantiated in a WinUI app with a windowed UI registers itself as the system media session automatically. Verify:
- Action Center media widget shows title/artist/album/art.
- Lock-screen controls work.
- Hardware media keys (Play/Pause, Next, Prev) route to our player even when another app is focused.
- `CommandManager.NextBehavior.EnablingRule = MediaCommandEnablingRule.Always` so Next is enabled on last track (cycles back to start per our queue policy).

Required manual work: set `SystemMediaTransportControls.IsEnabled = true` explicitly (defaults vary), subscribe to `ButtonPressed` for edge cases (seek buttons if added later).

Acceptance: Press Win+K media dialog — shows Jellify as the active session; keyboard Play/Pause toggles playback while focus is elsewhere.

### Issue 12: Home screen — recent, recommended, continue listening
**Labels:** `area:windows`, `kind:feat`, `priority:p1`
**Effort:** M

Port `macos` home. Sections: "Continue Listening", "Recently Added Albums", "Made For You", "Your Favorites". Horizontal `ScrollViewer` + `ItemsRepeater` with a custom `StackLayout(Orientation=Horizontal)`. Each card: 180px album art (`Image` with `NineGrid` shadow), title, subtitle. Tap navigates to Album/Artist/Playlist detail. Pull-to-refresh via `RefreshContainer`.

Data: queries come from `IJellyfinClient` (already implemented in core). Show loading skeletons while `IsFetching`.

Acceptance: Home loads on a populated server within 2s; scrolling is smooth at 60fps on a mid-tier laptop.

### Issue 13: Library screen — albums grid (virtualized)
**Labels:** `area:windows`, `kind:feat`, `priority:p1`
**Effort:** M

Grid of album cards in `ScrollViewer > ItemsRepeater` with `UniformGridLayout { MinItemWidth=180, MinItemHeight=240, MinRowSpacing=16, MinColumnSpacing=16 }`. ItemsRepeater virtualizes — critical for libraries with 10k+ albums. Incremental loading: paginate at 500 items, load next page when `ScrollViewer.VerticalOffset` crosses 80% threshold.

Top bar: `CommandBar` with sort (`AppBarButton` + `MenuFlyout`: Title, Artist, Year, Date Added, Random), filter (Genre picker via `ContentDialog`), view mode (Grid / List toggle).

Acceptance: 5000-album test library renders in < 500ms, scrolling stays at 60fps, memory stays under 300MB.

### Issue 14: Album Detail + Artist + Playlist screens
**Labels:** `area:windows`, `kind:feat`, `priority:p1`
**Effort:** L

**Album**: header with large art + metadata + `Play`/`Shuffle`/`Add to Queue` buttons → `ListView` of tracks with track number, title, duration, right-aligned `MenuFlyout` trigger. Click row → `IPlayerService.PlayAlbum(album, startIndex)`.

**Artist**: bio + top tracks (like a Spotify artist page) + albums grid + appearances/compilations. Uses `Pivot` or segmented control.

**Playlist**: similar to Album but reorderable rows (ListView with `CanReorderItems=true`, `AllowDrop=true`). Save order via core mutation.

Acceptance: Navigate from Home → Album → Artist → Artist's album — back stack restores correctly.

### Issue 15: Search with AutoSuggestBox
**Labels:** `area:windows`, `kind:feat`, `priority:p1`
**Effort:** M

`AutoSuggestBox` in the shell's title bar region. `TextChanged` debounced to 250ms, queries core `search(q)` → returns grouped suggestions (Artists / Albums / Tracks / Playlists). `ItemTemplateSelector` for per-type row rendering with icons. `SuggestionChosen` navigates directly; `QuerySubmitted` (Enter key) navigates to a full Search Results page.

Acceptance: Typing "a" returns results within ~300ms on a 10k-item library; arrow keys + Enter work; Escape clears.

---

## W-M3: Polish parity with macOS M3

### Issue 16: Now-Playing bar + queue flyout
**Labels:** `area:windows`, `kind:feat`, `priority:p1`
**Effort:** L

Persistent bottom bar: art thumbnail, title/artist, transport controls (Prev/Play/Pause/Next), seek bar (`ProgressBar` with drag), volume (`Slider` in a `FlyoutBase`), shuffle/repeat toggles, queue button. Queue button opens a `CommandBarFlyout` containing the upcoming tracks with drag-reorder and per-row MenuFlyout (Play Next, Remove).

State bindings: `IPlayerService.PositionChanged` at 4Hz. Scrub via `ThumbToolTipValueConverter` showing timestamp.

Acceptance: Seek mid-track, change volume, reorder queue — all reflect in SMTC immediately.

### Issue 17: App notifications — track changed, download ready, errors
**Labels:** `area:windows`, `kind:feat`, `priority:p2`
**Effort:** S

Use `Microsoft.Windows.AppNotifications.AppNotificationManager` (WinAppSDK native — replaces legacy `Microsoft.Toolkit.Uwp.Notifications` for packaged apps post-1.2). Build content with `AppNotificationBuilder`: toast on track change (if app is backgrounded and user has opted in), on download-complete, on playback errors. Register the notification activation handler in `App.OnLaunched` so clicking a toast brings the app forward and navigates to the relevant item.

Acceptance: Minimize app → track changes → toast appears with art + title; clicking raises window.

### Issue 18: Jump List — recent albums + quick actions
**Labels:** `area:windows`, `kind:feat`, `priority:p2`
**Effort:** S

`Windows.UI.StartScreen.JumpList.LoadCurrentAsync()`. Custom category "Recent" populated from the last 10 albums played (read from core `playback_history`). Task group with fixed actions: "Play Last Played", "Open Library". Activation args (e.g., `--jumplist=play-last`) parsed in `App.OnLaunched`.

Acceptance: Right-click taskbar icon → jump list shows recent albums; clicking one starts playback.

### Issue 19: Credential storage via Windows Credential Manager
**Labels:** `area:windows`, `kind:feat`, `priority:p0`
**Effort:** S

The Rust `keyring` crate already has a Windows backend (Generic credentials via `windows_native_keyring_store`). Core already stores tokens there — verify that the Windows DLL links the `wincred` feature (no feature flag needed, it's the default on `windows-msvc`). Expose `saveToken`/`loadToken` via UniFFI, call from the C# `AuthService`. Target name convention: `Jellify/<server_url>`.

Acceptance: Log in, restart app, auto-login works; "Forget server" deletes the credential.

### Issue 20: Keyboard shortcuts + no-menu-bar command surface
**Labels:** `area:windows`, `kind:feat`, `priority:p1`
**Effort:** M

WinUI 3 has no native menu bar — instead, use `KeyboardAccelerator` globally (on the root `ShellPage`). Shortcuts to match macOS: `Space` play/pause, `Ctrl+Right/Left` next/prev, `Ctrl+Shift+Right/Left` seek ±10s, `Ctrl+Up/Down` volume, `Ctrl+F` search, `Ctrl+,` settings, `Ctrl+W` close window, `Ctrl+R` refresh. Use `KeyboardAcceleratorPlacementMode=Hidden` on hotkeys that should work but not render in tooltips. Also register via `KeyboardAccelerator.ScopeOwner` so shortcuts work regardless of focused element.

Acceptance: Each shortcut works from every screen; none collide with `TextBox` input.

### Issue 21: Context menus — right-click on tracks/albums/artists
**Labels:** `area:windows`, `kind:feat`, `priority:p1`
**Effort:** M

`MenuFlyout` attached via `ContextFlyout` on list rows. Mirror macOS: Play, Play Next, Add to Queue, Add to Playlist → (sub `MenuFlyoutSubItem`), Go to Artist, Go to Album, Share, Favorite/Unfavorite. Prefer `CommandBarFlyout` for secondary commands (Microsoft's own guidance) but use plain `MenuFlyout` where only text items are needed.

Acceptance: Right-click every row type in Library/Album/Search — menu matches macOS parity.

### Issue 22: Drag & drop for queue reorder
**Labels:** `area:windows`, `kind:feat`, `priority:p1`
**Effort:** S

ListView with `CanReorderItems="True"` `CanDragItems="True"` `AllowDrop="True"` in the queue flyout and on the Playlist detail screen. Hook `DragItemsCompleted` to persist the new order via `IQueueStore.Reorder(fromIndex, toIndex)`.

Acceptance: Drag to reorder, playback continues seamlessly from the new position; order survives restart.

### Issue 23: Accessibility — Narrator, high contrast, focus visuals
**Labels:** `area:windows`, `kind:feat`, `priority:p1`
**Effort:** M

Set `AutomationProperties.Name`, `AutomationProperties.HelpText`, `AutomationProperties.LocalizedLandmarkType="Navigation"` on the sidebar / player bar / content frame. Verify the `HighContrast` theme dictionary overrides all brand colors to `{ThemeResource SystemColorWindowColor}` etc. Tab order: `TabIndex` on interactive elements, `TabFocusNavigation="Local"` to trap inside modal flyouts.

Test with Narrator on (Win+Ctrl+Enter): it should announce "Play, button, press Space to activate".

Acceptance: Narrator walkthrough of login → play flow reads correctly; High Contrast Black theme renders all UI legibly.

---

## W-M4: Distribution — MSIX + auto-update

### Issue 24: Fonts, icons, splash
**Labels:** `area:windows`, `kind:chore`, `priority:p1`
**Effort:** S

**Fonts**: bundle Figtree `.ttf` files under `src/Jellify.App/Assets/Fonts/`. Register via `<FontFamily>ms-appx:///Assets/Fonts/Figtree-Regular.ttf#Figtree</FontFamily>` in a merged resource dictionary.

**Icons**: source from `design/` SVG → export via `makepri` / Image Tool to all required sizes:
- `Square44x44Logo` (scales 100/125/150/200/400)
- `Square150x150Logo`, `Square71x71Logo`, `Square310x310Logo`, `Wide310x150Logo`
- `StoreLogo`, `SplashScreen` (620x300)
Place in `Assets/`, reference from `Package.appxmanifest`.

Acceptance: Start menu tile shows Jellify icon at all scales; splash shows brand purple bg + logo.

### Issue 25: Single-project MSIX packaging
**Labels:** `area:windows`, `kind:chore`, `priority:p0`
**Effort:** M

Enable single-project MSIX in `Jellify.App.csproj`: `<WindowsPackageType>MSIX</WindowsPackageType>`, `<EnableMsixTooling>true</EnableMsixTooling>`. Fill in `Package.appxmanifest`: Publisher (matches cert subject), Identity Name (`Jellify.Desktop`), Display Name, Description, Logo paths, Capabilities (`internetClient`, `backgroundMediaPlayback`).

Build both packaged (`.msix`) and unpackaged (`dotnet publish -p:WindowsPackageType=None -p:WindowsAppSDKSelfContained=true`) variants. Unpackaged produces a portable `.exe` folder we can zip for non-Store distribution.

Acceptance: `dotnet publish` produces both a signed `.msix` and a self-contained `.exe` folder; both launch and play audio.

### Issue 26: Signing — dev SelfCert + prod Azure Trusted Signing
**Labels:** `area:windows`, `kind:chore`, `priority:p0`
**Effort:** M

**Dev**: Generate a self-signed cert via `New-SelfSignedCertificate -Subject "CN=Jellify Dev, O=Jellify" -Type CodeSigningCert -CertStoreLocation cert:\CurrentUser\My`. Export `.pfx`. Document install into `Trusted Root` + `Trusted People` so packages are double-click-installable during dev.

**Prod**: Use Azure Trusted Signing (Microsoft's modern replacement for EV certs). Configure `SignTool.exe` with `/dlib Azure.CodeSigning.Dlib.dll` + metadata JSON pointing at the Azure Trusted Signing account. Timestamps **must** be applied (`/td sha256 /tr http://timestamp.acs.microsoft.com`) or the signature expires with the cert.

Acceptance: Signed MSIX installs on a clean Win11 VM without SmartScreen warning (once publisher reputation builds via Trusted Signing); unsigned dev package installs on dev box via imported cert.

### Issue 27: Auto-update via Velopack for non-Store channel
**Labels:** `area:windows`, `kind:feat`, `priority:p1`
**Effort:** L

For Store-distributed users, the Store handles updates. For direct-download `.exe` users (primary channel for a FOSS app), use Velopack (successor to Squirrel.Windows, Rust-based, ~2s updates, delta packages). Add the `Velopack` NuGet, wrap in `UpdateService`:
```
var mgr = new UpdateManager("https://updates.jellify.org/win");
var newVer = await mgr.CheckForUpdatesAsync();
if (newVer != null) { await mgr.DownloadUpdatesAsync(newVer); mgr.ApplyUpdatesAndRestart(); }
```
Host update feed on GitHub Releases (Velopack native support) or S3. Sign Velopack packages with the same cert (Issue 26).

In-app UX: settings panel "Check for updates" button, optional background-check at launch, "Install and restart" affordance.

Acceptance: Release v0.1.1 → dev build on v0.1.0 detects, downloads delta, installs, and restarts into v0.1.1 within ~5s.

### Issue 28: CI — GitHub Actions on `windows-latest`
**Labels:** `area:windows`, `kind:chore`, `priority:p0`
**Effort:** M

Workflow `.github/workflows/windows.yml`:
1. Cache cargo (`~/.cargo/registry`, `target/`) keyed on `Cargo.lock`.
2. `rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc`.
3. `cargo binstall uniffi-bindgen-cs --version 0.10.0`.
4. Run `windows/tools/build-core.ps1` → `jellify_core.dll` for both RIDs.
5. Run `windows/tools/gen-bindings.ps1` → verify no drift (fail if git-diff dirty).
6. `dotnet test windows/Jellify.sln`.
7. `dotnet publish -c Release -r win-x64 -p:WindowsPackageType=MSIX`.
8. Sign with cert stored in `secrets.WIN_SIGN_CERT_PFX_BASE64` (decoded to disk, SignTool against it, then `shred`). Pin: import cert to current user store, sign, remove.
9. Upload MSIX + unpackaged zip as artifacts; on tagged release, push to GitHub Releases + Velopack feed.

Acceptance: Every PR runs build + test + lint (dotnet-format check) in under 10 minutes; tag push produces signed release artifacts automatically.

### Issue 29: Manual QA playbook + limited UI snapshot tests
**Labels:** `area:windows`, `kind:chore`, `priority:p2`
**Effort:** S

WinUI 3 UI automation is rough (no first-class Appium driver as of 2026). Approach:
1. **Manual**: checklist in `windows/docs/QA.md` covering login, play, pause, seek, next/prev, queue reorder, search, theme switch, high contrast, offline boot. Run before each release on Win10 22H2, Win11 23H2, Win11 on ARM (via Parallels on Apple Silicon).
2. **Snapshot**: `AppUI.Testing` (or `FlaUI.UIA3`) for smoke-level — launch app, assert main window title, click login page elements. One test per screen to catch XAML-parse regressions.

Acceptance: `dotnet test` runs the snapshot suite in CI against a headless Win session; QA.md checklist committed.

### Issue 30: First-launch story — SmartScreen + localization stub + telemetry opt-in
**Labels:** `area:windows`, `kind:feat`, `priority:p2`
**Effort:** S

**SmartScreen**: unsigned `.exe` downloads hit SmartScreen's "unrecognized app" warning. With Azure Trusted Signing (Issue 26) this clears once publisher reputation builds (~few thousand installs). Document in README the "More info → Run anyway" flow for early adopters.

**Localization**: scaffold `.resw` under `Strings/en-us/Resources.resw`. Use `x:Uid="Login_ServerLabel"` on all user-facing strings. Don't ship translations yet — just build the scaffold so community can PR translations later. Avoid hard-coding any UI string in `.xaml.cs`.

**Telemetry opt-in**: first-launch `ContentDialog` asking about crash reporting (Sentry). Default: off. Matches macOS behavior.

Acceptance: First launch shows welcome dialog; strings resolve from `.resw`; `SetLanguageOverride("ja-JP")` in a test swaps at least one string.

---

**Total: 30 issues.** W-M1 lays the foundation (Rust core callable from C#), W-M2 delivers login-to-play, W-M3 reaches macOS-M3 feature parity, W-M4 ships publicly on both MSIX and portable channels with auto-update.
