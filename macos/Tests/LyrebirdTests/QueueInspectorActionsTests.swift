import XCTest
import LyrebirdCore

@testable import Lyrebird

/// Coverage for the Queue Inspector's mutating actions on `AppModel`
/// (#79 / #80 / #282 / #284):
///
///  * `removeFromUpNext(id:)` removes a single addressable instance by its
///    per-queue `id`, so a track queued twice loses only the tapped row.
///  * `shuffleUpNext()` honours the short-list guard and preserves the set of
///    queued tracks (only their order may change).
///  * `queueJumpPlan(for:)` — the pure index resolver behind the
///    double-click "jump to track" gesture — flattens the three inspector
///    sections into play order and lands `startIndex` on the right slot,
///    correctly accounting for the currently-playing track occupying slot 0.
///
/// `AppModel` is `@MainActor` and boots a live `LyrebirdCore`; we redirect the
/// core data dir to a throwaway temp dir via `XDG_DATA_HOME` so tests never
/// touch the real database (mirrors `SessionPlayHistoryTests` /
/// `MiniPlayerStateTests`). The reorder/remove actions also call
/// `core.setQueue`; with no authenticated session that FFI is a no-op or a
/// caught throw — the Swift overlay mutation under test still happens, so the
/// state assertions remain deterministic.
@MainActor
final class QueueInspectorActionsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    // MARK: - Fixtures

    private func makeTrack(_ id: String) -> Track {
        Track(
            id: id,
            name: "t-\(id)",
            albumId: nil,
            albumName: nil,
            artistName: "a-\(id)",
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

    private func status(currentTrack: Track?) -> PlayerStatus {
        PlayerStatus(
            state: currentTrack == nil ? .idle : .playing,
            currentTrack: currentTrack,
            positionSeconds: 0,
            durationSeconds: 0,
            volume: 1,
            queuePosition: 0,
            queueLength: 0,
            shuffle: false,
            repeatMode: .off,
            playSessionId: nil
        )
    }

    // MARK: - removeFromUpNext

    func testRemoveFromUpNextDropsTheTargetedInstanceOnly() throws {
        let model = try AppModel()
        let keepA = Queue(track: makeTrack("a"))
        let drop = Queue(track: makeTrack("b"))
        let keepC = Queue(track: makeTrack("c"))
        model.upNextUserAdded = [keepA, drop, keepC]

        model.removeFromUpNext(id: drop.id)

        XCTAssertEqual(
            model.upNextUserAdded.map(\.id),
            [keepA.id, keepC.id],
            "only the entry whose queueId was passed should be removed"
        )
    }

    /// The whole reason `Queue` carries a per-instance `id` distinct from
    /// `track.id`: the same track queued twice must be individually
    /// removable. Removing one instance must leave the other in place.
    func testRemoveFromUpNextRemovesOneOfTwoIdenticalTracks() throws {
        let model = try AppModel()
        let first = Queue(track: makeTrack("dup"))
        let second = Queue(track: makeTrack("dup"))
        model.upNextUserAdded = [first, second]

        model.removeFromUpNext(id: first.id)

        XCTAssertEqual(
            model.upNextUserAdded.map(\.id),
            [second.id],
            "removing one instance of a doubly-queued track must keep the other"
        )
        XCTAssertEqual(model.upNextUserAdded.first?.track.id, "dup")
    }

    func testRemoveFromUpNextWithUnknownIdIsANoOp() throws {
        let model = try AppModel()
        let a = Queue(track: makeTrack("a"))
        model.upNextUserAdded = [a]

        model.removeFromUpNext(id: UUID())

        XCTAssertEqual(model.upNextUserAdded.map(\.id), [a.id])
    }

    // MARK: - shuffleUpNext

    /// One item (or none) is a no-op — the guard keeps the order stable so a
    /// single-item queue doesn't churn the core queue for nothing.
    func testShuffleUpNextNoOpsBelowTwoItems() throws {
        let model = try AppModel()
        let only = Queue(track: makeTrack("a"))
        model.upNextUserAdded = [only]

        model.shuffleUpNext()

        XCTAssertEqual(model.upNextUserAdded.map(\.id), [only.id])
    }

    /// Shuffle may reorder but must never add, drop, or mutate entries — the
    /// multiset of queued tracks is invariant under shuffle.
    func testShuffleUpNextPreservesTheSetOfEntries() throws {
        let model = try AppModel()
        let entries = (0..<12).map { Queue(track: makeTrack("t\($0)")) }
        model.upNextUserAdded = entries

        model.shuffleUpNext()

        XCTAssertEqual(
            Set(model.upNextUserAdded.map(\.id)),
            Set(entries.map(\.id)),
            "shuffle must preserve exactly the same queue entries"
        )
        XCTAssertEqual(model.upNextUserAdded.count, entries.count)
    }

    // MARK: - queueJumpPlan (double-click "jump to track")

    /// With a track playing, the current track sits at index 0, so the first
    /// auto-queue entry resolves to index (1 + userAdded.count).
    func testJumpPlanAccountsForCurrentTrackAtSlotZero() throws {
        let model = try AppModel()
        model.status = status(currentTrack: makeTrack("now"))
        let up1 = Queue(track: makeTrack("u1"))
        let up2 = Queue(track: makeTrack("u2"))
        let auto1 = Queue(track: makeTrack("a1"))
        let auto2 = Queue(track: makeTrack("a2"))
        model.upNextUserAdded = [up1, up2]
        model.upNextAutoQueue = [auto1, auto2]

        let plan = try XCTUnwrap(model.queueJumpPlan(for: auto2.id))

        // Flattened order: [now, u1, u2, a1, a2] → a2 is index 4.
        XCTAssertEqual(plan.startIndex, 4)
        XCTAssertEqual(plan.tracks.map(\.id), ["now", "u1", "u2", "a1", "a2"])
        XCTAssertEqual(plan.tracks[plan.startIndex].id, "a2")
    }

    /// A double-click on a user-added row also resolves — jump isn't limited
    /// to the auto tail.
    func testJumpPlanResolvesUserAddedEntry() throws {
        let model = try AppModel()
        model.status = status(currentTrack: makeTrack("now"))
        let up1 = Queue(track: makeTrack("u1"))
        let up2 = Queue(track: makeTrack("u2"))
        model.upNextUserAdded = [up1, up2]

        let plan = try XCTUnwrap(model.queueJumpPlan(for: up2.id))

        // [now, u1, u2] → u2 is index 2.
        XCTAssertEqual(plan.startIndex, 2)
        XCTAssertEqual(plan.tracks[plan.startIndex].id, "u2")
    }

    /// With nothing playing there's no slot-0 offset, so the first auto entry
    /// is index 0.
    func testJumpPlanWithoutCurrentTrackHasNoOffset() throws {
        let model = try AppModel()
        model.status = status(currentTrack: nil)
        let auto1 = Queue(track: makeTrack("a1"))
        let auto2 = Queue(track: makeTrack("a2"))
        model.upNextAutoQueue = [auto1, auto2]

        let plan = try XCTUnwrap(model.queueJumpPlan(for: auto1.id))

        XCTAssertEqual(plan.startIndex, 0)
        XCTAssertEqual(plan.tracks.map(\.id), ["a1", "a2"])
    }

    func testJumpPlanReturnsNilForUnknownEntry() throws {
        let model = try AppModel()
        model.status = status(currentTrack: makeTrack("now"))
        model.upNextAutoQueue = [Queue(track: makeTrack("a1"))]

        XCTAssertNil(
            model.queueJumpPlan(for: UUID()),
            "an id not present in any queue section must resolve to nil"
        )
    }
}
