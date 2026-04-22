import SwiftUI
@preconcurrency import JellifyCore

struct TrackRow: View {
    @Environment(AppModel.self) private var model

    let track: Track
    let number: Int
    var onPlay: (() -> Void)? = nil

    @State private var isHovering = false

    private var isActive: Bool {
        model.status.currentTrack?.id == track.id
    }
    private var isPlaying: Bool {
        isActive && model.status.state == .playing
    }

    var body: some View {
        HStack(spacing: 12) {
            // Number / play button / equalizer
            ZStack {
                if isPlaying {
                    EqualizerIcon()
                        .foregroundStyle(Theme.accent)
                } else if isHovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink)
                } else {
                    Text("\(number)")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(isActive ? Theme.accent : Theme.ink3)
                }
            }
            .frame(width: 32)

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

            Text(track.durationFormatted)
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Theme.surface2 : (isHovering ? Theme.rowHover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { onPlay?() }
        .onTapGesture(count: 1) { onPlay?() }
        .contextMenu { TrackContextMenu(selection: [track]) }
    }
}

/// Tiny three-bar equalizer visual for the "now playing" row.
/// Respects Reduce Motion: swaps to a static three-bar glyph when on.
struct EqualizerIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Static heights used when Reduce Motion is enabled — chosen to read as
    /// a recognizable EQ glyph without implying motion.
    private let staticHeights: [CGFloat] = [9, 12, 7]

    var body: some View {
        if reduceMotion {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Rectangle()
                        .frame(width: 3, height: staticHeights[i])
                }
            }
            .frame(height: 14)
            .accessibilityLabel("Now playing")
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        let height = 4 + CGFloat(abs(sin(t * 3 + Double(i) * 0.7))) * 10
                        Rectangle()
                            .frame(width: 3, height: height)
                            .animation(.linear(duration: 0.1), value: height)
                    }
                }
                .frame(height: 14)
            }
            .accessibilityLabel("Now playing")
        }
    }
}
