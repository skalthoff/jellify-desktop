import SwiftUI
@preconcurrency import JellifyCore

/// Shared right-click / long-press context menu for artist surfaces
/// (library/search rows + artist detail hero).
///
/// Issue: #312. Many of the backing actions are TODO stubs pending
/// follow-up FFI work (see individual `AppModel` methods for issue refs).
struct ArtistContextMenu: View {
    @Environment(AppModel.self) private var model
    let artist: Artist

    var body: some View {
        Button("Play All", systemImage: "play.fill") { model.playAll(artist: artist) }
        Button("Shuffle", systemImage: "shuffle") { model.shuffle(artist: artist) }
        Button("Play Top Tracks", systemImage: "chart.bar.fill") {
            model.playTopTracks(artist: artist)
        }

        Divider()

        Button("Favorite", systemImage: "heart") { model.toggleFavorite(artist: artist) }
        Button("Follow", systemImage: "person.badge.plus") { model.toggleFollow(artist: artist) }

        Divider()

        Button("Start Artist Radio", systemImage: "dot.radiowaves.left.and.right") {
            model.startArtistRadio(artist: artist)
        }
        Button("Go to Discography", systemImage: "square.stack") {
            model.goToDiscography(artist: artist)
        }
        Button("Show Similar", systemImage: "person.2") {
            model.showSimilar(artist: artist)
        }

        Divider()

        Button("Share Link", systemImage: "link") { model.copyShareLink(artist: artist) }
            .disabled(model.webURL(for: artist) == nil)
        Button("Show in Jellyfin", systemImage: "safari") { model.openInJellyfin(artist: artist) }
            .disabled(model.webURL(for: artist) == nil)
    }
}
