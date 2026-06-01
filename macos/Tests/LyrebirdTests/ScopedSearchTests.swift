import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for the scoped (⌘F) search feature: the in-content track filtering
/// predicates on the Artist and Playlist detail pages, the ⌘F routing decision
/// (`requestFind` → scoped bar vs. global Search), and — critically — the
/// route-addressed focus request that prevents a page stacked *under* the
/// visible one in the `NavigationStack` back-stack from stealing focus.
///
/// `AppModel` is `@MainActor`, so the suite is main-actor isolated. We redirect
/// the core's data dir to a throwaway temp dir via `XDG_DATA_HOME` so the tests
/// never touch the real app database.
@MainActor
final class ScopedSearchTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    // MARK: - Fixtures

    private func makeTrack(
        id: String,
        name: String,
        artistName: String = "",
        albumName: String? = nil
    ) -> Track {
        Track(
            id: id,
            name: name,
            albumId: nil,
            albumName: albumName,
            artistName: artistName,
            artistId: nil,
            indexNumber: nil,
            discNumber: nil,
            year: nil,
            runtimeTicks: 0,
            isFavorite: false,
            playCount: 0,
            container: nil,
            bitrate: nil,
            imageTag: nil,
            playlistItemId: nil,
            userData: nil
        )
    }

    // MARK: - ArtistDetailView.filterTopTracks

    func testFilterTopTracksEmptyQueryReturnsAll() {
        let tracks = [
            makeTrack(id: "1", name: "Alpha"),
            makeTrack(id: "2", name: "Beta"),
        ]
        XCTAssertEqual(ArtistDetailView.filterTopTracks(tracks, query: "").map(\.id), ["1", "2"])
        // Whitespace-only is treated as empty.
        XCTAssertEqual(ArtistDetailView.filterTopTracks(tracks, query: "   ").map(\.id), ["1", "2"])
    }

    func testFilterTopTracksMatchesTitleCaseInsensitively() {
        let tracks = [
            makeTrack(id: "1", name: "Bohemian Rhapsody"),
            makeTrack(id: "2", name: "Another One"),
        ]
        XCTAssertEqual(ArtistDetailView.filterTopTracks(tracks, query: "bohemian").map(\.id), ["1"])
        XCTAssertEqual(ArtistDetailView.filterTopTracks(tracks, query: "BOHEMIAN").map(\.id), ["1"])
    }

    func testFilterTopTracksMatchesAlbumName() {
        let tracks = [
            makeTrack(id: "1", name: "Track One", albumName: "Greatest Hits"),
            makeTrack(id: "2", name: "Track Two", albumName: "B-Sides"),
        ]
        XCTAssertEqual(ArtistDetailView.filterTopTracks(tracks, query: "greatest").map(\.id), ["1"])
    }

    func testFilterTopTracksTrimsQueryWhitespace() {
        let tracks = [
            makeTrack(id: "1", name: "Alpha"),
            makeTrack(id: "2", name: "Beta"),
        ]
        // Leading/trailing whitespace must not defeat the match.
        XCTAssertEqual(ArtistDetailView.filterTopTracks(tracks, query: "  alpha  ").map(\.id), ["1"])
    }

    func testFilterTopTracksNoMatchReturnsEmpty() {
        let tracks = [makeTrack(id: "1", name: "Alpha", albumName: "X")]
        XCTAssertTrue(ArtistDetailView.filterTopTracks(tracks, query: "zzz").isEmpty)
    }

    // MARK: - PlaylistView.filterTracks (index preservation)

    func testFilterTracksEmptyQueryReturnsAllWithOriginalIndices() {
        let tracks = [
            makeTrack(id: "a", name: "One"),
            makeTrack(id: "b", name: "Two"),
            makeTrack(id: "c", name: "Three"),
        ]
        let result = PlaylistView.filterTracks(tracks, query: "")
        XCTAssertEqual(result.map { $0.index }, [0, 1, 2])
        XCTAssertEqual(result.map { $0.track.id }, ["a", "b", "c"])
    }

    func testFilterTracksPreservesOriginalIndexWhenFiltered() {
        // The match is at position 2; the filtered result must report index 2,
        // not 0, so playback / reorder target the true playlist position.
        let tracks = [
            makeTrack(id: "a", name: "One"),
            makeTrack(id: "b", name: "Two"),
            makeTrack(id: "c", name: "Needle"),
            makeTrack(id: "d", name: "Four"),
        ]
        let result = PlaylistView.filterTracks(tracks, query: "needle")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].index, 2)
        XCTAssertEqual(result[0].track.id, "c")
    }

    func testFilterTracksMatchesArtistAndAlbum() {
        let tracks = [
            makeTrack(id: "a", name: "Song", artistName: "Radiohead", albumName: "OK Computer"),
            makeTrack(id: "b", name: "Other", artistName: "Blur", albumName: "Parklife"),
        ]
        XCTAssertEqual(PlaylistView.filterTracks(tracks, query: "radiohead").map { $0.track.id }, ["a"])
        XCTAssertEqual(PlaylistView.filterTracks(tracks, query: "parklife").map { $0.track.id }, ["b"])
    }

    // MARK: - activeRouteSupportsScopedSearch / scopedSearchRoute

    func testScopedSearchRouteNilOnRootTabs() throws {
        let model = try AppModel()
        model.navPath = []
        XCTAssertNil(model.scopedSearchRoute)
        XCTAssertFalse(model.activeRouteSupportsScopedSearch)
    }

    func testScopedSearchRouteReflectsTopOfStack() throws {
        let model = try AppModel()
        model.navPath = [.artist("artist-1")]
        XCTAssertEqual(model.scopedSearchRoute, .artist("artist-1"))
        XCTAssertTrue(model.activeRouteSupportsScopedSearch)

        model.navPath = [.album("album-9")]
        XCTAssertNil(model.scopedSearchRoute, "album detail has no scoped bar")
        XCTAssertFalse(model.activeRouteSupportsScopedSearch)
    }

    // MARK: - requestFind routing

    func testRequestFindAddressesRequestToTopRouteWhenScoped() throws {
        let model = try AppModel()
        model.navPath = [.playlist("pl-1")]

        model.requestFind()

        XCTAssertEqual(model.scopedSearchFocusRequest?.route, .playlist("pl-1"))
    }

    func testRequestFindFallsBackToGlobalSearchOffScopedRoutes() throws {
        let model = try AppModel()
        model.navPath = [.album("al-1")]
        model.scopedSearchFocusRequest = nil

        model.requestFind()

        XCTAssertNil(
            model.scopedSearchFocusRequest,
            "off a scoped route ⌘F must not raise a scoped request"
        )
        XCTAssertTrue(
            model.isSearchFieldFocused,
            "⌘F off a scoped route falls back to the global Search surface"
        )
        XCTAssertEqual(model.screen, .search)
    }

    func testRequestFindRePulsesWithFreshTokenForSameRoute() throws {
        let model = try AppModel()
        model.navPath = [.artist("a-1")]

        model.requestFind()
        let first = model.scopedSearchFocusRequest
        XCTAssertNotNil(first)

        model.requestFind()
        let second = model.scopedSearchFocusRequest

        XCTAssertEqual(first?.route, second?.route, "same route on a repeat ⌘F")
        XCTAssertNotEqual(
            first?.token, second?.token,
            "the token must advance so a repeat ⌘F is an observable change"
        )
        XCTAssertNotEqual(first, second, "requests must differ so .onChange fires again")
    }

    // MARK: - consumeScopedSearchFocus — the back-stack race

    func testConsumeFocusOnlyMatchesAddressedRoute() throws {
        let model = try AppModel()
        // Simulate Artist → Playlist drill: both views are alive, playlist on
        // top. ⌘F addresses the playlist.
        model.navPath = [.artist("artist-X"), .playlist("playlist-Y")]
        model.requestFind()
        XCTAssertEqual(model.scopedSearchFocusRequest?.route, .playlist("playlist-Y"))

        // The Artist view (stacked under) must NOT claim the request, and must
        // not consume it out from under the Playlist view.
        XCTAssertFalse(
            model.consumeScopedSearchFocus(for: .artist("artist-X")),
            "the under-stack Artist view must not steal a playlist-addressed request"
        )
        XCTAssertNotNil(
            model.scopedSearchFocusRequest,
            "a non-matching consume must leave the request intact"
        )

        // The Playlist view (on top) claims it and clears it.
        XCTAssertTrue(
            model.consumeScopedSearchFocus(for: .playlist("playlist-Y")),
            "the on-top Playlist view claims its addressed request"
        )
        XCTAssertNil(
            model.scopedSearchFocusRequest,
            "claiming the request clears it so it can't re-fire"
        )
    }

    func testConsumeFocusDistinguishesSameTypeDifferentIds() throws {
        let model = try AppModel()
        // Two playlists stacked (drill from one playlist into another via a
        // shared track / context menu). Route id disambiguates.
        model.navPath = [.playlist("pl-A"), .playlist("pl-B")]
        model.requestFind()

        XCTAssertFalse(
            model.consumeScopedSearchFocus(for: .playlist("pl-A")),
            "the under-stack playlist with a different id must not match"
        )
        XCTAssertTrue(model.consumeScopedSearchFocus(for: .playlist("pl-B")))
    }

    func testConsumeFocusNoRequestIsNoOp() throws {
        let model = try AppModel()
        model.scopedSearchFocusRequest = nil
        XCTAssertFalse(model.consumeScopedSearchFocus(for: .artist("anything")))
    }
}
