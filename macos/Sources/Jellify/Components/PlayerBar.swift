import SwiftUI
@preconcurrency import JellifyCore

struct PlayerBar: View {
    @Environment(AppModel.self) private var model
    @State private var showNowPlaying = false

    var body: some View {
        HStack(spacing: 16) {
            leftMeta
                .frame(width: 280, alignment: .leading)
            Spacer(minLength: 16)
            centerTransport
                .frame(maxWidth: 640)
            Spacer(minLength: 16)
            rightControls
                .frame(width: 220, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 78)
        // HUD-style translucent material for the unified transport bar so
        // the chrome matches Music.app's bottom panel and reads as "system
        // chrome" rather than app content. Brand wash on top keeps Jellify's
        // palette dominant. See issues #9 / #10 / #28.
        .background(
            VisualEffectView(material: .hudWindow)
                .overlay(Theme.bgAlt.opacity(0.7))
        )
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingSheet()
                .environment(model)
        }
    }

    @ViewBuilder
    private var leftMeta: some View {
        if let track = model.status.currentTrack {
            // Tapping the track meta opens the Now Playing sheet (#279)
            // which currently surfaces track artwork, title/artist/album,
            // and the Credits block. The button is styled flush so it
            // reads as a regular bar region, not a chrome control.
            Button(action: { showNowPlaying = true }) {
                HStack(spacing: 12) {
                    Artwork(
                        url: model.imageURL(for: track.albumId ?? track.id, tag: track.imageTag, maxWidth: 120),
                        seed: track.name,
                        size: 54,
                        radius: 6
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.name)
                            .font(Theme.font(13, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text("\(track.artistName) · \(track.albumName ?? "")")
                            .font(Theme.font(11, weight: .medium))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now Playing: \(track.name) by \(track.artistName)")
            .accessibilityHint("Shows track details")
        } else {
            Text("Nothing playing")
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    @ViewBuilder
    private var centerTransport: some View {
        VStack(spacing: 6) {
            HStack(spacing: 20) {
                iconBtn("shuffle")
                iconBtn("backward.fill", size: 16) { model.skipPrevious() }
                Button(action: model.togglePlayPause) {
                    Image(systemName: model.status.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.bg)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.ink))
                }
                .buttonStyle(.plain)
                iconBtn("forward.fill", size: 16) { model.skipNext() }
                iconBtn("repeat")
            }
            HStack(spacing: 10) {
                Text(format(model.status.positionSeconds))
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)

                GeometryReader { geom in
                    let total = max(1.0, model.status.durationSeconds)
                    let pct = min(1.0, model.status.positionSeconds / total)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface2)
                        Capsule().fill(Theme.ink).frame(width: geom.size.width * CGFloat(pct))
                    }
                    .frame(height: 4)
                }
                .frame(height: 4)

                Text(format(model.status.durationSeconds))
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var rightControls: some View {
        HStack(spacing: 6) {
            Spacer()
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink2)
            Slider(
                value: Binding(
                    get: { Double(model.status.volume) },
                    set: { model.setVolume(Float($0)) }
                ),
                in: 0...1
            )
            .tint(Theme.ink2)
            .frame(width: 100)
        }
    }

    @ViewBuilder
    private func iconBtn(_ name: String, size: CGFloat = 14, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(Theme.ink2)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
