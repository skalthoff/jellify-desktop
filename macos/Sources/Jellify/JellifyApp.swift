import SwiftUI

@main
struct JellifyApp: App {
    @State private var model: AppModel

    init() {
        FontRegistration.register()
        do {
            _model = State(wrappedValue: try AppModel())
        } catch {
            fatalError("Failed to initialize Jellify core: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup("Jellify") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(.dark)
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

            // TODO(#305): Replace with a dedicated command palette once the
            // palette UI lands. For now ⌘K mirrors ⌘F.
            Button("Command Palette") {
                model.focusSearch()
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

    var body: some View {
        Group {
            if model.session == nil {
                LoginView()
            } else {
                MainShell()
            }
        }
        .background(Theme.bg)
        // Login <-> main shell swap is instant under Reduce Motion.
        .animation(reduceMotion ? nil : .default, value: model.session != nil)
    }
}
