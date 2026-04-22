import SwiftUI

/// Top-level Preferences window. Presented via the `Settings { ... }` scene in
/// `JellifyApp` so macOS handles the ⌘, shortcut and standard window behavior
/// automatically. For the shell (issue #258) each pane renders a placeholder —
/// real settings land in follow-up issues (#259 Account, #260 General,
/// #261/#262 Playback, #263 Appearance, #264 Library, #265 Downloads,
/// #266 Keyboard, #267 Advanced).
struct PreferencesView: View {
    enum Pane: String, CaseIterable, Hashable, Identifiable {
        case account, general, playback, appearance, library, downloads, keyboard, advanced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .account: return "Account"
            case .general: return "General"
            case .playback: return "Playback"
            case .appearance: return "Appearance"
            case .library: return "Library"
            case .downloads: return "Downloads"
            case .keyboard: return "Keyboard"
            case .advanced: return "Advanced"
            }
        }

        var icon: String {
            switch self {
            case .account: return "person.circle"
            case .general: return "gearshape"
            case .playback: return "play.circle"
            case .appearance: return "paintpalette"
            case .library: return "music.note.list"
            case .downloads: return "arrow.down.circle"
            case .keyboard: return "keyboard"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }

    @State private var selection: Pane = .account

    var body: some View {
        HStack(spacing: 0) {
            PreferencesNav(selection: $selection)
                .frame(width: 180)

            Divider()
                .background(Theme.border)

            ScrollView {
                pane(for: selection)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
        }
        .frame(width: 780, height: 520)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func pane(for selection: Pane) -> some View {
        switch selection {
        case .account: AccountPane()
        case .general: GeneralPane()
        case .playback: PlaybackPane()
        case .appearance: AppearancePane()
        case .library: LibraryPane()
        case .downloads: DownloadsPane()
        case .keyboard: KeyboardPane()
        case .advanced: AdvancedPane()
        }
    }
}

// MARK: - Left navigation

private struct PreferencesNav: View {
    @Binding var selection: PreferencesView.Pane

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header

            ForEach(PreferencesView.Pane.allCases) { pane in
                navRow(pane)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity)
        .background(Theme.bgAlt)
    }

    private var header: some View {
        Text("Preferences".uppercased())
            .font(Theme.font(10, weight: .bold))
            .foregroundStyle(Theme.ink3)
            .tracking(1.5)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func navRow(_ pane: PreferencesView.Pane) -> some View {
        let active = selection == pane
        Button { selection = pane } label: {
            HStack(spacing: 10) {
                Image(systemName: pane.icon)
                    .foregroundStyle(active ? Theme.accent : Theme.ink2)
                    .frame(width: 18)
                Text(pane.title)
                    .font(Theme.font(13, weight: active ? .bold : .semibold))
                    .foregroundStyle(active ? Theme.ink : Theme.ink2)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Theme.surface2 : .clear)
            )
            .overlay(alignment: .leading) {
                if active {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                        .padding(.vertical, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

// MARK: - Placeholder panes
// Each pane is a thin shell; real content lands in follow-up issues.

private struct PlaceholderPane: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text(subtitle)
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
            Text("Coming soon…")
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .padding(.top, 24)
        }
    }
}

private struct AccountPane: View {
    var body: some View {
        PlaceholderPane(
            title: "Account",
            subtitle: "Server, user, and sign-in state."
        )
    }
}

private struct GeneralPane: View {
    var body: some View {
        PlaceholderPane(
            title: "General",
            subtitle: "Launch-at-login, menubar, and default window behavior."
        )
    }
}

private struct PlaybackPane: View {
    var body: some View {
        PlaceholderPane(
            title: "Playback",
            subtitle: "Streaming and download quality, crossfade, gapless, normalization."
        )
    }
}

private struct AppearancePane: View {
    var body: some View {
        PlaceholderPane(
            title: "Appearance",
            subtitle: "Theme, mode, density, and sidebar visibility."
        )
    }
}

private struct LibraryPane: View {
    var body: some View {
        PlaceholderPane(
            title: "Library",
            subtitle: "Refresh, resync, and local cache."
        )
    }
}

private struct DownloadsPane: View {
    var body: some View {
        PlaceholderPane(
            title: "Downloads",
            subtitle: "Offline storage location, quality, and limits."
        )
    }
}

private struct KeyboardPane: View {
    var body: some View {
        PlaceholderPane(
            title: "Keyboard",
            subtitle: "Shortcut editor for transport and navigation commands."
        )
    }
}

private struct AdvancedPane: View {
    var body: some View {
        PlaceholderPane(
            title: "Advanced",
            subtitle: "Logs, developer options, and experimental features."
        )
    }
}

#Preview {
    PreferencesView()
}
