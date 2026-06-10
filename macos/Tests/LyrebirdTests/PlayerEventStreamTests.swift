import XCTest

@preconcurrency import LyrebirdCore

@testable import Lyrebird

/// Coverage for the push-based player status surface (#433): the
/// `PlayerEventBridge` subscription that replaced the 1 Hz `core.status()`
/// poll, the stale-sequence drop rule, and the track-change side-effect
/// bookkeeping that used to live in the poll tick.
///
/// `AppModel` is `@MainActor`, so the whole suite is main-actor isolated.
/// Constructing it boots a live `LyrebirdCore`; the core's data directory is
/// redirected to a throwaway temp dir via `XDG_DATA_HOME` (honoured by
/// `storage::default_data_dir()`) so tests never touch the real app's
/// database. No session is required — the player FFIs are local state.
@MainActor
final class PlayerEventStreamTests: XCTestCase {

    /// Point the core at a unique temp data dir before the first `AppModel()`
    /// in the process — same pattern as `AutoplayWhenQueueEndsTests`.
    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private func makeTrack(_ id: String) -> Track {
        Track(
            id: id,
            name: "t-\(id)",
            albumId: nil,
            albumName: nil,
            artistName: "Artist",
            artistId: nil,
            indexNumber: nil,
            discNumber: nil,
            year: nil,
            runtimeTicks: 1_800_000_000,
            isFavorite: false,
            playCount: 0,
            container: nil,
            bitrate: nil,
            imageTag: nil,
            playlistItemId: nil,
            userData: nil
        )
    }

    private func makeStatus(
        state: PlaybackState,
        track: Track?,
        position: Double = 0,
        queuePosition: UInt32 = 0,
        queueLength: UInt32 = 0
    ) -> PlayerStatus {
        PlayerStatus(
            state: state,
            currentTrack: track,
            positionSeconds: position,
            durationSeconds: 180,
            volume: 1.0,
            queuePosition: queuePosition,
            queueLength: queueLength,
            shuffle: false,
            repeatMode: .off,
            playSessionId: nil
        )
    }

    /// Let the bridge's `Task { @MainActor in … }` hops run until `predicate`
    /// holds (or the deadline passes). The test itself is main-actor bound,
    /// so suspension via `Task.sleep` is what gives the queued hops a turn.
    private func drainMainActor(
        timeout: TimeInterval = 2,
        until predicate: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - End-to-end: core mutation -> push -> status

    /// A core-side player mutation must land on `model.status` with no
    /// polling: the registered bridge receives the push and applies it on
    /// the main actor.
    func testCoreMutationIsPushedIntoStatus() async throws {
        let model = try AppModel()
        model.startStatusEventStream()
        defer { model.stopStatusEventStream() }

        XCTAssertNil(model.status.currentTrack, "fresh core starts trackless")

        _ = try model.core.setQueue(tracks: [makeTrack("a"), makeTrack("b")], startIndex: 0)
        model.core.markTrackStarted(track: makeTrack("a"))

        await drainMainActor { model.status.currentTrack?.id == "a" }
        XCTAssertEqual(model.status.currentTrack?.id, "a")
        XCTAssertEqual(model.status.state, .playing)
        XCTAssertEqual(model.status.queueLength, 2)

        model.core.markState(state: .paused)
        await drainMainActor { model.status.state == .paused }
        XCTAssertEqual(
            model.status.state, .paused,
            "a state transition must be pushed without any poll"
        )
    }

    /// After `stopStatusEventStream`, further core mutations must not move
    /// the reactive surface.
    func testStoppedStreamGoesSilent() async throws {
        let model = try AppModel()
        model.startStatusEventStream()

        model.core.markState(state: .playing)
        await drainMainActor { model.status.state == .playing }
        XCTAssertEqual(model.status.state, .playing)

        model.stopStatusEventStream()
        model.core.markState(state: .paused)
        // Deliberately give a (nonexistent) push time to arrive.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            model.status.state, .playing,
            "no pushes may arrive after the stream is stopped"
        )
        XCTAssertNil(model.playerEventBridge)
    }

    // MARK: - Stale-sequence drop rule

    /// Pushes hop to the main actor as individual `Task`s, so delivery
    /// order is not guaranteed even though sequence numbers are stamped in
    /// mutation order. An older snapshot arriving late must be dropped, not
    /// applied over newer state.
    func testStaleSequenceIsDropped() throws {
        let model = try AppModel()

        model.applyPlayerEvent(
            seq: 5,
            kinds: [.stateChanged],
            status: makeStatus(state: .playing, track: makeTrack("a"))
        )
        XCTAssertEqual(model.status.state, .playing)

        // Late-delivered older push: must be ignored entirely.
        model.applyPlayerEvent(
            seq: 3,
            kinds: [.stateChanged],
            status: makeStatus(state: .paused, track: makeTrack("a"))
        )
        XCTAssertEqual(
            model.status.state, .playing,
            "an older seq must never overwrite newer state"
        )

        // Equal seq (duplicate delivery): also dropped.
        model.applyPlayerEvent(
            seq: 5,
            kinds: [.stateChanged],
            status: makeStatus(state: .stopped, track: nil)
        )
        XCTAssertEqual(model.status.state, .playing)

        // Strictly newer: applies.
        model.applyPlayerEvent(
            seq: 6,
            kinds: [.stateChanged],
            status: makeStatus(state: .paused, track: makeTrack("a"))
        )
        XCTAssertEqual(model.status.state, .paused)
    }

