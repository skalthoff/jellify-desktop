import SwiftUI
@preconcurrency import JellifyCore

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let albumID: String

    @State private var tracks: [Track] = []
    @State private var isLoading = true

    private var album: Album? {
        model.albums.first { $0.id == albumID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                transportBar
                trackList
                footer
            }
        }
        .background(Theme.bg)
        .task {
            isLoading = true
            tracks = await model.loadTracks(forAlbum: albumID)
            isLoading = false
        }
    }

    @ViewBuilder
    private var hero: some View {
        if let album = album {
            HStack(alignment: .bottom, spacing: 36) {
                Artwork(
                    url: model.imageURL(for: album.id, tag: album.imageTag, maxWidth: 480),
                    seed: album.name,
                    size: 240,
                    radius: 6
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text("LONG-PLAYER · \(album.year.map(String.init) ?? "")")
                        .font(Theme.font(11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .tracking(3)
                    Text(album.name)
                        .font(Theme.font(72, weight: .black, italic: true))
                        .foregroundStyle(Theme.ink)
                        .tracking(-2)
                    Text("by \(album.artistName)")
                        .font(Theme.font(20, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Theme.accent)
                                .frame(height: 2)
                                .padding(.leading, 28)
                                .offset(y: 2)
                        }
                    HStack(spacing: 28) {
                        stat(value: "\(album.trackCount)", label: "Tracks")
                        stat(value: formatMinutes(album.runtimeTicks), label: "Minutes")
                        if !album.genres.isEmpty {
                            stat(value: album.genres.first ?? "—", label: "Genre")
                        }
                        stat(value: "FLAC", label: "Format")
                    }
                    .padding(.top, 14)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 28)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Theme.font(22, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
            Text(label.uppercased())
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(2)
        }
    }

    @ViewBuilder
    private var transportBar: some View {
        HStack(spacing: 14) {
            Button {
                if !tracks.isEmpty { model.play(tracks: tracks, startIndex: 0) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Theme.accent))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 8)
            }
            .buttonStyle(.plain)

            Image(systemName: "shuffle").font(.system(size: 20)).foregroundStyle(Theme.ink2).frame(width: 36, height: 36)
            Image(systemName: "heart").font(.system(size: 20)).foregroundStyle(Theme.ink2).frame(width: 36, height: 36)
            Image(systemName: "plus").font(.system(size: 20)).foregroundStyle(Theme.ink2).frame(width: 36, height: 36)
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var trackList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                ProgressView().tint(Theme.ink2).padding(.vertical, 40).frame(maxWidth: .infinity)
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                    TrackRow(
                        track: track,
                        number: Int(track.indexNumber ?? UInt32(idx + 1)),
                        onPlay: { model.play(tracks: tracks, startIndex: idx) }
                    )
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var footer: some View {
        if let album = album {
            Text("Released \(album.year.map(String.init) ?? "—") · \(formatMinutes(album.runtimeTicks)) min runtime")
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
        }
    }

    private func formatMinutes(_ ticks: UInt64) -> String {
        let seconds = Double(ticks) / 10_000_000.0
        let minutes = Int(seconds / 60)
        return "\(minutes)"
    }
}
