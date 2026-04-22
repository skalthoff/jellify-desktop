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
                                        .contextMenu { ArtistContextMenu(artist: a) }
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
                        // "Show all N results" — visible when the server
                        // reports more matches than the current page holds.
                        // See issue #429. Jellyfin doesn't expose per-kind
                        // pagination on this endpoint, so we page the
                        // combined response and let the per-kind arrays
                        // grow as new results come in.
                        if showAllResultsVisible(for: results) {
                            showAllResultsButton(for: results)
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
            TextField("Search library", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.font(18, weight: .medium))
                .foregroundStyle(Theme.ink)
                .focused($searchFieldFocused)
                .onSubmit {
                    Task { await model.search(query) }
                }
                // Esc clears the field (without removing focus) so the user
                // can start a new query without reaching for the mouse.
                .onExitCommand {
                    if !query.isEmpty {
                        clearQuery()
                    }
                }
            if !query.isEmpty {
                Button(action: clearQuery) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.ink2)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
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

    /// Clears the current query, resets any displayed results, and keeps
    /// keyboard focus in the field so the user can immediately type a new
    /// search. Shared by the x-button and Esc keybinding.
    private func clearQuery() {
        query = ""
        searchFieldFocused = true
        Task { await model.search("") }
    }

    @ViewBuilder
    private func section(_ title: String) -> some View {
        Text(title)
            .font(Theme.font(18, weight: .bold))
            .foregroundStyle(Theme.ink)
            .padding(.top, 12)
    }

    /// Total rows currently displayed across all three typed sections.
    /// Used against `searchResultsTotal` to decide whether a follow-up page
    /// would yield anything new.
    private func loadedCount(for results: SearchResults) -> Int {
        results.artists.count + results.albums.count + results.tracks.count
    }

    private func showAllResultsVisible(for results: SearchResults) -> Bool {
        Int(model.searchResultsTotal) > loadedCount(for: results)
    }

    @ViewBuilder
    private func showAllResultsButton(for results: SearchResults) -> some View {
        let loaded = loadedCount(for: results)
        let total = Int(model.searchResultsTotal)
        HStack {
            Spacer()
            if model.isLoadingMoreSearch {
                ProgressView()
                    .tint(Theme.ink2)
                    .scaleEffect(0.8)
                    .padding(.vertical, 14)
            } else {
                Button {
                    Task { await model.loadMoreSearchResults() }
                } label: {
                    Text("Show all \(total) results (\(loaded) shown)")
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Theme.borderStrong, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show all \(total) results, \(loaded) currently shown")
            }
            Spacer()
        }
        .padding(.top, 16)
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