    // MARK: - Track-change side effects (the old poll-tick body)

    /// A push that drops the current track (stop / queue exhausted) must
    /// clear the Now Playing detail state, exactly like the old poll's
    /// track-change hook did.
    func testTrackTeardownClearsNowPlayingDetails() throws {
        let model = try AppModel()

        model.applyPlayerEvent(
            seq: 1,
            kinds: [.stateChanged, .trackChanged],
            status: makeStatus(state: .playing, track: makeTrack("a"))
        )
        // Simulate details fetched for the playing track.
        model.currentTrackPeople = [Person(name: "P", type: "Composer", id: nil)]
        model.currentTrackPeopleForId = "a"
        model.currentLyrics = [LyricLine(id: 0, timestamp: nil, text: "la")]
        model.currentLyricsForId = "a"

        model.applyPlayerEvent(
            seq: 2,
            kinds: [.stateChanged, .trackChanged, .queueChanged],
            status: makeStatus(state: .stopped, track: nil)
        )

        XCTAssertTrue(model.currentTrackPeople.isEmpty)
        XCTAssertNil(model.currentTrackPeopleForId)
        XCTAssertNil(model.currentLyrics)
        XCTAssertNil(model.currentLyricsForId)
    }

    /// A track-to-track transition must record the *outgoing* track onto the
    /// in-session history (#81) — and a same-track push must not.
    func testTrackChangeRecordsSessionHistory() throws {
        let model = try AppModel()

        model.applyPlayerEvent(
            seq: 1,
            kinds: [.trackChanged],
            status: makeStatus(state: .playing, track: makeTrack("a"))
        )
        XCTAssertTrue(
            model.sessionPlayHistory.isEmpty,
            "start-from-stopped has no outgoing track to record"
        )

        model.applyPlayerEvent(
            seq: 2,
            kinds: [.trackChanged],
            status: makeStatus(state: .playing, track: makeTrack("b"))
        )
        XCTAssertEqual(model.sessionPlayHistory.map(\.id), ["a"])

        // Same track again (e.g. an inline refresh raced the push): the
        // before/after diff suppresses a duplicate history entry.
        model.applyPlayerEvent(
            seq: 3,
            kinds: [.stateChanged],
            status: makeStatus(state: .paused, track: makeTrack("b"))
        )
        XCTAssertEqual(model.sessionPlayHistory.map(\.id), ["a"])
    }

    // MARK: - Position ticks

    /// The 1 Hz engine tick must advance `status.positionSeconds` directly
    /// (no FFI, no event) — and must not resurrect a position after the
    /// track was torn down.
    func testPositionTickAdvancesPositionOnlyWhileTrackLoaded() throws {
        let model = try AppModel()

        model.applyPlayerEvent(
            seq: 1,
            kinds: [.trackChanged, .stateChanged],
            status: makeStatus(state: .playing, track: makeTrack("a"))
        )
        model.handlePositionTick(seconds: 42.5)
        XCTAssertEqual(model.status.positionSeconds, 42.5)

        model.applyPlayerEvent(
            seq: 2,
            kinds: [.stateChanged, .trackChanged],
            status: makeStatus(state: .stopped, track: nil)
        )
        model.handlePositionTick(seconds: 99)
        XCTAssertEqual(
            model.status.positionSeconds, 0,
            "a stale tick must not write onto a stopped surface"
        )
    }

    /// Seeks mirror their target onto the reactive surface immediately —
    /// while paused there is no time-observer tick to do it, and with the
    /// poll gone nothing else would.
    func testSeekMirrorsPositionWhilePaused() throws {
        let model = try AppModel()

        model.applyPlayerEvent(
            seq: 1,
            kinds: [.trackChanged, .stateChanged],
            status: makeStatus(state: .playing, track: makeTrack("a"))
        )
        model.applyPlayerEvent(
            seq: 2,
            kinds: [.stateChanged],
            status: makeStatus(state: .paused, track: makeTrack("a"), position: 10)
        )

        model.seek(toSeconds: 90)
        XCTAssertEqual(
            model.status.positionSeconds, 90,
            "paused seek must update the UI position without waiting for a tick"
        )
        XCTAssertEqual(
            model.core.status().positionSeconds, 90,
            "the core's bookkeeping must agree with the surface after a seek"
        )
    }
}
