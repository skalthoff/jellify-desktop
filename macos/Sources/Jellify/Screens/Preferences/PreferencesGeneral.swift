import SwiftUI

/// General preferences pane.
///
/// Launch-at-login, menu-bar presence, and language. These are the knobs that
/// don't fit under a more specific pane but still belong in the p0 shipping
/// set. All three are UI-only today:
///
/// - **Language**: only English ships; the picker is present so the setting
///   is visible and the user can see i18n is on the roadmap. Real wiring is
///   tracked in `TODO(i18n-#345)`.
/// - **Auto-start on login**: persists the selection; real `SMAppService`
///   registration lands alongside the rest of the launch-item scaffolding
///   (see TODO below). A naive toggle is still useful to surface the feature
///   so users can opt-in and the choice is remembered across a restart.
/// - **Show in menu bar**: persists today; the actual `NSStatusItem` mount
///   belongs with the mini-player / menu-bar companion work.
///
/// Spec: `research/03-ux-patterns.md` Issue 66 top-level General bullet.
struct PreferencesGeneral: View {
    @AppStorage("general.language") private var languageRaw: String = AppLanguage.system.rawValue
    @AppStorage("general.autoStartOnLogin") private var autoStartOnLogin: Bool = false
    @AppStorage("general.showInMenuBar") private var showInMenuBar: Bool = false

    private var language: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: languageRaw) ?? .system },
            set: { languageRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            PreferenceSection(
                title: "Language",
                footnote: "Only English ships today. The picker is here so you can see the setting exists — additional languages will appear as translations land. TODO(i18n-#345)."
            ) {
                PreferenceRow(
                    label: "Language",
                    help: language.wrappedValue.subtitle
                ) {
                    Picker("", selection: language) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
                    .accessibilityLabel("Application language")
                }
            }

            PreferenceSection(
                title: "Startup",
                footnote: "Auto-start launches Jellify in the background when you log in. The toggle persists today; TODO(#566) registers the login-item through SMAppService so the behaviour actually fires."
            ) {
                PreferenceRow(
                    label: "Open at login",
                    help: autoStartOnLogin
                        ? "On — Jellify will launch in the background when you sign in."
                        : "Off — Jellify only opens when you launch it manually."
                ) {
                    Toggle("", isOn: $autoStartOnLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Launch Jellify at login")
                }
            }

            PreferenceSection(
                title: "Menu Bar",
                footnote: "Keeps a transport icon in the macOS menu bar for quick play/pause, skip, and now-playing access. TODO(#567) — NSStatusItem mount lands with the mini-player work."
            ) {
                PreferenceRow(
                    label: "Show in menu bar",
                    help: showInMenuBar
                        ? "On — a compact transport icon stays in the menu bar."
                        : "Off — Jellify lives only in the Dock."
                ) {
                    Toggle("", isOn: $showInMenuBar)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Show in menu bar")
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("General")
                .font(Theme.font(28, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            Text("Language, startup, and menu-bar presence.")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }
}

/// Application language for the UI. Only `system` (effectively English today)
/// and `english` are present in the v1 cut — additional cases land alongside
/// the strings catalog in `TODO(i18n-#345)`. Raw values are stable user-
/// defaults strings so on-disk preferences survive future additions.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "Follow macOS language settings."
        case .english: return "Use English regardless of system language."
        }
    }
}

#Preview {
    PreferencesGeneral()
        .frame(width: 560, height: 520)
        .padding(32)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
