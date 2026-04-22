import SwiftUI
@preconcurrency import JellifyCore

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("libraryViewMode") private var viewMode: LibraryViewMode = .grid

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if model.isLoadingLibrary && model.albums.isEmpty {
                    ProgressView()
                        .tint(Theme.ink2)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                } else if model.albums.isEmpty {
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
                Text("\(model.albums.count) albums · \(model.artists.count) artists")
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
            }
            Spacer()
            LibraryViewToggle(mode: $viewMode)
        }
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
