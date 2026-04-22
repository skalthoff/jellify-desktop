import SwiftUI

struct MainShell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Sidebar()
                Divider().background(Theme.border)
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PlayerBar()
        }
        .background(Theme.bg)
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
