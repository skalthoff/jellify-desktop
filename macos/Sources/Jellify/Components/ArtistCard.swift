import SwiftUI
@preconcurrency import JellifyCore

/// Square grid tile used in the Library Artists tab. Mirrors the shape and
/// visual language of `AlbumCard`: square artwork, name below, hover reveals
/// a play overlay. Tapping the card routes to the artist detail screen via
/// `model.screen = .artist(artist.id)`.
///
/// Issue: #213 (Library → Artists grid). The overlay play button calls
/// `AppModel.playAll(artist:)`, which is a logging stub today pending
/// `artist_tracks` FFI (#156 / #465). The visual affordance matches the
/// album card so users have a consistent hover model across the grid.
struct ArtistCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let artist: Artist
    @State private var isHovering = false

    var body: some View {
        Button {
            model.screen = .artist(artist.id)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(
                        url: model.imageURL(for: artist.id, tag: artist.imageTag, maxWidth: 400),
                        seed: artist.name,
                        size: 180,
                        radius: 8
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)

                    Button { model.playAll(artist: artist) } label: {
                        Image(systemName: "play.fill")
                            .foregroundStyle(.white)
                            .font(.system(size: 16))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Theme.primary))
                            .shadow(color: Theme.primary.opacity(0.5), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .opacity(isHovering ? 1 : 0)
                    .offset(y: reduceMotion ? 0 : (isHovering ? 0 : 8))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name)
                        .font(Theme.font(13, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(albumCountLabel)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovering ? Theme.surface : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu { ArtistContextMenu(artist: artist) }
    }

    /// Subline shown under the artist name. Uses `album_count` when known;
    /// falls back to song count so the tile always reads as "something by
    /// this artist" rather than an orphaned label.
    private var albumCountLabel: String {
        if artist.albumCount > 0 {
            return artist.albumCount == 1 ? "1 album" : "\(artist.albumCount) albums"
        }
        if artist.songCount > 0 {
            return artist.songCount == 1 ? "1 song" : "\(artist.songCount) songs"
        }
        return "Artist"
    }
}
