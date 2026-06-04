import XCTest
@testable import Lyrebird
@testable import LyrebirdAudio
import LyrebirdCore

@MainActor
final class AudioEnginePreloadTests: XCTestCase {
    private func makeEngine() throws -> AudioEngine {
        // Build a real (un-authed) core against a throwaway data dir, same
        // pattern as MiniPlayerStateTests. The off-main resolve fails fast
        // without touching the network.
        let dir = NSTemporaryDirectory() + "lyrebird-preload-\(UUID().uuidString)"
        let core = try LyrebirdCore(config: CoreConfig(dataDir: dir, deviceName: "preload-test"))
        let engine = AudioEngine(core: core)
        engine.installEmptyPlayerForTesting()
        return engine
    }

    private func makeTrack(_ id: String) -> Track {
        Track(
            id: id,
            name: "t-\(id)",
            albumId: nil,
            albumName: nil,
            artistName: "",
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

    /// The PlaybackInfo / streamUrl / authHeader resolution must run off the
    /// main actor: `preloadNextTrack` dispatches the FFI into a detached task
    /// and returns immediately, so no item can be spliced into the queue
    /// synchronously on the caller's thread. If the resolution ran inline this
    /// would block until the (un-authed) resolve threw — and on success it
    /// would have mutated the queue before returning.
    func testPreloadDoesNotMutateQueueSynchronously() throws {
        let engine = try makeEngine()
        XCTAssertEqual(engine.queuedItemCountForTesting, 0)

        engine.preloadNextTrack(makeTrack("a"))

        // Control returned to the main actor with the queue still untouched —
        // the resolve is happening off-main.
        XCTAssertEqual(engine.queuedItemCountForTesting, 0)
    }

    /// Rapid back-to-back preloads (e.g. skip-next, or `onTrackEnded` firing
    /// again) must not deadlock or crash, and must not synchronously enqueue.
    /// The generation guard ensures only the latest in-flight resolve can ever
    /// win the marshal-back, so a stale resolution can't clobber the queue.
    func testConcurrentPreloadsDoNotEnqueueSynchronously() throws {
        let engine = try makeEngine()

        engine.preloadNextTrack(makeTrack("a"))
        engine.preloadNextTrack(makeTrack("b"))

        XCTAssertEqual(engine.queuedItemCountForTesting, 0)
    }

    /// Stall recovery rebuilds the current item via `replaceCurrentItem`,
    /// which drops any pre-loaded next-track item. The owner needs a
    /// post-recovery signal to re-arm gapless playback, so `recoverFromStall`
    /// must fire `audioEngineDidRecover()` after restarting playback.
    func testStallRecoveryFiresDidRecoverDelegate() throws {
        let engine = try makeEngine()
        let spy = RecoverySpy()
        engine.delegate = spy

        engine.recoverFromStallForTesting(url: URL(string: "https://example.invalid/stream")!)

        XCTAssertEqual(spy.didRecoverCount, 1)
    }
}

@MainActor
private final class RecoverySpy: AudioEngineDelegate {
    var didRecoverCount = 0
    func audioEngineDidStall() {}
    func audioEngineDidFail(_ message: String) {}
    func audioEngineDidRecover() { didRecoverCount += 1 }
}

/// #931 — gapless must engage on a *normal* queue advance, not just stall
/// recovery. `AppModel.handleTrackEnded` advances the queue and rebuilds the
/// player via `play(track:)` (a fresh single-item `AVQueuePlayer`), which drops
/// any pre-inserted next item. The advance must therefore re-arm the engine's
/// pre-load for the track *after* the new current one — selecting it with the
/// same precedence stall recovery uses (user-added "Up Next" over the
/// auto-queue tail).
///
/// These exercise the production arming step directly (`armNextTrackPreload`,
/// surfaced for tests as `armNextTrackPreloadForTesting`) rather than the async
/// `play(track:)` path, which throws against the un-authed test core before the
/// arm would run. The engine records the armed track id before its off-main
/// stream resolve, so we can assert the *intent* without a network round-trip.
///
/// `AppModel` is `@MainActor`; constructing it boots a live `LyrebirdCore`. We
/// redirect the core's data dir to a throwaway temp dir via `XDG_DATA_HOME`
/// (honoured by `storage::default_data_dir()`) so tests never touch the real
/// app database — same pattern as `AutoplayWhenQueueEndsTests`.
@MainActor
final class AppModelAdvancePreloadTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-advance-preload-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private func makeTrack(_ id: String) -> Track {
        Track(
            id: id,
            name: "t-\(id)",
            albumId: nil,
            albumName: nil,
            artistName: "",
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

    /// A normal advance arms the engine pre-load for the head of the auto-queue
    /// tail when there is no user-added "Up Next". Without the #931 wiring the
    /// freshly built player would carry no queued-ahead item and the engine's
    /// `lastPreloadedTrackIdForTesting` would stay nil.
    func testAdvanceArmsPreloadFromAutoQueueTail() throws {
        let model = try AppModel()
        model.audio.installEmptyPlayerForTesting()
        model.upNextAutoQueue = [Queue(track: makeTrack("auto-next"))]

        model.armNextTrackPreloadForTesting()

        XCTAssertEqual(
            model.audio.lastPreloadedTrackIdForTesting,
            "auto-next",
            "advance must pre-load the next auto-queue track for gapless playback"
        )
    }

    /// User-added "Up Next" wins over the auto-queue tail — the engine advances
    /// through explicit queue entries first, so the pre-loaded item must match.
    func testAdvancePrefersUserAddedOverAutoQueue() throws {
        let model = try AppModel()
        model.audio.installEmptyPlayerForTesting()
        model.upNextUserAdded = [Queue(track: makeTrack("user-next"))]
        model.upNextAutoQueue = [Queue(track: makeTrack("auto-next"))]

        model.armNextTrackPreloadForTesting()

        XCTAssertEqual(
            model.audio.lastPreloadedTrackIdForTesting,
            "user-next",
            "user-added Up Next must take precedence over the auto-queue tail"
        )
    }

    /// At the end of the queue (nothing user-added, empty tail) there is no
    /// next track to arm, so the advance must leave the engine pre-load
    /// untouched rather than re-arming a stale item.
    func testAdvanceAtEndOfQueueArmsNothing() throws {
        let model = try AppModel()
        model.audio.installEmptyPlayerForTesting()
        model.upNextUserAdded = []
        model.upNextAutoQueue = []

        model.armNextTrackPreloadForTesting()

        XCTAssertNil(
            model.audio.lastPreloadedTrackIdForTesting,
            "no upcoming track means nothing to pre-load at end of queue"
        )
    }
}
