import SwiftUI
@preconcurrency import JellifyCore

/// Compact single-line row used by the Library Tracks tab. Mirrors the
/// density of `LibraryListRow` (small square artwork, primary + secondary
/// text, trailing metadata) but surfaces track-specific fields: artist on the
/// secondary line and right-aligned duration.
///
/// Clicking / double-clicking plays the track as a one-track queue via
/// `AppModel.play(tracks:startIndex:)`. Hover reveals an inline play button
/// for parity with the album row affordance. Right-click opens a context
/// menu with the standard track actions (play / play next / queue / share).
struct TrackListRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let track: Track
    /// Full track list the row was rendered from, so tap-to-play can hand
    /// the entire ordered list to `AppModel.play` and index into it. This
    /// matches the `AlbumDetailView.trackList` contract.
    let tracks: [Track]
    let index: Int
    @State private var isHovering = false

    private var isActive: Bool {
        model.status.currentTrack?.id == track.id
    }

    private var isPlaying: Bool {
        isActive && model.status.state == .playing
    }

    var body: some View {
        Button {
            model.play(tracks: tracks, startIndex: index)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Artwork(
                        url: model.imageURL(
                            for: track.albumId ?? track.id,
                            tag: track.imageTag,
                            maxWidth: 120
                        ),
                        seed: track.albumName ?? track.name,
                        size: 40,
                        radius: 4
                    )
                    if isPlaying {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.55))
                            .frame(width: 40, height: 40)
                        EqualizerIcon()
                            .foregroundStyle(Theme.accent)
                    } else if isHovering {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 40, height: 40)
                        Image(systemName: "play.fill")
                            .foregroundStyle(.white)
                            .font(.system(size: 13))
                            .transition(.opacity)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(isActive ? Theme.accent : Theme.ink)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }

                Spacer()

                if let album = track.albumName {
                    Text(album)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .frame(maxWidth: 240, alignment: .trailing)
                }

                Text(track.durationFormatted)
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .frame(minWidth: 48, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Theme.surface2 : (isHovering ? Theme.rowHover : .clear))
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
        .accessibilityLabel("\(track.name) by \(track.artistName)")
    }
}
