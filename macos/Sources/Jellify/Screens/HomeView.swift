import SwiftUI
@preconcurrency import JellifyCore

/// The Home screen. Per the design brief, Home is a "content river": a
/// greeting block, a 3-column quick-tiles row, and a stack of carousels
/// (Recently Played, Artists You Love, Jump Back In, Your Playlists,
/// Recently Added). See `research/06-screen-specs.md`.
///
/// The quick-tiles row (#205), Recently Played carousel (#206), and Artist
/// Radio row (#254) are the first three content blocks to land. The
/// greeting header (#204) and the remaining carousels (#55 / #208 / #209 /
/// #207) will slot into this scaffold in follow-up issues without needing
/// a refactor.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                quickTilesRow
                recentlyPlayedSection
                artistRadioRow
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .background(backgroundWash)
    }

    /// Minimal placeholder header. The full time-aware greeting + CTAs ship
    /// in #204 (Home greeting header). Kept tiny here so the quick tiles row
    /// has a label and a dominant surface to sit under.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WELCOME BACK")
                .font(Theme.font(12, weight: .bold))
                .foregroundStyle(Theme.ink2)
                .tracking(2)
            // TODO: #204 — swap this for the time-aware greeting + BigBtn CTAs.
            Text("Home")
                .font(Theme.font(36, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
            if let name = model.session?.user.name, !name.isEmpty {
                Text("Hi, \(name)")
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
            }
        }
    }

    /// 3-column quick tiles row. Per the brief the content should rank
    /// `recently_played` / `most_played` with a fallback to pinned playlists;
    /// none of those FFI paths exist yet (see #206 for recently_played,
    /// #209 for user_playlists). Until they land we use the first three
    /// albums in the library as a best-effort stand-in.
    private var quickTilesRow: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
            alignment: .leading,
            spacing: 10
        ) {
            // TODO: #206 / #209 — replace `albums.prefix(3)` with the top 3 of
            // `core.recently_played(last_7d)` or `core.most_played(last_7d)`
            // (whichever yields more distinct items), falling back to the
            // first 3 pinned playlists.
            ForEach(Array(tileAlbums.enumerated()), id: \.element.id) { _, album in
                HomeQuickTile(
                    title: album.name,
                    subtitle: album.artistName,
                    artworkURL: model.imageURL(for: album.id, tag: album.imageTag, maxWidth: 96),
                    seed: album.name,
                    action: { model.screen = .album(album.id) },
                    onPlay: { model.play(album: album) }
                )
            }
            // Pad out to exactly three slots so the row layout stays stable
            // before the library has finished loading.
            ForEach(0..<placeholderCount, id: \.self) { _ in
                HomeQuickTilePlaceholder()
            }
        }
    }

    /// Horizontal row of circular "<Artist> Radio" tiles. Source of artists
    /// is picked by `radioArtists`, which today falls back to the first few
    /// library artists — the favorites/top-listened signals (#133, #229)
    /// aren't wired yet, and this view swaps to them seamlessly once they are.
    @ViewBuilder
    private var artistRadioRow: some View {
        if !radioArtists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(Theme.accent)
                        .font(.system(size: 14, weight: .bold))
                    Text("Artist Radio")
                        .font(Theme.font(18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Tap to start a radio station")
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(radioArtists, id: \.id) { artist in
                            ArtistRadioTile(artist: artist)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// The albums surfaced as quick tiles — capped at 3. Pulled from the
    /// currently-loaded library as a placeholder until the ranked data sources
    /// in the TODO above are wired.
    private var tileAlbums: [Album] {
        Array(model.albums.prefix(3))
    }

    /// Number of placeholder tiles needed to fill the 3-column grid while
    /// the library is still loading or empty.
    private var placeholderCount: Int {
        max(0, 3 - tileAlbums.count)
    }

    /// The "Recently Played" carousel (#206). Hidden when the backing data is
    /// still loading or empty so we don't punch a blank hole in the layout.
    @ViewBuilder
    private var recentlyPlayedSection: some View {
        if !model.recentlyPlayed.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recently Played")
                    .font(Theme.font(18, weight: .bold))
                    .foregroundStyle(Theme.ink)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(model.recentlyPlayed, id: \.id) { track in
                            RecentlyPlayedTile(track: track)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// Pick a short list of artists to surface as radio seeds. Prefer
    /// favorites → top-listened → library order. Favorites and top-listened
    /// aren't wired in the core yet (tracked in #133 and #229), so for now
    /// this falls through to the library's first few artists. Capped at 20
    /// so the horizontal row doesn't grow unbounded once the better signals
    /// are available.
    private var radioArtists: [Artist] {
        // TODO: #133 — surface favorites here once `list_favorite_artists`
        //   lands on the core.
        // TODO: #229 — surface top-listened artists once that endpoint is wired.
        let limit = 20
        return Array(model.artists.prefix(limit))
    }

    private var backgroundWash: some View {
        LinearGradient(
            colors: [Theme.primary.opacity(0.15), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .blur(radius: 80)
        .frame(height: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
    }
}

/// An inert, dimmed version of `HomeQuickTile` used to keep the 3-column
/// grid visually balanced before the library has loaded. Intentionally not
/// interactive — once the real data sources for this row exist (#206 / #209)
/// we should prefer a skeleton shimmer, but that belongs in #212 (Home
/// empty + skeleton states).
private struct HomeQuickTilePlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.surface2)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.surface2)
                    .frame(height: 10)
                    .frame(maxWidth: 120, alignment: .leading)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.surface)
                    .frame(height: 8)
                    .frame(maxWidth: 80, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surface.opacity(0.5))
        )
        .accessibilityHidden(true)
    }
}

private struct RecentlyPlayedTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let track: Track
    @State private var isHovering = false

    var body: some View {
        Button {
            model.play(tracks: [track], startIndex: 0)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(
                        url: model.imageURL(
                            for: track.albumId ?? track.id,
                            tag: track.imageTag,
                            maxWidth: 400
                        ),
                        seed: track.albumName ?? track.name,
                        size: 160,
                        radius: 8
                    )
                    .frame(width: 160, height: 160)

                    Image(systemName: "play.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 14))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.primary))
                        .shadow(color: Theme.primary.opacity(0.5), radius: 8, y: 3)
                        .padding(8)
                        .opacity(isHovering ? 1 : 0)
                        .offset(y: reduceMotion ? 0 : (isHovering ? 0 : 8))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(Theme.font(13, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(Theme.font(11, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                .frame(width: 160, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
