import SwiftUI
@preconcurrency import JellifyCore

/// Compact single-line row used by the Library list view. Mirrors the
/// design's list density: small square artwork, title, secondary text, and
/// a trailing metadata slot. Renders either an album or an artist depending
/// on which payload was used at construction time. Clicking opens the
/// relevant detail screen; hover reveals an inline play button.
struct LibraryListRow: View {
    enum Payload {
        case album(Album)
        case artist(Artist)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let payload: Payload
    @State private var isHovering = false

    init(album: Album) {
        self.payload = .album(album)
    }

    init(artist: Artist) {
        self.payload = .artist(artist)
    }

    var body: some View {
        Button(action: openDetail) {
            HStack(spacing: 12) {
                ZStack {
                    Artwork(
                        url: artworkURL,
                        seed: artworkSeed,
                        size: 40,
                        radius: artworkRadius
                    )
                    if isHovering {
                        Button(action: playPrimary) {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.white)
                                .font(.system(size: 11))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Theme.primary))
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryText)
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(secondaryText)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }

                Spacer()

                if let trailing = trailingMeta {
                    Text(trailing)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .monospacedDigit()
                }

                Text(countMeta)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Theme.rowHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
        }
        .contextMenu { contextMenu }
    }

    // MARK: - Payload-driven properties

    private var artworkURL: URL? {
        switch payload {
        case .album(let album):
            return model.imageURL(for: album.id, tag: album.imageTag, maxWidth: 120)
        case .artist(let artist):
            return model.imageURL(for: artist.id, tag: artist.imageTag, maxWidth: 120)
        }
    }

    private var artworkSeed: String {
        switch payload {
        case .album(let album): return album.name
        case .artist(let artist): return artist.name
        }
    }

    /// Albums use the shared 4pt radius; artists get a pill/circle so the
    /// list row reads consistently with the circular `ArtistRadioTile` used
    /// elsewhere.
    private var artworkRadius: CGFloat {
        switch payload {
        case .album: return 4
        case .artist: return 20
        }
    }

    private var primaryText: String {
        switch payload {
        case .album(let album): return album.name
        case .artist(let artist): return artist.name
        }
    }

    private var secondaryText: String {
        switch payload {
        case .album(let album):
            return album.artistName
        case .artist(let artist):
            if !artist.genres.isEmpty { return artist.genres.joined(separator: ", ") }
            return "Artist"
        }
    }

    /// Optional trailing metadata (e.g. release year for albums). Artists
    /// have no equivalent, so the slot stays empty.
    private var trailingMeta: String? {
        switch payload {
        case .album(let album):
            return album.year.map { String($0) }
        case .artist:
            return nil
        }
    }

    private var countMeta: String {
        switch payload {
        case .album(let album):
            return "\(album.trackCount) tracks"
        case .artist(let artist):
            return artist.albumCount == 1 ? "1 album" : "\(artist.albumCount) albums"
        }
    }

    private func openDetail() {
        switch payload {
        case .album(let album):
            model.screen = .album(album.id)
        case .artist(let artist):
            model.screen = .artist(artist.id)
        }
    }

    private func playPrimary() {
        switch payload {
        case .album(let album):
            model.play(album: album)
        case .artist(let artist):
            model.playAll(artist: artist)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        switch payload {
        case .album(let album):
            AlbumContextMenu(album: album)
        case .artist(let artist):
            ArtistContextMenu(artist: artist)
        }
    }
}
