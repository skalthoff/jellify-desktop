import SwiftUI

struct MainShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
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
        // Auth-expired prompt — see #303. One-shot modal; on "Sign in" we
        // drop the stored token and clear the session so `RootView` routes
        // back to `LoginView`, which prefills the remembered server URL and
        // username so the user only needs to re-enter their password.
        .sheet(isPresented: $model.authExpired) {
            AuthExpiredSheet {
                model.forgetToken()
                model.session = nil
                model.authExpired = false
            }
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        VStack(spacing: 0) {
            topBar
            if !model.network.isOnline {
                OfflineBanner(onRetry: { model.retryNetwork() })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // Only surface the server-unreachable banner when the system is
            // actually online — otherwise the offline banner already explains
            // why requests are failing and stacking both would be noisy.
            if model.network.isOnline && !model.serverReachability.isServerReachable {
                ServerUnreachableBanner(onRetry: { model.retryServer() })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Screen swaps should be instant when Reduce Motion is on.
                // Otherwise, keep SwiftUI's default implicit behavior.
                .animation(reduceMotion ? nil : .default, value: model.screen)
        }
        .animation(.easeInOut(duration: 0.2), value: model.network.isOnline)
        .animation(.easeInOut(duration: 0.2), value: model.serverReachability.isServerReachable)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch model.screen {
        case .home:
            HomeView()
        case .library:
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
        case .playlist(_):
            segments.append("Playlists")
        case .settings:
            segments.append("Settings")
        }
        return segments
    }

    /// Handles a tap on a breadcrumb segment at `idx`. Navigation is driven by
    /// the current `model.screen` and the tapped index, so the component stays
    /// agnostic of label strings (no brittle title matching). Index 0 is the
    /// root ("Jellify") and always returns to the library. For nested screens
    /// (e.g. album/artist detail), intermediate indices pop to the library;
    /// the final index is the current location and is a no-op.
    private func navigate(toBreadcrumbDepth idx: Int) {
        // Index 0 is always the root and pops to library.
        guard idx > 0 else {
            model.screen = .library
            return
        }

        switch model.screen {
        case .home, .library, .search, .settings, .playlist:
            // Shape: ["Jellify", <current>] — only the final index, which is
            // the current location and non-navigable. Nothing to do.
            break
        case .album, .artist:
            // Shape: ["Jellify", "Library", "<Albums|Artists>", <name>].
            // idx 1 = "Library" and idx 2 = the section both pop to library;
            // idx 3 is the current location and is a no-op.
            if idx < 3 {
                model.screen = .library
            }
        }
    }
}
