import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for drag-to-reorder of tracks inside a playlist (#73 / #235).
///
/// Two surfaces:
///   * `PlaylistReorderPayload` — the pure `"<index>|<trackId>"` drag-payload
///     codec. The source index is what makes a *duplicated* track move
///     correctly, so the codec is pinned independently of the model.
///   * `AppModel.applyPlaylistDrop(playlistId:sourceIndex:destinationIndex:)` —
///     the index-addressed drop path. The regression it fixes: when the same
///     track id appears more than once in a playlist, resolving the moved row
///     by id alone always grabs the *first* copy, so dragging a later copy
///     moved the wrong one. Routing by index moves the exact copy grabbed.
///
/// `AppModel` is `@MainActor` and boots a live `LyrebirdCore`; we redirect the
/// core's data dir to a throwaway temp via `XDG_DATA_HOME` (the same hermetic
/// setup `AutoplayWhenQueueEndsTests` uses) so the test never touches the real
/// app DB. The drop only mutates the in-memory `playlistTracks` cache
/// synchronously before kicking off the (here unauthenticated, harmless)
/// server round-trip, so the local-order assertions are deterministic.
@MainActor
final class PlaylistReorderHandleTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    // MARK: - Payload codec

    func testPayloadEncodeJoinsIndexAndId() {
        XCTAssertEqual(PlaylistReorderPayload.encode(index: 3, trackId: "abc"), "3|abc")
    }

    func testPayloadDecodeSplitsIndexAndId() {
        let parsed = PlaylistReorderPayload.decode("3|abc")
        XCTAssertEqual(parsed.sourceIndex, 3)
        XCTAssertEqual(parsed.trackId, "abc")
    }

    func testPayloadEncodeDecodeRoundTrip() {
        let parsed = PlaylistReorderPayload.decode(
            PlaylistReorderPayload.encode(index: 0, trackId: "track-xyz")
        )
        XCTAssertEqual(parsed.sourceIndex, 0)
        XCTAssertEqual(parsed.trackId, "track-xyz")
    }

    /// A track id that itself contains a `|` must survive: only the *first*
    /// separator delimits the index, so the id keeps its remaining pipes.
    func testPayloadDecodeSplitsOnlyOnFirstSeparator() {
        let parsed = PlaylistReorderPayload.decode("5|weird|id|with|pipes")
        XCTAssertEqual(parsed.sourceIndex, 5)
        XCTAssertEqual(parsed.trackId, "weird|id|with|pipes")
    }

    /// A legacy payload that's a bare track id (no separator) decodes with a
    /// nil index so the caller falls back to id-based resolution.
    func testPayloadDecodeBareIdYieldsNilIndex() {
        let parsed = PlaylistReorderPayload.decode("just-an-id")
        XCTAssertNil(parsed.sourceIndex)
        XCTAssertEqual(parsed.trackId, "just-an-id")
    }

    /// A non-integer leading segment is not a valid index, so it falls back to
    /// the id path rather than silently moving row 0.
    func testPayloadDecodeNonIntegerIndexYieldsNilIndex() {
        let parsed = PlaylistReorderPayload.decode("notanumber|abc")
        XCTAssertNil(parsed.sourceIndex)
        XCTAssertEqual(parsed.trackId, "abc")
    }

    // MARK: - applyPlaylistDrop (index-addressed) — duplicate-track fix

    /// The regression: a playlist with the *same* track id at two positions.
    /// Dragging the second copy (index 2) to the front must move *that* copy,
    /// identified by its distinct `playlistItemId`, not the first copy at
    /// index 0. The id-based path would have moved index 0 instead.
    func testApplyPlaylistDropByIndexMovesTheGrabbedDuplicate() throws {
        let model = try AppModel()
        let playlistId = "pl-dup"
        // Order: A(dup, item-1), B(item-2), A(dup, item-3)
        model.playlistTracks[playlistId] = [
            track(id: "A", playlistItemId: "item-1"),
            track(id: "B", playlistItemId: "item-2"),
            track(id: "A", playlistItemId: "item-3"),
        ]

        // Drag the *second* "A" (index 2) to the top (destination 0).
        model.applyPlaylistDrop(playlistId: playlistId, sourceIndex: 2, destinationIndex: 0)

        let result = model.playlistTracks[playlistId] ?? []
        // The moved copy must be item-3 (the one the user grabbed), landing
        // first — item-1 stays put relative to B.
        XCTAssertEqual(result.map(\.playlistItemId), ["item-3", "item-1", "item-2"])
        XCTAssertEqual(result.map(\.id), ["A", "A", "B"])
    }

    /// The first copy moves independently of the second when *it* is grabbed.
    func testApplyPlaylistDropByIndexMovesFirstDuplicateToEnd() throws {
        let model = try AppModel()
        let playlistId = "pl-dup2"
        model.playlistTracks[playlistId] = [
            track(id: "A", playlistItemId: "item-1"),
            track(id: "B", playlistItemId: "item-2"),
            track(id: "A", playlistItemId: "item-3"),
        ]

        // Drag the *first* "A" (index 0) to the end (destination 3 = past last).
        model.applyPlaylistDrop(playlistId: playlistId, sourceIndex: 0, destinationIndex: 3)

        let result = model.playlistTracks[playlistId] ?? []
        XCTAssertEqual(result.map(\.playlistItemId), ["item-2", "item-3", "item-1"])
    }

    /// An out-of-range source index (e.g. a stale snapshot from a list that
    /// mutated mid-drag) is a safe no-op rather than a move of the wrong row.
    func testApplyPlaylistDropByIndexIgnoresOutOfRangeIndex() throws {
        let model = try AppModel()
        let playlistId = "pl-oob"
        let original = [
            track(id: "A", playlistItemId: "item-1"),
            track(id: "B", playlistItemId: "item-2"),
        ]
        model.playlistTracks[playlistId] = original

        model.applyPlaylistDrop(playlistId: playlistId, sourceIndex: 9, destinationIndex: 0)

        XCTAssertEqual(model.playlistTracks[playlistId]?.map(\.playlistItemId),
                       original.map(\.playlistItemId),
                       "an out-of-range source index must leave the order untouched")
    }

    // MARK: - Fixture

    private func track(id: String, playlistItemId: String) -> Track {
        Track(
            id: id,
            name: "Track \(id)",
            albumId: nil,
            albumName: nil,
            artistName: "Artist",
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
            playlistItemId: playlistItemId,
            userData: nil
        )
    }
}
