# Jellify — Windows

WinUI 3 + Windows App SDK 1.8 client for Jellyfin. Wraps the shared Rust
core (`core/`) via UniFFI-generated C# bindings; transport playback uses
`Windows.Media.Playback.MediaPlayer` and surfaces SMTC for the system
overlay.

This directory is the M-W1 bootstrap. The shell launches to an empty
content frame with a left-pane `NavigationView`; concrete pages and the
Rust-backed services land in subsequent batches.

## Layout

```
windows/
  Jellify.sln
  Directory.Build.props      # WinAppSDK / Toolkit floor (one place to bump)
  uniffi.toml                # bindgen config consumed by tools/gen-bindings.ps1
  Jellify.App/               # WinUI 3 packaged app — XAML, VMs, navigation
    App.xaml(.cs)            # Composition root — HostApplicationBuilder + DI
    MainWindow.xaml(.cs)
    Pages/
      ShellPage.xaml(.cs)    # NavigationView (left pane) + Frame (content)
    Services/
      INavigationService.cs
      NavigationService.cs
    ViewModels/
      LoginViewModel.cs
      HomeViewModel.cs
      LibraryViewModel.cs
    Package.appxmanifest     # MSIX manifest (Win10 1809+ device family)
    app.manifest             # PerMonitorV2 DPI, UTF-8 ACP, OS compat
  Jellify.Core/              # Wraps generated UniFFI bindings + native DLL
    IJellyfinClient.cs       # Hand-written facade over the Rust core (shape)
    IQueueStore.cs
    IPlaybackStateStore.cs
    Generated/               # uniffi-bindgen-cs output (gitignored)
    native/
      win-x64/jellify_core.dll      # produced by tools/build-core.ps1
      win-arm64/jellify_core.dll
  tools/
    build-core.ps1           # cargo build --target … for x64 + arm64
    gen-bindings.ps1         # uniffi-bindgen-cs --library …
```

## Build prerequisites

- **Windows 11** (Windows 10 1809 / build 17763 is the runtime floor; 11
  is recommended for dev, since some tooling — Mica fallback, SMTC art
  cache — only behaves correctly there).
- **Visual Studio 2022 17.8 or newer**, with the **WinUI application
  development** workload (under .NET desktop). The Universal Windows
  Platform development workload is not required when targeting the
  packaged-app single-project template, but install it if you want the
  legacy `.wapproj` packaging fallback.
- **Windows 11 SDK 10.0.22621** or newer. Listed under "Individual
  components" in the VS installer.
- **PowerShell 7+** (`pwsh`). Required by the helper scripts under
  `tools/`. Windows PowerShell 5.1 is missing several cmdlets they rely
  on.
- **Rust 1.88 or newer** with both MSVC targets installed:

  ```pwsh
  rustup target add x86_64-pc-windows-msvc
  rustup target add aarch64-pc-windows-msvc
  ```

  1.88 is the floor required by `uniffi-bindgen-cs` v0.10 (which tracks
  upstream `uniffi 0.29.x`). The workspace's MSRV is 1.75 for the core
  itself; the bindgen tool is the binding constraint on Windows.

- **uniffi-bindgen-cs**:

  ```pwsh
  cargo install uniffi-bindgen-cs `
    --git https://github.com/NordSecurity/uniffi-bindgen-cs `
    --tag v0.10.0+v0.29.4
  ```

  The `+v0.29.4` tag suffix is the upstream UniFFI version this bindgen
  tracks. It must match the `uniffi` version pinned in the workspace
  `Cargo.toml`. When bumping `uniffi`, rev this tag in lockstep.

## Build loop

```pwsh
# 1. Build the Rust core for both Windows targets.
pwsh windows/tools/build-core.ps1

# 2. Generate C# bindings from the freshly built DLL. Skip on rebuilds
#    that don't touch the Rust API surface — the Generated/ output is
#    committed.
pwsh windows/tools/gen-bindings.ps1

# 3. Build + run the app.
dotnet build windows/Jellify.sln -c Debug -p:Platform=x64
dotnet run --project windows/Jellify.App -c Debug
```

Skipping arm64 during local iteration is fine:

```pwsh
pwsh windows/tools/build-core.ps1 -SkipArm64
```

## CI verification

The acceptance build runs on `windows-latest`:

1. `cargo build --workspace --target x86_64-pc-windows-msvc -p jellify_core --release`
2. `pwsh windows/tools/gen-bindings.ps1 -Configuration Release`
3. `dotnet build windows/Jellify.sln -c Release -p:Platform=x64`

The shell-launches smoke test (CI is headless so this is a process-spawn
check, not a UI assertion) lives in a follow-up issue.

## What this batch ships

- Solution + project skeleton compiles on a Win11 + VS 2022 box once
  the Rust DLL has been staged.
- `App.xaml.cs` builds a `HostApplicationBuilder`, registers the
  `IJellyfinClient` / `IQueueStore` / `IPlaybackStateStore` / VM
  contracts, and sets `App.Services` so VMs can resolve dependencies
  outside the XAML activation path.
- `ShellPage` renders an empty `NavigationView` with Home / Library /
  Search items + a content `Frame`. Clicking an item is wired to
  `INavigationService.NavigateTo<TViewModel>()`; concrete child pages
  land in later batches.
- `tools/build-core.ps1` and `tools/gen-bindings.ps1` produce the native
  DLL + C# bindings end-to-end.

Concrete page implementations, transport service, SMTC bridge, and
`MediaPlayer` integration land in the W-M2 batch (see ROADMAP).
