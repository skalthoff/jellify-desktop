import SwiftUI
@preconcurrency import JellifyCore

/// The Home screen. Per the design brief, Home is a "content river": a
/// greeting block, a 3-column quick-tiles row, and a stack of carousels
/// (Recently Played, Artists You Love, Jump Back In, Your Playlists,
/// Recently Added). See `research/06-screen-specs.md`.
///
/// The greeting header (#204), quick-tiles row (#205), Recently Played
/// carousel (#206), Pinned Stations row (#253), and Artist Radio row (#254)
/// are the first content blocks to land. The remaining carousels
/// (#55 / #208 / #209 / #207) will slot into this scaffold in follow-up
/// issues without needing a refactor.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    /// Locally-persisted list of pinned stations (#253). JSON-encoded into
    /// `@AppStorage` via `PinnedStationsStore` — placeholder until the real
    /// pin infrastructure ships. See `PinnedStationTile.swift`.
    @AppStorage(PinnedStationsStore.defaultsKey) private var pinnedStationsData: Data = Data()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                quickTilesRow
                recentlyPlayedSection
                pinnedStationsRow
                artistRadioRow
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .background(backgroundWash)
    }

    /// Time-of-day aware greeting header with two pill CTAs (#204).
    ///
    /// Layout follows `research/06-screen-specs.md`:
    /// - Eyebrow "IN ROTATION" 12pt `ink2`, letter-spaced.
    /// - Italic 42pt black h1 greeting. Copy branches on the current hour
    ///   and, when a session exists, is personalised with the user's first
    ///   name ("good morning, jane").
    /// - 14pt `ink2` subtitle with the accent-coloured "instant mix" word.
    /// - Right-aligned CTAs: primary "Instant Mix" (ink fill) + ghost
    ///   "Shuffle All" (border-only). On narrow windows the header stacks
    ///   vertically so the CTAs never clip.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                greetingBlock
                Spacer(minLength: 16)
                headerCTAs
                    .padding(.top, 22)
            }
            VStack(alignment: .leading, spacing: 18) {
                greetingBlock
                headerCTAs
            }
        }
    }

    /// Left-hand block: eyebrow, greeting, subtitle. Pulled out of `header`
    /// so the stacked + side-by-side layouts in `ViewThatFits` can share it.
    @ViewBuilder
    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IN ROTATION")
                .font(Theme.font(12, weight: .bold))
                .foregroundStyle(Theme.ink2)
                .tracking(1.2)
            Text(greetingText)
                .font(Theme.font(42, weight: .black, italic: true))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            subtitleLine
        }
    }

    /// Subtitle rendered as three Text pieces so the middle "instant mix"
    /// word can be styled in accent italic — per the `06-screen-specs.md`
    /// "inline accent italicized link" pattern. Concatenating `Text` values
    /// preserves each run's styling while keeping the whole line wrappable.
    private var subtitleLine: some View {
        (
            Text("Pick up where you left off, or start an ")
                + Text("instant mix")
                    .font(Theme.font(14, weight: .semibold, italic: true))
                    .foregroundColor(Theme.accent)
                + Text(" seeded from your library.")
        )
        .font(Theme.font(14, weight: .medium))
        .foregroundStyle(Theme.ink2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Pick up where you left off, or start an instant mix seeded from your library.")
    }

    /// Right-hand action cluster: primary "Instant Mix" + ghost "Shuffle All".
    /// Shuffle All dims + disables while the library hasn't loaded; Instant
    /// Mix always remains tappable since it routes through a stub landing pad
    /// regardless of library state (see `AppModel.startInstantMix`).
    @ViewBuilder
    private var headerCTAs: some View {
        HStack(spacing: 10) {
            Button {
                model.startInstantMix()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                    Text("Instant Mix")
                        .font(Theme.font(13, weight: .bold))
                }
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Capsule().fill(Theme.ink))
                .shadow(color: Theme.ink.opacity(0.18), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start Instant Mix")
            .accessibilityHint("Generates a personalised mix seeded from your library")

            Button {
                model.shuffleLibrary()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 13, weight: .bold))
                    Text("Shuffle All")
                        .font(Theme.font(13, weight: .semibold))
                }
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    Capsule().stroke(Theme.borderStrong, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(model.albums.isEmpty)
            .opacity(model.albums.isEmpty ? 0.5 : 1)
            .accessibilityLabel("Shuffle your entire library")
        }
    }

    /// Produces the time-branched greeting per `06-screen-specs.md`:
    /// `<5h → "still up?"`, `<12 → "good morning"`, `<18 → "good afternoon"`,
    /// else `"good evening"`. Appends the first name when a session is in
    /// place, so logged-out previews still render nicely.
    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let base: String
        switch hour {
        case 0..<5: base = "still up?"
        case 5..<12: base = "good morning"
        case 12..<18: base = "good afternoon"
        default: base = "good evening"
        }
        guard let first = firstName(from: model.session?.user.name), !first.isEmpty else {
            return base
        }
        // "still up?" keeps its terminal punctuation — tucking a name in
        // after the question mark reads awkwardly, so skip personalisation.
        if base.hasSuffix("?") { return base }
        return "\(base), \(first.lowercased())"
    }

    /// Split the Jellyfin display name on whitespace and return the first
    /// non-empty segment. Returns `nil` for empty / whitespace-only input so
    /// `greetingText` can fall back to the un-personalised copy.
    private func firstName(from displayName: String?) -> String? {
        guard let displayName else { return nil }
        let first = displayName
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? ""
        return first.isEmpty ? nil : first
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

    /// Pinned Stations row (#253). A user-curated shelf of station "presets"
    /// — artist radios, playlists, moods. The real pin infrastructure (server
    /// or core-backed) doesn't exist yet, so we back the row with a local
    /// `@AppStorage` array of `PinnedStation` triples. When empty we show an
    /// empty-state card with a "Pin a station" CTA; the CTA and the end-of-row
    /// "+ Add station" pill are both inert pending the pin UI.
    @ViewBuilder
    private var pinnedStationsRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "pin.fill")
                    .foregroundStyle(Theme.primary)
                    .font(.system(size: 14, weight: .bold))
                    .rotationEffect(.degrees(-15))
                Text("Pinned Stations")
                    .font(Theme.font(18, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Your radio presets — always one click away")
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
            }

            if pinnedStations.isEmpty {
                PinnedStationsEmptyState(action: handlePinAction)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(pinnedStations) { station in
                            PinnedStationTile(
                                station: station,
                                subtitle: pinnedStationSubtitle(for: station),
                                action: { handleStationTap(station) }
                            )
                        }
                        PinnedStationAddPill(action: handlePinAction)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// Decoded view over `pinnedStationsData`. The `@AppStorage` backing is a
    /// single `Data` blob (JSON), decoded every render — the lists are tiny
    /// and this avoids a separate observable object just for placeholder data.
    private var pinnedStations: [PinnedStation] {
        guard !pinnedStationsData.isEmpty else { return [] }
        return (try? JSONDecoder().decode([PinnedStation].self, from: pinnedStationsData)) ?? []
    }

    /// Placeholder subtitle — we don't yet have a real "track count / updated"
    /// signal for user-curated stations. Once the pin model exposes those
    /// fields we swap this for the live string; the tile already accepts any
    /// string. See `06-screen-specs.md §9`.
    private func pinnedStationSubtitle(for station: PinnedStation) -> String {
        // TODO: #253 follow-up — replace with live "N tracks · updated X" once
        // the pin model carries those fields.
        switch station.type {
        case .artist: return "Artist radio · updated today"
        case .playlist: return "Playlist · always fresh"
        case .mood: return "Mood station · updated today"
        case .genre: return "Genre station · updated today"
        case .mix: return "Auto mix · updated today"
        }
    }

    /// Inert handler for the "Pin a station" / "+ Add station" CTAs. The pin
    /// picker UI hasn't been built yet (see #253 follow-up) — log and bail.
    private func handlePinAction() {
        // TODO: #253 follow-up — open the pin picker / station library
        // modal. For now, just log so we can see the hit rate in console.
        print("[HomeView] Pin a station tapped — pin picker UI not yet built (#253).")
    }

    /// Inert handler for a tapped pinned station. Logs the triple so we can
    /// see it in the console. Real routing (start this radio / open this
    /// playlist) waits on the Instant Mix FFI (#144) and the pin model.
    private func handleStationTap(_ station: PinnedStation) {
        // TODO: #144 / #253 — route to start the corresponding station once
        // the typed pin model + Instant Mix FFI land.
        print("[HomeView] Pinned station tapped: type=\(station.type.rawValue) id=\(station.id) title=\"\(station.title)\"")
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

// `RecentlyPlayedTile` lives in `Components/RecentlyPlayedTile.swift` so it
// can be reused from the Discover "For You" carousel (#249) without
// duplication.
