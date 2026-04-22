import SwiftUI
@preconcurrency import JellifyCore

/// Artist detail screen scaffold. Today this lands the hero (circular
/// artwork, artist name, quick counts) and the "Top Tracks" section (#229) —
/// a compact 5-row list of the artist's most-played tracks, tap-to-play.
///
/// Fuller surfaces (discography grouped by album, bio/overview, similar
/// artists, follower state) are tracked in #58 / #60 / #408 / #146 and will
/// slot in as their backing FFI lands. For now this view is intentionally
/// narrow: it only exposes what's live on the core today and routes every
/// other artist action (playAll / shuffle / radio / follow / favorite /
/// share) through the `ArtistContextMenu` so the affordances stay visible.
struct ArtistView: View {
    @Environment(AppModel.self) private var model
    let artistID: String

    @State private var topTracks: [Track] = []
    @State private var isLoadingTopTracks = true
    @State private var artistAlbums: [Album] = []

    /// Resolve the artist from the model's cached list. Missing is an edge
    /// case (deep link, or the list evicted the artist) and we render a
    /// gentle placeholder rather than crash.
    private var artist: Artist? {
        model.artists.first { $0.id == artistID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                transportBar
                topTracksSection
                footer
            }
        }
        .background(Theme.bg)
        .task(id: artistID) {
            // Resolve artist albums for the header stats (count) and the
            // footer. Cached in-memory by the library load; we're just
            // filtering. Top tracks go through the core fetch.
            artistAlbums = model.albums.filter { $0.artistId == artistID }
            isLoadingTopTracks = true
            topTracks = await model.loadArtistTopTracks(artistId: artistID)
            isLoadingTopTracks = false
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        if let artist = artist {
            HStack(alignment: .bottom, spacing: 36) {
                Artwork(
                    url: model.imageURL(for: artist.id, tag: artist.imageTag, maxWidth: 480),
                    seed: artist.name,
                    size: 220,
                    radius: 110
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text("ARTIST")
                        .font(Theme.font(11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .tracking(3)
                    Text(artist.name)
                        .font(Theme.font(72, weight: .black, italic: true))
                        .foregroundStyle(Theme.ink)
                        .tracking(-2)
                        .lineLimit(2)
                    HStack(spacing: 28) {
                        stat(value: "\(artistAlbums.count)", label: "Albums")
                        if !artist.genres.isEmpty {
                            stat(value: artist.genres.first ?? "—", label: "Genre")
                        }
                        // Song count from the server is often 0 on artist
                        // endpoints that don't project it. Surface only
                        // when we actually have it.
                        if artist.songCount > 0 {
                            stat(value: "\(artist.songCount)", label: "Tracks")
                        }
                    }
                    .padding(.top, 14)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 28)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            .contextMenu { ArtistContextMenu(artist: artist) }
        } else {
            HStack {
                Text("Artist not found")
                    .font(Theme.font(18, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                Spacer()
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 44)
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

    // MARK: - Transport

    @ViewBuilder
    private var transportBar: some View {
        if let artist = artist {
            HStack(spacing: 14) {
                Button { model.playTopTracks(artist: artist) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Theme.accent))
                        .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 8)
                }
                .buttonStyle(.plain)
                .disabled(topTracks.isEmpty)
                .help("Play top tracks")

                Button { model.shuffle(artist: artist) } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .help("Shuffle artist")

                Button { model.startArtistRadio(artist: artist) } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .help("Artist radio")

                Button { model.toggleFavorite(artist: artist) } label: {
                    Image(systemName: "heart")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .help("Favorite")

                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Top Tracks

    @ViewBuilder
    private var topTracksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                eyebrow: "MOST PLAYED",
                title: "Top Tracks"
            )
            VStack(alignment: .leading, spacing: 2) {
                if isLoadingTopTracks {
                    ProgressView()
                        .tint(Theme.ink2)
                        .padding(.vertical, 40)
                        .frame(maxWidth: .infinity)
                } else if topTracks.isEmpty {
                    emptyTopTracks
                } else {
                    ForEach(Array(topTracks.enumerated()), id: \.element.id) { idx, track in
                        TopTrackRow(track: track, rank: idx + 1, queue: topTracks)
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 20)
    }

    @ViewBuilder
    private func sectionHeader(eyebrow: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow)
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.accent)
                .tracking(3)
            Text(title)
                .font(Theme.font(24, weight: .heavy))
                .foregroundStyle(Theme.ink)
        }
    }

    /// Rendered when the core returned no top tracks — e.g. the user has
    /// never played this artist, or the server has no audio items credited
    /// to them. Keeps the section anchored on the page instead of vanishing
    /// entirely so the section heading doesn't look like a bug.
    @ViewBuilder
    private var emptyTopTracks: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink3)
            Text("No play history yet for this artist.")
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
            Spacer()
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if let artist = artist {
            Text("\(artist.name) · \(artistAlbums.count) albums")
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
        }
    }
}
