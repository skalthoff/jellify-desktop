import SwiftUI
@preconcurrency import JellifyCore

/// Shared right-click / long-press context menu for playlist surfaces
/// (sidebar rows + playlist detail hero, once those land).
///
/// Issue: #313. Parallels `AlbumContextMenu` (#311). Many of the backing
/// actions are TODO stubs pending follow-up FFI work: playlist mutation
/// (#126 create, #130 update/rename, #131 delete), queue append (#282),
/// favorites (#133), and the download engine (#70). See the individual
/// `AppModel` methods for the full list of issue references.
struct PlaylistContextMenu: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist

    var body: some View {
        Button("Play", systemImage: "play.fill") { model.play(playlist: playlist) }
        Button("Shuffle", systemImage: "shuffle") { model.shuffle(playlist: playlist) }
        Button("Play Next", systemImage: "text.insert") { model.playNext(playlist: playlist) }
        Button("Add to Queue", systemImage: "text.append") { model.addToQueue(playlist: playlist) }

        Divider()

        Button("Favorite", systemImage: "heart") { model.toggleFavorite(playlist: playlist) }
        Button("Download", systemImage: "arrow.down.circle") { model.enqueueDownload(playlist: playlist) }
        Button("Rename…", systemImage: "pencil") { model.requestRename(playlist: playlist) }
        Button("Delete", systemImage: "trash", role: .destructive) {
            model.requestDelete(playlist: playlist)
        }

        Divider()

        Button("Share Link", systemImage: "link") { model.copyShareLink(playlist: playlist) }
            .disabled(model.webURL(for: playlist) == nil)
        Button("Show in Jellyfin", systemImage: "safari") { model.openInJellyfin(playlist: playlist) }
            .disabled(model.webURL(for: playlist) == nil)
    }
}
