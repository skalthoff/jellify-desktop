import SwiftUI
@preconcurrency import JellifyCore

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query: String = ""
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SEARCH")
                        .font(Theme.font(12, weight: .bold))
                        .foregroundStyle(Theme.ink2)
                        .tracking(2)
                    searchField
                }
                if let results = model.searchResults {
                    if results.artists.isEmpty && results.albums.isEmpty && results.tracks.isEmpty {
                        NoSearchResultsState(query: model.searchQuery)
                    } else {
                        if !results.artists.isEmpty {
                            section("Artists")
                            VStack(spacing: 2) {
                                ForEach(results.artists, id: \.id) { a in
                                    resultRow(title: a.name, subtitle: a.genres.first ?? "Artist", seed: a.name)
                                }
                            }
                        }
                        if !results.albums.isEmpty {
                            section("Albums")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading, spacing: 18) {
                                ForEach(results.albums, id: \.id) { alb in
                                    AlbumCard(album: alb)
                                }
                            }
                        }
                        if !results.tracks.isEmpty {
                            section("Tracks")
                            VStack(spacing: 0) {
                                ForEach(Array(results.tracks.enumerated()), id: \.element.id) { idx, t in
                                    TrackRow(
                                        track: t,
                                        number: idx + 1,
                                        onPlay: { model.play(tracks: results.tracks, startIndex: idx) }
                                    )
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 32)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .background(Theme.bg)
        .onAppear {
            // Focus the search field immediately whenever the Search screen
            // appears so ⌘F (which sets screen = .search) lands focus here.
            if model.requestSearchFocus {
                searchFieldFocused = true
                model.requestSearchFocus = false
            }
        }
        .onChange(of: model.requestSearchFocus) { _, newValue in
            // Handles the case where the Search screen is already visible
            // when ⌘F is pressed — `onAppear` won't fire again, but
            // `focusSearch()` toggles this flag so we can refocus here.
            if newValue {
                searchFieldFocused = true
                model.requestSearchFocus = false
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.ink2)
                .font(.system(size: 18))
            TextField("Artists, albums, tracks…", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.font(18, weight: .medium))
                .foregroundStyle(Theme.ink)
                .focused($searchFieldFocused)
                .onSubmit {
                    Task { await model.search(query) }
                }
            if !query.isEmpty {
                Button { query = ""; Task { await model.search("") } } label: {
                    Image(systemName: "xmark").foregroundStyle(Theme.ink2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.borderStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func section(_ title: String) -> some View {
        Text(title)
            .font(Theme.font(18, weight: .bold))
            .foregroundStyle(Theme.ink)
            .padding(.top, 12)
    }

    @ViewBuilder
    private func resultRow(title: String, subtitle: String, seed: String) -> some View {
        HStack(spacing: 12) {
            Artwork(url: nil, seed: seed, size: 40, radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(13, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(subtitle).font(Theme.font(11, weight: .medium)).foregroundStyle(Theme.ink2)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
