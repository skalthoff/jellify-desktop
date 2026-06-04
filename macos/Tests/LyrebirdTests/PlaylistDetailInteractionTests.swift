import AppKit
import XCTest

@testable import Lyrebird
@testable import LyrebirdCore

/// Pure-logic coverage for the `PlaylistDetailView` interaction fixes (2.0
/// polish audit): the drop-to-add payload parser that drives drop acceptance
/// and error surfacing (#236), and the row-click selection arithmetic the view
/// shares with `LibraryView` (#74 / #236).
///
/// These are deliberately View-, FFI-, and `AppModel`-free — the row-click glue
/// in `PlaylistDetailView.handleRowClick` now delegates to the same
/// `TrackSelectionResolver.resolve` exercised here, so the out-of-bounds (stale
/// index) guard and the Cmd-over-Shift precedence are locked down without a
/// SwiftUI scene graph.
final class PlaylistDetailInteractionTests: XCTestCase {

    // MARK: - Drop payload parsing (drop acceptance + empty-ids branch)

    func testParseTrackIdsReadsJSONArray() {
        let data = Data(#"["id-1","id-2","id-3"]"#.utf8)
        XCTAssertEqual(PlaylistDropPayload.parseTrackIds(from: data), ["id-1", "id-2", "id-3"])
    }

    func testParseTrackIdsReadsNewlineSeparatedText() {
        let data = Data("id-1\nid-2\n  id-3  \n".utf8)
        XCTAssertEqual(PlaylistDropPayload.parseTrackIds(from: data), ["id-1", "id-2", "id-3"])
    }

    func testParseTrackIdsSkipsBlankJSONEntries() {
        let data = Data(#"["id-1","   ","id-2"]"#.utf8)
        XCTAssertEqual(PlaylistDropPayload.parseTrackIds(from: data), ["id-1", "id-2"])
    }

    func testParseTrackIdsReturnsEmptyForBlankText() {
        // An all-whitespace / empty payload yields no ids — the signal
        // `handleDroppedPayload` uses to surface the "no tracks to add" error
        // instead of firing an empty add.
        XCTAssertTrue(PlaylistDropPayload.parseTrackIds(from: Data("\n   \n".utf8)).isEmpty)
        XCTAssertTrue(PlaylistDropPayload.parseTrackIds(from: Data()).isEmpty)
    }

    func testParseTrackIdsIgnoresNonStringJSON() {
        // A JSON object / number array isn't a `[String]`, so it falls through
        // to the newline path and (finding nothing line-like) yields nothing
        // usable beyond the raw blob — never a crash.
        let data = Data(#"{"ids":["a"]}"#.utf8)
        // The object serializes to a single non-id line; what matters is it
        // does not decode as a string array, so no structured ids come back.
        XCTAssertEqual(PlaylistDropPayload.parseTrackIds(from: data), [#"{"ids":["a"]}"#])
    }

    // MARK: - Row-click bounds safety (stale index → no-op, no crash)

    func testStaleIndexBeyondShrunkListIsRejected() {
        // Simulates the L337 crash setup: a row's index was captured at render
        // time as 4, but the array shrank to 2 entries before the click landed.
        // The resolver returns nil so `handleRowClick` does nothing instead of
        // force-indexing `tracks[4]`.
        let shrunk = ["a", "b"]
        XCTAssertNil(
            TrackSelectionResolver.resolve(
                clickedIndex: 4,
                trackIds: shrunk,
                currentSelection: ["a"],
                anchorIndex: 0,
                modifiers: []
            )
        )
    }

    func testBareClickWithinBoundsPlaysAndClears() {
        let ids = ["a", "b", "c"]
        let outcome = TrackSelectionResolver.resolve(
            clickedIndex: 1,
            trackIds: ids,
            currentSelection: ["a", "c"],
            anchorIndex: 0,
            modifiers: []
        )
        XCTAssertEqual(outcome, .init(selection: [], anchorIndex: 1, shouldPlay: true))
    }

    // MARK: - Multiselect precedence (the L603 .gesture fix's contract)

    func testCommandClickTogglesWithoutPlaying() {
        // The whole point of the `.gesture` (not `.simultaneousGesture`) fix:
        // a Cmd+Click must toggle selection only — never also play+clear.
        let ids = ["a", "b", "c"]
        let outcome = TrackSelectionResolver.resolve(
            clickedIndex: 2,
            trackIds: ids,
            currentSelection: ["a"],
            anchorIndex: 0,
            modifiers: .command
        )
        XCTAssertEqual(outcome, .init(selection: ["a", "c"], anchorIndex: 2, shouldPlay: false))
        XCTAssertFalse(outcome?.shouldPlay ?? true)
    }

    func testCommandTakesPrecedenceWhenCmdAndShiftBothHeld() {
        let ids = ["a", "b", "c", "d"]
        let outcome = TrackSelectionResolver.resolve(
            clickedIndex: 3,
            trackIds: ids,
            currentSelection: ["a"],
            anchorIndex: 0,
            modifiers: [.command, .shift]
        )
        // Cmd checked first → single-row toggle, not a range extend.
        XCTAssertEqual(outcome, .init(selection: ["a", "d"], anchorIndex: 3, shouldPlay: false))
    }
}

/// `AppModel`-level coverage for the `loadPlaylistTracks` cache contract that
/// backs the drop-to-add list refresh (#236). `AppModel` is `@MainActor` and
/// boots a live (logged-out) `LyrebirdCore`; the data dir is redirected to a
/// throwaway temp dir so the test never touches the real app database and the
/// cache-hit path resolves without any network round trip.
@MainActor
final class PlaylistTracksCacheTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private func makeTrack(id: String) -> Track {
        Track(
            id: id,
            name: "Track \(id)",
            albumId: "alb-1",
            albumName: "Album",
            artistName: "Artist",
            artistId: "art-1",
            indexNumber: nil,
            discNumber: nil,
            year: nil,
            runtimeTicks: 1_000_000_000,
            isFavorite: false,
            playCount: 0,
            container: nil,
            bitrate: nil,
            imageTag: nil,
            playlistItemId: "pli-\(id)",
            userData: nil
        )
    }

    /// A cached playlist resolves into `currentPlaylistTracks` synchronously,
    /// without hitting the network — the fast path the detail view relies on
    /// when switching back to a playlist (unchanged by the `forceRefresh` add).
    func testLoadPlaylistTracksServesFromCacheWhenNotForced() async throws {
        let model = try AppModel()
        let cached = [makeTrack(id: "1"), makeTrack(id: "2")]
        model.playlistTracks["pl-1"] = cached
        model.currentPlaylistTracks = []

        await model.loadPlaylistTracks(playlistId: "pl-1")

        XCTAssertEqual(model.currentPlaylistTracks.map(\.id), ["1", "2"])
        // Cache untouched and no error raised on the happy cache-hit path.
        XCTAssertEqual(model.playlistTracks["pl-1"]?.map(\.id), ["1", "2"])
        XCTAssertNil(model.errorMessage)
    }

    /// `forceRefresh: true` must bypass the cache. Logged out, the underlying
    /// fetch fails, so the stale cache value is NOT promoted into
    /// `currentPlaylistTracks` — proving the early cache return was skipped.
    func testForceRefreshBypassesCache() async throws {
        let model = try AppModel()
        model.playlistTracks["pl-2"] = [makeTrack(id: "9")]
        model.currentPlaylistTracks = []

        await model.loadPlaylistTracks(playlistId: "pl-2", forceRefresh: true)

        // The cache short-circuit was skipped, so the (failed, logged-out)
        // fetch left currentPlaylistTracks empty rather than serving "9".
        XCTAssertTrue(model.currentPlaylistTracks.isEmpty)
    }
}
