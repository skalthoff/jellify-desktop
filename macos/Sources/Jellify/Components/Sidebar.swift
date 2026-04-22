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
                    .overlay(Text("🪼").font(.system(size: 16)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Jellify")
                        .font(Theme.font(15, weight: .black, italic: true))
                        .foregroundStyle(Theme.ink)
                    Text("DESKTOP")
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
                navItem("house", label: "Home", screen: .home)
                navItem("music.note.list", label: "Library", screen: .library)
                navItem("magnifyingglass", label: "Search", screen: .search)
            }
            .padding(.horizontal, 10)

            // Stats footer
            sectionHeader("Your Library")
            VStack(alignment: .leading, spacing: 2) {
                libRow("heart", label: "Favorites", count: nil)
                libRow("square.stack", label: "Albums", count: UInt32(model.albums.count))
                libRow("person.crop.circle", label: "Artists", count: UInt32(model.artists.count))
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
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Divider().background(Theme.border), alignment: .top)
        }
        .frame(width: 252)
        .background(Theme.bgAlt)
    }

    @ViewBuilder
    private func navItem(_ icon: String, label: String, screen: AppModel.Screen) -> some View {
        let active = model.screen == screen
        Button { model.screen = screen } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(active ? Theme.accent : Theme.ink2)
                    .frame(width: 18)
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
    }

    @ViewBuilder
    private func libRow(_ icon: String, label: String, count: UInt32?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Theme.ink2)
                .frame(width: 18)
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
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.font(10, weight: .bold))
            .foregroundStyle(Theme.ink3)
            .tracking(1.5)
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }
}
