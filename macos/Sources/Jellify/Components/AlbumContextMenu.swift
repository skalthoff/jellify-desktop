import SwiftUI
@preconcurrency import JellifyCore

/// Shared right-click / long-press context menu for album surfaces
/// (library grid cell + album hero in detail view).
///
/// Issue: #311. Many of the backing actions are TODO stubs pending
/// follow-up FFI work (see individual `AppModel` methods for issue refs).
struct AlbumContextMenu: View {
    @Environment(AppModel.self) private var model
    let album: Album

    var body: some View {
        Button("Play", systemImage: "play.fill") { model.play(album: album) }
        Button("Shuffle", systemImage: "shuffle") { model.shuffle(album: album) }
        Button("Play Next", systemImage: "text.insert") { model.playNext(album: album) }
        Button("Add to Queue", systemImage: "text.append") { model.addToQueue(album: album) }

        Divider()

        Button("Favorite", systemImage: "heart") { model.toggleFavorite(album: album) }
        Button("Download", systemImage: "arrow.down.circle") { model.enqueueDownload(album: album) }
        Button("Add All to Playlist…", systemImage: "plus.rectangle.on.folder") {
            model.requestAddToPlaylist(album: album)
        }

        Divider()

        Button("Go to Artist", systemImage: "person") { model.goToArtist(album: album) }
            .disabled(album.artistId == nil)
        Button("Start Album Radio", systemImage: "dot.radiowaves.left.and.right") {
            model.startAlbumRadio(album: album)
        }

        Divider()

        Button("Share Link", systemImage: "link") { model.copyShareLink(album: album) }
            .disabled(model.webURL(for: album) == nil)
        Button("Show in Jellyfin", systemImage: "safari") { model.openInJellyfin(album: album) }
            .disabled(model.webURL(for: album) == nil)
    }
}
