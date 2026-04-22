import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            // Brand
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Theme.teal, Theme.primary], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                    // Emoji rendered verbatim — a jellyfish is a jellyfish in
                    // every locale; no catalog entry needed.
                    .overlay(Text(verbatim: "🪼").font(.system(size: 16)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("app.name")
                        .font(Theme.font(15, weight: .black, italic: true))
                        .foregroundStyle(Theme.ink)
                    Text("app.subtitle.desktop")
                        .font(Theme.font(9, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                        .tracking(1.5)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Primary nav
            VStack(alignment: .leading, spacing: 2) {
                navItem("house", label: "sidebar.nav.home", screen: .home)
                navItem("music.note.list", label: "sidebar.nav.library", screen: .library)
                navItem("magnifyingglass", label: "sidebar.nav.search", screen: .search)
            }
            .padding(.horizontal, 10)

            // Stats footer
            sectionHeader("sidebar.section.your_library")
            VStack(alignment: .leading, spacing: 2) {
                libRow("heart", label: "sidebar.stats.favorites", count: nil)
                libRow("square.stack", label: "sidebar.stats.albums", count: UInt32(model.albums.count))
                libRow("person.crop.circle", label: "sidebar.stats.artists", count: UInt32(model.artists.count))
                libRow("music.note.list", label: "sidebar.stats.playlists", count: UInt32(model.playlists.count))
            }
            .padding(.horizontal, 10)

            Spacer()

            // Server footer
            HStack(spacing: 10) {
                Circle().fill(Theme.teal).frame(width: 8, height: 8)
                    .shadow(color: Theme.teal.opacity(0.7), radius: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.session?.server.name ?? "—")
                        .font(Theme.font(11, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text("Connected · \(model.albums.count) albums")
                        .font(Theme.font(10, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }
                Spacer()
                Button { model.logout() } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(Theme.ink3)
                }
                .buttonStyle(.plain)
                .help("Sign out")
                .accessibilityLabel("Sign out")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Divider().background(Theme.border), alignment: .top)
        }
        .frame(width: 252)
        // Translucent Apple-Music-style sidebar material. The `.sidebar`
        // material + `.behindWindow` blending lets the desktop wallpaper
        // tint through while preserving the brand backdrop on top. See
        // issues #9 / #10 / #28.
        .background(
            VisualEffectView(material: .sidebar)
                .overlay(Theme.bgAlt.opacity(0.55))
        )
    }

    @ViewBuilder
    private func navItem(_ icon: String, label: LocalizedStringKey, screen: AppModel.Screen) -> some View {
        let active = model.screen == screen
        Button { model.screen = screen } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(active ? Theme.accent : Theme.ink2)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(label)
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
        // VoiceOver announces a simple "Home" / "Library" / "Search" and,
        // for the currently selected tab, adds the "selected" trait so the
        // user hears which one they're on without parsing visual chrome.
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func libRow(_ icon: String, label: LocalizedStringKey, count: UInt32?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Theme.ink2)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(label)
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.ink2)
            Spacer()
            if let c = count {
                Text("\(c)")
                    .font(Theme.font(10, weight: .bold))
                    .foregroundStyle(Theme.ink3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Combine icon + label + count into one VoiceOver utterance so the
        // row reads as "Albums, 42" rather than three separate fragments.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count.map { "\(label), \($0)" } ?? label)
    }

    @ViewBuilder
    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        // The header reads as uppercase in the rendered frame via the heavy
        // tracking + smallcap feel; we no longer force `.uppercased()` here
        // because doing so would mangle non-Latin scripts (Arabic, CJK)
        // that have no case distinction. The catalog entries already ship
        // the English label in uppercase.
        Text(title)
            .font(Theme.font(10, weight: .bold))
            .foregroundStyle(Theme.ink3)
            .tracking(1.5)
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }
}
