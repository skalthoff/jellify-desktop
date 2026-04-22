import SwiftUI

struct MainShell: View {
    @Environment(AppModel.self) private var model

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
            if !model.network.isOnline {
                OfflineBanner(onRetry: { model.retryNetwork() })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}
