import SwiftUI
@preconcurrency import JellifyCore

/// Library tab options. The active tab filters what the library grid shows
/// and drives the count subline. See `Chip` / `ChipRow` in
/// `Components/Chips.swift` and spec issue #212.
enum LibraryTab: Hashable, CaseIterable {
	case tracks, albums, artists, playlists, downloaded

	var label: String {
		switch self {
		case .tracks: return "Tracks"
		case .albums: return "Albums"
		case .artists: return "Artists"
		case .playlists: return "Playlists"
		case .downloaded: return "Downloaded"
		}
	}

	/// Lowercase noun used in the count subline ("42 albums").
	var countNoun: String {
		switch self {
		case .tracks: return "tracks"
		case .albums: return "albums"
		case .artists: return "artists"
		case .playlists: return "playlists"
		case .downloaded: return "downloaded"
		}
	}
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("libraryViewMode") private var viewMode: LibraryViewMode = .grid
    @State private var selectedTab: LibraryTab = .albums

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                chipRow
                if model.isLoadingLibrary && model.albums.isEmpty {
                    ProgressView()
                        .tint(Theme.ink2)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                } else {
                    content
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .background(backgroundWash)
    }

    /// Jellyfin's web UI lives at `/web/` on the server host. Falls back to
    /// `nil` if the user somehow lands here without a server URL so the empty
    /// state can hide the CTA.
    private var serverWebURL: URL? {
        let trimmed = model.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: "\(base)/web/")
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR LIBRARY")
                    .font(Theme.font(12, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .tracking(2)
                Text("Library")
                    .font(Theme.font(36, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
                // Count subline — 11pt uppercase `ink3`. Updates live as the
                // user switches chips. See #212 / screen spec Issue 13.
                Text(countSubline)
                    .font(Theme.font(11, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .tracking(1.2)
                    .accessibilityLabel("\(tabCount(for: selectedTab)) \(selectedTab.countNoun)")
            }
            Spacer()
            LibraryViewToggle(mode: $viewMode)
        }
    }

    private var chipRow: some View {
        ChipRow(
            options: LibraryTab.allCases.map { (label: $0.label, tag: $0) },
            selection: $selectedTab
        )
    }

    /// Grid / list body for the currently selected chip. Only the `albums`
    /// tab has live content today; the others render the shared empty state
    /// so the chip selection still produces a coherent screen. As tracks,
    /// artists, playlists, and download state land, each branch gets its own
    /// surface.
    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .albums:
            if model.albums.isEmpty {
                EmptyLibraryState(serverUrl: serverWebURL)
            } else {
                switch viewMode {
                case .grid:
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(model.albums, id: \.id) { album in
                            AlbumCard(album: album)
                        }
                    }
                case .list:
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.albums, id: \.id) { album in
                            LibraryListRow(album: album)
                        }
                    }
                }
            }
        case .tracks, .artists, .playlists, .downloaded:
            // Placeholder until the per-tab surfaces land. The chip row, header,
            // and count subline remain live so navigation feels responsive.
            EmptyLibraryState(serverUrl: serverWebURL)
        }
    }

    /// Count for a given tab. Artists has a real count; the rest are stubs
    /// pending their respective FFI/storage work.
    private func tabCount(for tab: LibraryTab) -> Int {
        switch tab {
        case .albums: return model.albums.count
        case .artists: return model.artists.count
        case .tracks, .playlists, .downloaded: return 0
        }
    }

    /// 11pt uppercase count subline, e.g. "42 ALBUMS". Mirrors the spec's
    /// "{n} tracks · Sorted by {sort}" — sort hasn't been wired yet (#216),
    /// so for now the subline is just the count. The sort segment slots in
    /// once the sort menu lands.
    private var countSubline: String {
        let count = tabCount(for: selectedTab)
        return "\(count) \(selectedTab.countNoun)".uppercased()
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

/// Persisted selection for the Library list/grid toggle. Stored via
/// `@AppStorage("libraryViewMode")` — raw values are stable strings so future
/// tab-specific keys (`library.view.tracks` etc.) can share the same decoder.
enum LibraryViewMode: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2.fill"
        case .list: return "list.bullet"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .grid: return "Grid view"
        case .list: return "List view"
        }
    }
}

/// 2-segment control that toggles between list and grid. Matches the
/// design's 3pt padded `surface` pill with `border`. The active segment is
/// inked; the inactive one sits in `ink2`.
struct LibraryViewToggle: View {
    @Binding var mode: LibraryViewMode

    var body: some View {
        HStack(spacing: 2) {
            segment(.list)
            segment(.grid)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library view")
    }

    private func segment(_ target: LibraryViewMode) -> some View {
        let active = mode == target
        return Button {
            mode = target
        } label: {
            Image(systemName: target.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 22)
                .foregroundStyle(active ? Theme.bg : Theme.ink2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? Theme.ink : .clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.accessibilityLabel)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct AlbumCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let album: Album
    @State private var isHovering = false

    var body: some View {
        Button {
            model.screen = .album(album.id)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(
                        url: model.imageURL(for: album.id, tag: album.imageTag, maxWidth: 400),
                        seed: album.name,
                        size: 180,
                        radius: 8
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)

                    Button { model.play(album: album) } label: {
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
                    Text(album.name)
                        .font(Theme.font(13, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(album.artistName)
                            .font(Theme.font(11, weight: .medium))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                        if let year = album.year {
                            Text("· \(String(year))")
                                .font(Theme.font(11, weight: .medium))
                                .foregroundStyle(Theme.ink3)
                        }
                    }
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
        .contextMenu { AlbumContextMenu(album: album) }
    }
}
