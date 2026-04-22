import SwiftUI

@main
struct JellifyApp: App {
    @State private var model: AppModel

    /// Persisted color-scheme mode from the Appearance pane (#263). Read here
    /// so the entire window tree (including the Preferences scene) honours the
    /// user's choice. `oled` resolves to `.dark` until the true-black surface
    /// wash lands alongside the theme engine in #405.
    @AppStorage(AppearanceKeys.mode) private var modeRaw: String = AppearanceMode.dark.rawValue

    init() {
        FontRegistration.register()
        do {
            _model = State(wrappedValue: try AppModel())
        } catch {
            fatalError("Failed to initialize Jellify core: \(error)")
        }
    }

    private var preferredColorScheme: ColorScheme? {
        (AppearanceMode(rawValue: modeRaw) ?? .dark).preferredColorScheme
    }

    var body: some Scene {
        WindowGroup("Jellify") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(preferredColorScheme)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            JellifyCommands(model: model)
        }

        // Native Preferences scene. macOS wires up ⌘, and menu item for free.
        Settings {
            PreferencesView()
                .environment(model)
                .preferredColorScheme(preferredColorScheme)
        }
        .windowResizability(.contentSize)
    }
}

/// Global keyboard shortcuts. See issue #321 for the full matrix.
///
/// Transport commands live under a dedicated "Playback" menu; navigation
/// sits alongside the standard View group via `.sidebar` placement. Each
/// Button disables itself when the underlying action is not meaningful
/// (e.g., skipping next while no track is loaded).
struct JellifyCommands: Commands {
    @Bindable var model: AppModel

    var body: some Commands {
        // MARK: Playback (Space, prev/next, volume, mini player)
        CommandMenu("Playback") {
            Button(playPauseLabel) {
                model.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.status.currentTrack == nil)

            Divider()

            Button("Previous Track") {
                model.skipPrevious()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(model.status.currentTrack == nil)

            Button("Next Track") {
                model.skipNext()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(model.status.currentTrack == nil)

            Divider()

            Button("Volume Up") {
                let next = min(1.0, model.status.volume + 0.05)
                model.setVolume(next)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button("Volume Down") {
                let next = max(0.0, model.status.volume - 0.05)
                model.setVolume(next)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            // Full Now Playing view — #89. Swaps the detail column to the
            // large player + lyrics/queue/about/credits tabs. When already
            // on Now Playing, the shortcut pops back to the previous
            // screen so pressing it again feels like a toggle.
            Button("Show Now Playing") {
                if model.screen == .nowPlaying {
                    model.screen = model.previousScreen ?? .library
                    model.previousScreen = nil
                } else {
                    model.previousScreen = model.screen
                    model.screen = .nowPlaying
                }
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(model.session == nil)

            Divider()

            // TODO(#321): Wire to the mini-player scene once it exists.
            // Tracked separately in the macOS polish milestone.
            Button("Toggle Mini Player") {
                // No-op placeholder until the mini-player view is implemented.
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(true)
        }

        // MARK: View / navigation (⌘1–5, ⌘L, ⌘F, ⌘K)
        CommandGroup(after: .sidebar) {
            Divider()

            Button("Home") {
                model.screen = .home
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(model.session == nil)

            Button("Library") {
                model.screen = .library
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(model.session == nil)

            Button("Search") {
                model.screen = .search
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(model.session == nil)

            // ⌘4 / ⌘5 are reserved for additional top-level tabs. The
            // current sidebar only has three entries (Home, Library,
            // Search); expand this block when more nav targets land.

            Divider()

            // ⌘L is a convenience alias for the Library tab.
            Button("Go to Library") {
                model.screen = .library
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(model.session == nil)

            // ⌘F focuses search. Uses focusSearch() so the search TextField
            // actually receives keyboard focus — not just a screen switch.
            Button("Find…") {
                model.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model.session == nil)

            // Command Palette (#305). Full-screen ⌘K overlay with library
            // search + static action verbs. Toggling the flag here and
            // letting `RootView` mount the overlay keeps the palette
            // independent of whichever screen is currently focused.
            Button("Command Palette\u{2026}") {
                model.isCommandPaletteOpen.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(model.session == nil)
        }

        // Note: ⌘, (Preferences) is automatically provided by SwiftUI when a
        // `Settings` scene is declared. Settings UI for the macOS app is
        // tracked separately; leaving the system default in place so the
        // menu item shows up as soon as that scene is added.
    }

    private var playPauseLabel: String {
        model.status.state == .playing ? "Pause" : "Play"
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Sticky "first-launch is done" flag. On a fresh install this is
    /// `false` and the app lands on `OnboardingView`. After the user either
    /// completes the flow or taps "Skip, explore offline" it becomes
    /// `true` permanently so subsequent signed-out launches go straight
    /// to `LoginView`. See #291 / #292 / #293.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    var body: some View {
        Group {
            if model.isRestoringSession {
                // One-shot loading state on cold start while the core attempts
                // to rehydrate a session from persisted settings + keychain.
                // We don't want to briefly flash `LoginView` on every launch
                // just because the restore hasn't completed yet.
                RestoreLoadingView()
            } else if !hasCompletedOnboarding {
                // First launch. `OnboardingView` owns the flow across all
                // three steps; it flips `hasCompletedOnboarding` itself once
                // the user either lands in the sync step and hits Continue
                // to Home, or skips offline from the connect step. Keeping
                // `OnboardingView` mounted *even after* a successful login
                // matters: the first-sync step needs to stay on screen
                // while the library is fetching, which happens against a
                // live `model.session`.
                OnboardingView()
            } else if model.session == nil {
                LoginView()
            } else {
                MainShell()
            }
        }
        .background(Theme.bg)
        // Login <-> main shell swap (and restore-loading <-> either) is
        // instant under Reduce Motion.
        .animation(reduceMotion ? nil : .default, value: model.session != nil)
        .animation(reduceMotion ? nil : .default, value: model.isRestoringSession)
        .animation(reduceMotion ? nil : .default, value: hasCompletedOnboarding)
        // Command Palette (#305). Owned at the root so the overlay
        // floats above every screen — Home, Library, Now Playing, and
        // any modal sheet. The palette itself pulls `AppModel` out of
        // the environment to drive search + action dispatch.
        .overlay {
            if model.isCommandPaletteOpen && model.session != nil {
                CommandPalette()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.isCommandPaletteOpen)
        .task {
            // Kick off session restore exactly once, on the first appearance
            // of the root view. `attemptRestoreSession` guards against
            // re-entry, so a `.task` firing on every scene rebuild is safe.
            await model.attemptRestoreSession()
        }
    }
}

/// Minimal cold-start splash shown while the core rehydrates a persisted
/// session in the background. Kept lightweight on purpose — the restore pass
/// completes on a userInitiated Task and this view exists solely to avoid a
/// LoginView flash on every launch for a signed-in user.
private struct RestoreLoadingView: View {
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Jellify")
                    .font(Theme.font(40, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.ink3)
            }
        }
    }
}
