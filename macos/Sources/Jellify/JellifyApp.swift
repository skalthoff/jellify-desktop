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

        // Native Preferences scene. macOS wires up ⌘, and menu item for free.
        Settings {
            PreferencesView()
                .environment(model)
        }
        .windowResizability(.contentSize)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.session == nil {
                LoginView()
            } else {
                MainShell()
            }
        }
        .background(Theme.bg)
    }
}
