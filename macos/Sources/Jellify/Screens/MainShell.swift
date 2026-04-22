import SwiftUI

struct MainShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Sidebar()
                Divider().background(Theme.border)
                contentColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PlayerBar()
        }
        .background(Theme.bg)
    }

    @ViewBuilder
    private var contentColumn: some View {
        VStack(spacing: 0) {
            topBar
            if !model.network.isOnline {
                OfflineBanner(onRetry: { model.retryNetwork() })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Screen swaps should be instant when Reduce Motion is on.
                // Otherwise, keep SwiftUI's default implicit behavior.
                .animation(reduceMotion ? nil : .default, value: model.screen)
        }
        .animation(.easeInOut(duration: 0.2), value: model.network.isOnline)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch model.screen {
        case .home, .library:
            LibraryView()
        case .search:
            SearchView()
        case .album(let id):
            AlbumDetailView(albumID: id)
        default:
            LibraryView()
        }
    }

    @ViewBuilder
    private var topBar: some View {
        HStack {
            Breadcrumbs(segments: breadcrumbSegments) { idx in
                navigate(toBreadcrumbDepth: idx)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 12)
        .background(Theme.bgAlt.opacity(0.4))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    /// Builds the breadcrumb trail for the current screen. The root segment is
    /// always "Jellify"; subsequent segments describe where in the app the
    /// user has navigated.
    private var breadcrumbSegments: [String] {
        var segments: [String] = ["Jellify"]
        switch model.screen {
        case .home:
            segments.append("Home")
        case .library:
            segments.append("Library")
        case .search:
            segments.append("Search")
        case .album(let id):
            segments.append("Library")
            segments.append("Albums")
            if let album = model.albums.first(where: { $0.id == id }) {
                segments.append(album.name)
            } else {
                segments.append("Album")
            }
        case .artist(let id):
            segments.append("Library")
            segments.append("Artists")
            if let artist = model.artists.first(where: { $0.id == id }) {
                segments.append(artist.name)
            } else {
                segments.append("Artist")
            }
        case .playlist:
            segments.append("Playlists")
        case .settings:
            segments.append("Settings")
        }
        return segments
    }

    /// Handles a tap on a breadcrumb segment at `idx`. The root ("Jellify")
    /// and the common "Library" parent both return the user to the library.
    private func navigate(toBreadcrumbDepth idx: Int) {
        let segment = breadcrumbSegments[safe: idx] ?? ""
        switch segment {
        case "Jellify", "Library", "Albums", "Artists":
            model.screen = .library
        case "Home":
            model.screen = .home
        case "Search":
            model.screen = .search
        case "Settings":
            model.screen = .settings
        default:
            // Final/unknown segments are non-navigable; do nothing.
            break
        }
    }
}
