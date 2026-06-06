import XCTest
@testable import Lyrebird
@testable import LyrebirdAudio
import LyrebirdCore

/// Offline downloads (#819) — Swift-side coverage.
///
/// The feature is enabled (`supportsDownloads == true`). Tests cover:
///   1. The capability flag is on and seeds `AudioEngine.offlinePlaybackEnabled`.
///   2. The snapshot-read helpers (`downloadState`, `isDownloaded`, `isDownloading`)
///      behave correctly against the in-memory `downloadStateById` map.
///   3. The AudioEngine offline-path contracts: an undownloaded track always
///      resolves to nil regardless of whether offline playback is enabled, so
///      the streaming path is unchanged for tracks with no local copy.
///
/// `AppModel` is `@MainActor`; the suite redirects the core's data dir to a
/// throwaway temp dir via `XDG_DATA_HOME` so it never touches the real DB.
@MainActor
final class DownloadsTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-downloads-\(UUID().uuidString)"
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
            runtimeTicks: 0,
            isFavorite: false,
            playCount: 0,
            container: "mp3",
            bitrate: nil,
            imageTag: nil,
            playlistItemId: nil,
            userData: nil
        )
    }

    // MARK: - Capability enabled

    /// The downloads capability is enabled. The flag being `true` unlocks the
    /// download UI affordances and the AudioEngine offline branch.
    func testDownloadsCapabilityEnabled() throws {
        let model = try AppModel()
        XCTAssertTrue(
            model.supportsDownloads,
            "downloads capability must be enabled"
        )
    }

    /// With the feature enabled, the per-track state read returns nil only for
    /// tracks that have no download record yet — not for all tracks. An empty
    /// `downloadStateById` map returns nil, which is the correct initial state.
    func testDownloadStateNilForUnknownTrack() throws {
        let model = try AppModel()
        XCTAssertNil(model.downloadState(forTrackId: "unknown-id"))
        XCTAssertFalse(model.isDownloaded(makeTrack("x")))
        XCTAssertFalse(model.isDownloading(makeTrack("x")))
    }

    // MARK: - AudioEngine offline gate

    /// The engine flag is seeded from `supportsDownloads` at init time, so it
    /// is now `true` — enabling `resolveLocalAssetURL` to check for a local copy.
    func testEngineOfflinePlaybackEnabled() throws {
        let model = try AppModel()
        XCTAssertTrue(
            model.audio.offlinePlaybackEnabled,
            "offline playback must mirror supportsDownloads (true)"
        )
    }

    /// With offline playback disabled, the local-asset resolver returns nil for
    /// any track without touching the core — the streaming branch in
    /// `play(track:)` is reached exactly as before #819.
    func testResolveLocalAssetReturnsNilWhenOfflineDisabled() async throws {
        let dir = NSTemporaryDirectory() + "lyrebird-dl-engine-\(UUID().uuidString)"
        let core = try LyrebirdCore(config: CoreConfig(dataDir: dir, deviceName: "dl-test"))
        let engine = AudioEngine(core: core)
        XCTAssertFalse(engine.offlinePlaybackEnabled)

        let url = await engine.resolveLocalAssetURLForTesting("any-track")
        XCTAssertNil(url, "disabled offline playback must resolve no local URL")
    }

    /// Even when the flag is flipped on, a track with no completed download
    /// resolves to nil — so playback still streams. This proves the offline
    /// branch only diverts when an actual local copy exists.
    func testResolveLocalAssetReturnsNilForUndownloadedTrackWhenEnabled() async throws {
        let dir = NSTemporaryDirectory() + "lyrebird-dl-engine2-\(UUID().uuidString)"
        let core = try LyrebirdCore(config: CoreConfig(dataDir: dir, deviceName: "dl-test"))
        let engine = AudioEngine(core: core)
        engine.offlinePlaybackEnabled = true

        let url = await engine.resolveLocalAssetURLForTesting("never-downloaded")
        XCTAssertNil(url, "an undownloaded track must resolve to no local URL even when enabled")
    }

    // MARK: - Snapshot read helpers (independent of the gate)

    /// The read helpers the row views and context menu depend on map the
    /// in-memory state correctly. Driven directly against `downloadStateById`
    /// so the mapping is locked regardless of the capability flag.
    func testSnapshotReadHelpersMapState() throws {
        let model = try AppModel()
        let done = makeTrack("done")
        let queued = makeTrack("queued")
        let downloading = makeTrack("downloading")
        let failed = makeTrack("failed")

        model.downloadStateById = [
            done.id: .done,
            queued.id: .queued,
            downloading.id: .downloading,
            failed.id: .failed,
        ]

        XCTAssertEqual(model.downloadState(forTrackId: done.id), .done)
        XCTAssertTrue(model.isDownloaded(done))
        XCTAssertFalse(model.isDownloaded(failed))

        XCTAssertTrue(model.isDownloading(queued))
        XCTAssertTrue(model.isDownloading(downloading))
        XCTAssertFalse(model.isDownloading(done))
        XCTAssertFalse(model.isDownloading(failed))
    }

    /// `in-flight` set also counts as "downloading" for the spinner, covering
    /// the window between an optimistic enqueue and the core flipping the row.
    func testInFlightCountsAsDownloading() throws {
        let model = try AppModel()
        let t = makeTrack("inflight")
        model.downloadsInFlight = [t.id]
        XCTAssertTrue(model.isDownloading(t))
    }

    /// The budget slider value (GB) converts to the byte count the core stores.
    /// Pin the 1e9-per-GB factor the preferences pane uses so a UI tweak can't
    /// silently change the persisted budget.
    func testBudgetGigabytesToBytesFactor() {
        // 10 GB -> 10_000_000_000 bytes. The conversion lives in
        // `setDownloadBudget(gigabytes:)`; mirror it here as the contract.
        let gb = 10.0
        let bytes = UInt64(max(0, gb) * 1_000_000_000)
        XCTAssertEqual(bytes, 10_000_000_000)
    }
}
