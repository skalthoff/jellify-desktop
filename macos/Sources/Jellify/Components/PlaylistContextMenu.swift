import SwiftUI
@preconcurrency import JellifyCore

/// Shared right-click / long-press context menu for playlist surfaces
/// (sidebar rows, library grid cards, playlist detail hero).
///
/// Menu order follows Apple Music + Spotify convention and the spec in #98:
///
///     Play, Shuffle, Play Next, Add to Queue
///     ─
///     Rename (inline), Duplicate, Delete (with confirm)
///     ─
///     Export as .m3u8…, Copy Link
///
/// The destructive Delete action opens a `.confirmationDialog` on the parent
/// view via `AppModel.playlistPendingDelete`. Destructive mutations
/// (rename, duplicate, delete) call through to BATCH-06 stubs in
/// `AppModel`; those forward to real core calls when #126 / #130 / #131 land.
struct PlaylistContextMenu: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist

    var body: some View {
        Button("Play", systemImage: "play.fill") { model.play(playlist: playlist) }
        Button("Shuffle", systemImage: "shuffle") { model.shuffle(playlist: playlist) }
        Button("Play Next", systemImage: "text.insert") { model.playNext(playlist: playlist) }
        Button("Add to Queue", systemImage: "text.append") { model.addToQueue(playlist: playlist) }

        Divider()

        Button("Rename", systemImage: "pencil") { model.requestRename(playlist: playlist) }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            model.requestDuplicate(playlist: playlist)
        }
        Button("Delete", systemImage: "trash", role: .destructive) {
            model.confirmDelete(playlist: playlist)
        }

        Divider()

        Button("Export as .m3u8…", systemImage: "square.and.arrow.up.on.square") {
            model.exportPlaylist(playlist: playlist)
        }
        Button("Copy Link", systemImage: "link") { model.copyShareLink(playlist: playlist) }
            .disabled(model.webURL(for: playlist) == nil)
    }
}
