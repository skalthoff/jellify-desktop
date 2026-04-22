import SwiftUI
@preconcurrency import JellifyCore

/// Compact single-line row used by the Library list view. Mirrors the
/// design's list density: small square artwork, album title, artist, year.
/// Clicking opens the album detail; hover reveals an inline play button.
struct LibraryListRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let album: Album
    @State private var isHovering = false

    var body: some View {
        Button {
            model.screen = .album(album.id)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Artwork(
                        url: model.imageURL(for: album.id, tag: album.imageTag, maxWidth: 120),
                        seed: album.name,
                        size: 40,
                        radius: 4
                    )
                    if isHovering {
                        Button { model.play(album: album) } label: {
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
                    Text(album.name)
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(album.artistName)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }

                Spacer()

                if let year = album.year {
                    Text(String(year))
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .monospacedDigit()
                }

                Text("\(album.trackCount) tracks")
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
        .contextMenu { AlbumContextMenu(album: album) }
    }
}
