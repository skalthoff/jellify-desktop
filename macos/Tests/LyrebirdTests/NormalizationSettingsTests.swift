import AVFoundation
import XCTest

@testable import Lyrebird
@testable import LyrebirdAudio
import LyrebirdCore

/// Coverage for the Playback pane's loudness + gapless wiring:
///
///   1. `NormalizationSettings` value semantics — pre-gain / target clamps,
///      non-finite sanitizing, the all-off `isActive` contract.
///   2. `UserDefaults` persistence round-trips on the pre-existing
///      `playback.normalization` / `playback.preGainDb` keys plus the new
///      volume-normalization pair — including the missing-target-key probe
///      (a bare `double(forKey:)` would read 0 and clamp to −14, silently
///      shifting loudness for everyone who never touched the slider).
///   3. The volume-normalization gain math — the target shift on top of the
///      tag gain, the track-tag fallback when Replay Gain is off, and the
///      total clamp.
///   4. `GaplessPreference` — default-on for a missing key, persisted
///      opt-out honoured, and `AppModel.gaplessEnabled` delegating to it.
///   5. `EngineDSPPipeline` integration — gapless arming with crossfade off,
///      disarm rules when either transition feature turns off, and the
///      per-deck player gain stage driven by `provideLoudnessGains` /
///      `applyNormalization` (stash-then-load and loaded-deck paths).
@MainActor
final class NormalizationSettingsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    /// Standard-domain keys the engine / preference layer read directly;
    /// scrubbed around every test so suites sharing `UserDefaults.standard`
    /// stay hermetic.
    private let standardKeys = [
        NormalizationSettings.DefaultsKey.mode,
        NormalizationSettings.DefaultsKey.preGainDb,
        NormalizationSettings.DefaultsKey.volumeNormalizationEnabled,
        NormalizationSettings.DefaultsKey.targetLoudnessDb,
        GaplessPreference.defaultsKey,
    ]

    override func setUp() {
        super.setUp()
        suiteName = "normalization-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        for key in standardKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        for key in standardKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: - 1. Value semantics

    func testShippedDefaultIsAllOff() {
        let settings = NormalizationSettings()
        XCTAssertEqual(settings.mode, .off)
        XCTAssertEqual(settings.preGainDb, 0)
        XCTAssertFalse(settings.volumeNormalizationEnabled)
        XCTAssertEqual(settings.targetLoudnessDb, ReplayGain.referenceLoudnessDb)
        XCTAssertFalse(settings.isActive, "everything-off must be inactive — no metadata reads, no gain")
    }

    func testIsActiveForEitherKnob() {
        XCTAssertTrue(NormalizationSettings(mode: .track).isActive)
        XCTAssertTrue(NormalizationSettings(volumeNormalizationEnabled: true).isActive)
        XCTAssertTrue(NormalizationSettings(mode: .album, volumeNormalizationEnabled: true).isActive)
    }

    func testInitClampsAndSanitizes() {
        XCTAssertEqual(NormalizationSettings(preGainDb: 99).preGainDb, 12, "pre-gain clamps to the slider ceiling")
        XCTAssertEqual(NormalizationSettings(preGainDb: -99).preGainDb, -12)
        XCTAssertEqual(NormalizationSettings(preGainDb: .nan).preGainDb, 0, "NaN pre-gain must never reach the gain math")
        XCTAssertEqual(NormalizationSettings(targetLoudnessDb: -5).targetLoudnessDb, -14, "target clamps to the loud end")
        XCTAssertEqual(NormalizationSettings(targetLoudnessDb: -40).targetLoudnessDb, -23, "target clamps to the quiet end")
        XCTAssertEqual(
            NormalizationSettings(targetLoudnessDb: .infinity).targetLoudnessDb,
            NormalizationSettings.defaultTargetLoudnessDb,
            "non-finite target falls back to the reference"
        )
    }

    func testReferenceSitsInsideTargetRange() {
        XCTAssertTrue(
            NormalizationSettings.targetRange.contains(NormalizationSettings.defaultTargetLoudnessDb),
            "the no-shift default must be reachable on the slider"
        )
    }

    // MARK: - 2. Persistence

    func testRoundTrip() {
        let saved = NormalizationSettings(
            mode: .album,
            preGainDb: 3,
            volumeNormalizationEnabled: true,
            targetLoudnessDb: -16
        )
        saved.save(to: defaults)
        let loaded = NormalizationSettings.load(from: defaults)
        XCTAssertEqual(loaded, saved)
    }

    func testLoadFromEmptyDomainYieldsDefaults() {
        let loaded = NormalizationSettings.load(from: defaults)
        XCTAssertEqual(loaded, NormalizationSettings(), "missing keys must read as the shipped default")
    }

    /// The regression this suite exists for: with the toggle persisted but
    /// the target key never written, `double(forKey:)` reads 0 — which the
    /// clamp would turn into −14 (a +4 dB loudness shift). The loader must
    /// probe for the object and fall back to the reference instead.
    func testMissingTargetKeyReadsReferenceNotClampedZero() {
        defaults.set(true, forKey: NormalizationSettings.DefaultsKey.volumeNormalizationEnabled)
        let loaded = NormalizationSettings.load(from: defaults)
        XCTAssertEqual(
            loaded.targetLoudnessDb,
            ReplayGain.referenceLoudnessDb,
            "an unset target must mean no shift, not the clamp of 0"
        )
    }

    func testLoadSanitizesGarbage() {
        defaults.set("definitely-not-a-mode", forKey: NormalizationSettings.DefaultsKey.mode)
        defaults.set(Double.nan, forKey: NormalizationSettings.DefaultsKey.preGainDb)
        defaults.set(-99.0, forKey: NormalizationSettings.DefaultsKey.targetLoudnessDb)
        let loaded = NormalizationSettings.load(from: defaults)
        XCTAssertEqual(loaded.mode, .off, "unknown mode raw must fall back, not crash")
        XCTAssertEqual(loaded.preGainDb, 0)
        XCTAssertEqual(loaded.targetLoudnessDb, -23, "out-of-range target clamps on load")
    }

    func testSaveNormalizesOutOfRangeValues() {
        var settings = NormalizationSettings()
        settings.preGainDb = 40 // bypass init normalization
        settings.targetLoudnessDb = -2
        settings.save(to: defaults)
        XCTAssertEqual(defaults.double(forKey: NormalizationSettings.DefaultsKey.preGainDb), 12)
        XCTAssertEqual(defaults.double(forKey: NormalizationSettings.DefaultsKey.targetLoudnessDb), -14)
    }

    // MARK: - 3. Volume-normalization gain math

    private let taggedGains = ReplayGain.Gains(trackGainDb: -6, albumGainDb: -4)

    func testTargetShiftAddsOnTopOfTagGain() {
        // Track tag −6 dB, target −14 (reference −18) ⇒ shift +4 ⇒ total −2.
        let volume = ReplayGain.linearVolume(
            mode: .track,
            gains: taggedGains,
            volumeNormalizationEnabled: true,
            targetLoudnessDb: -14
        )
        XCTAssertEqual(volume ?? .nan, ReplayGain.linearGain(fromDb: -2), accuracy: 1e-6)
    }

    func testTargetAtReferenceIsPureReplayGain() {
        let shifted = ReplayGain.linearVolume(
            mode: .album,
            gains: taggedGains,
            volumeNormalizationEnabled: true,
            targetLoudnessDb: ReplayGain.referenceLoudnessDb
        )
        let plain = ReplayGain.linearVolume(mode: .album, gains: taggedGains)
        XCTAssertEqual(shifted ?? .nan, plain ?? .nan, accuracy: 1e-9, "−18 target must be a no-shift")
    }

    func testNormalizationWithModeOffFallsBackToTrackGain() {
        // Replay Gain off + normalization on: the target needs a measurement,
        // so the track tag drives it. −6 dB tag, −23 target ⇒ shift −5 ⇒ −11.
        let volume = ReplayGain.linearVolume(
            mode: .off,
            gains: taggedGains,
            volumeNormalizationEnabled: true,
            targetLoudnessDb: -23
        )
        XCTAssertEqual(volume ?? .nan, ReplayGain.linearGain(fromDb: -11), accuracy: 1e-6)
    }

    func testAllOffResolvesNil() {
        XCTAssertNil(ReplayGain.linearVolume(mode: .off, gains: taggedGains))
        XCTAssertNil(NormalizationSettings().linearVolume(gains: taggedGains))
    }

    func testNormalizationOnUntaggedTrackIsNoOp() {
        let volume = ReplayGain.linearVolume(
            mode: .off,
            gains: ReplayGain.Gains(),
            volumeNormalizationEnabled: true,
            targetLoudnessDb: -14
        )
        XCTAssertNil(volume, "no tag ⇒ leave the level untouched, never a blind boost")
    }

    func testClampIncludesTargetShift() {
        // +12 tag + 4 shift + 6 pre-gain = 22 ⇒ clamps at +15.
        let volume = ReplayGain.linearVolume(
            mode: .track,
            gains: ReplayGain.Gains(trackGainDb: 12),
            preGainDb: 6,
            volumeNormalizationEnabled: true,
            targetLoudnessDb: -14
        )
        XCTAssertEqual(volume ?? .nan, ReplayGain.linearGain(fromDb: ReplayGain.maxAbsGainDb), accuracy: 1e-6)
    }

    func testSettingsLinearVolumeMatchesFreeFunction() {
        let settings = NormalizationSettings(
            mode: .track,
            preGainDb: 2,
            volumeNormalizationEnabled: true,
            targetLoudnessDb: -16
        )
        XCTAssertEqual(
            settings.linearVolume(gains: taggedGains) ?? .nan,
            ReplayGain.linearVolume(
                mode: .track,
                gains: taggedGains,
                preGainDb: 2,
                volumeNormalizationEnabled: true,
                targetLoudnessDb: -16
            ) ?? .nan,
            accuracy: 1e-9
        )
    }

    // MARK: - 4. Gapless preference

    func testGaplessDefaultsOnWhenKeyUnset() {
        XCTAssertNil(UserDefaults.standard.object(forKey: GaplessPreference.defaultsKey))
        XCTAssertTrue(GaplessPreference.isEnabled(), "an unset gapless key must read on")
    }

    func testGaplessHonoursPersistedOff() {
        UserDefaults.standard.set(false, forKey: GaplessPreference.defaultsKey)
        XCTAssertFalse(GaplessPreference.isEnabled())
    }

    /// `AppModel.gaplessEnabled` (the queue-side gate) must read the same
    /// source as the engine's pipeline seeding, so the two paths can never
    /// disagree about the toggle.
    func testAppModelGateDelegatesToSharedPreference() {
        XCTAssertEqual(AppModel.gaplessEnabled, GaplessPreference.isEnabled())
        UserDefaults.standard.set(false, forKey: GaplessPreference.defaultsKey)
        XCTAssertEqual(AppModel.gaplessEnabled, GaplessPreference.isEnabled())
        XCTAssertFalse(AppModel.gaplessEnabled)
    }

    // MARK: - 5. Pipeline integration

    private func armedTrack(key: String, albumKey: String? = nil) -> EngineDSPPipeline.ArmedNextTrack {
        EngineDSPPipeline.ArmedNextTrack(
            key: key,
            albumKey: albumKey,
            url: URL(fileURLWithPath: "/dev/null"),
            authHeader: nil,
            containerHint: nil,
            durationHint: 180,
            mediaSourceId: nil,
            playSessionId: nil
        )
    }

    /// A bare pipeline ships with gapless off (the pre-existing rebuild
    /// transition), and the gapless knob alone — crossfade still off — must
    /// accept an arm for the buffered zero-fade join.
    func testGaplessArmsWithCrossfadeOff() {
        let pipeline = EngineDSPPipeline()
        XCTAssertFalse(pipeline.transitionArmingEnabled, "bare pipeline must preserve rebuild transitions")

        pipeline.armNextTrack(armedTrack(key: "next"))
        XCTAssertNil(pipeline.armedTrackKeyForTesting, "no transition feature on ⇒ arming stays a no-op")

        pipeline.applyGapless(true)
        XCTAssertTrue(pipeline.transitionArmingEnabled)
        XCTAssertFalse(pipeline.crossfadeIsEnabled, "gapless must not report as crossfade")

        pipeline.armNextTrack(armedTrack(key: "next"))
        XCTAssertEqual(pipeline.armedTrackKeyForTesting, "next", "gapless on ⇒ the join arms without crossfade")
    }

    /// Turning gapless off disarms a pending join — unless crossfade still
    /// wants the standby deck for an overlap of its own.
    func testGaplessOffDisarmsUnlessCrossfadeHoldsTheArm() {
        let pipeline = EngineDSPPipeline()
        pipeline.applyGapless(true)
        pipeline.armNextTrack(armedTrack(key: "next"))
        XCTAssertEqual(pipeline.armedTrackKeyForTesting, "next")

        pipeline.applyGapless(false)
        XCTAssertNil(pipeline.armedTrackKeyForTesting, "gapless off with crossfade off must drop the join")

        pipeline.applyGapless(true)
        pipeline.applyCrossfade(CrossfadeSettings(durationSeconds: 4))
        pipeline.armNextTrack(armedTrack(key: "next2"))
        pipeline.applyGapless(false)
        XCTAssertEqual(pipeline.armedTrackKeyForTesting, "next2", "crossfade on must keep the arm alive")
    }

    /// The mirror rule: crossfade turning off keeps the arm while gapless
    /// still wants the zero-fade join.
    func testCrossfadeOffKeepsArmWhileGaplessOn() {
        let pipeline = EngineDSPPipeline()
        pipeline.applyGapless(true)
        pipeline.applyCrossfade(CrossfadeSettings(durationSeconds: 4))
        pipeline.armNextTrack(armedTrack(key: "next"))

        pipeline.applyCrossfade(CrossfadeSettings(durationSeconds: 0))
        XCTAssertEqual(pipeline.armedTrackKeyForTesting, "next", "gapless must hold the buffered join")

        pipeline.applyGapless(false)
        XCTAssertNil(pipeline.armedTrackKeyForTesting, "both off ⇒ nothing may stay armed")
    }

    /// Per-deck loudness: tags provided for a loaded track drive that deck's
    /// player gain stage, settings changes recompute from the cached tags,
    /// and all-off snaps back to unity. The deck loads from a dead file URL —
    /// `load` records the track key synchronously and the streamer's async
    /// failure never resets the gain stage.
    func testProvideGainsDrivesDeckPlayerGain() {
        let pipeline = EngineDSPPipeline()
        pipeline.applyNormalization(NormalizationSettings(mode: .track))
        XCTAssertEqual(pipeline.deckPlayerGainsForTesting, [1, 1], "no tags yet ⇒ unity")

        pipeline.load(url: URL(fileURLWithPath: "/dev/null"), authHeader: nil, trackKey: "t1")
        pipeline.provideLoudnessGains(ReplayGain.Gains(trackGainDb: -6), forTrackKey: "t1")

        let expected = ReplayGain.linearGain(fromDb: -6)
        XCTAssertEqual(pipeline.deckPlayerGainsForTesting[0], expected, accuracy: 1e-6)

        // Mode flip mid-track: pure math on the cached tags, no re-fetch.
        pipeline.applyNormalization(NormalizationSettings(mode: .track, preGainDb: 2))
        XCTAssertEqual(pipeline.deckPlayerGainsForTesting[0], ReplayGain.linearGain(fromDb: -4), accuracy: 1e-6)

        pipeline.applyNormalization(NormalizationSettings())
        XCTAssertEqual(pipeline.deckPlayerGainsForTesting, [1, 1], "all-off must restore unity")
    }

    /// Tags that arrive before their track is loaded (the armed next track)
    /// stash and apply at load; unloading resets the stage to unity.
    func testStashedGainsApplyAtLoadAndResetOnReload() {
        let pipeline = EngineDSPPipeline()
        pipeline.applyNormalization(NormalizationSettings(mode: .track))

        pipeline.provideLoudnessGains(ReplayGain.Gains(trackGainDb: -3), forTrackKey: "t1")
        XCTAssertEqual(pipeline.pendingLoudnessGainsCountForTesting, 1, "early tags must stash, not vanish")
        XCTAssertEqual(pipeline.deckPlayerGainsForTesting, [1, 1])

        pipeline.load(url: URL(fileURLWithPath: "/dev/null"), authHeader: nil, trackKey: "t1")
        XCTAssertEqual(pipeline.pendingLoudnessGainsCountForTesting, 0, "load must consume the stash")
        XCTAssertEqual(pipeline.deckPlayerGainsForTesting[0], ReplayGain.linearGain(fromDb: -3), accuracy: 1e-6)

        // A new track on the same deck with no tags must not inherit t1's gain.
        pipeline.load(url: URL(fileURLWithPath: "/dev/null"), authHeader: nil, trackKey: "t2")
        XCTAssertEqual(pipeline.deckPlayerGainsForTesting, [1, 1], "loudness is per-track state")
    }

    /// The engine seeds a freshly built pipeline from the persisted gapless
    /// preference (default on) and its live loudness knobs — the same
    /// construct-then-restore contract as the EQ and crossfade.
    func testEnginePipelineConstructionSeedsGaplessAndNormalization() throws {
        let dir = NSTemporaryDirectory() + "lyrebird-normalization-\(UUID().uuidString)"
        let core = try LyrebirdCore(config: CoreConfig(dataDir: dir, deviceName: "normalization-test"))
        let engine = AudioEngine(core: core)
        engine.dspPipelineEnabled = true
        engine.normalizationMode = .track
        engine.setVolume(0.5) // cheapest pipeline-constructing call; never starts audio

        let pipeline = try XCTUnwrap(engine.dspPipeline)
        XCTAssertTrue(pipeline.gaplessEnabled, "unset preference must seed the pipeline default-on")
        XCTAssertTrue(pipeline.transitionArmingEnabled, "gapless alone must enable arming")

        // The seeded settings must be live: a tagged track picks up the gain.
        pipeline.load(url: URL(fileURLWithPath: "/dev/null"), authHeader: nil, trackKey: "t1")
        pipeline.provideLoudnessGains(ReplayGain.Gains(trackGainDb: -6), forTrackKey: "t1")
        XCTAssertEqual(pipeline.deckPlayerGainsForTesting[0], ReplayGain.linearGain(fromDb: -6), accuracy: 1e-6)
    }

    /// With the preference persisted off, the engine seeds the pipeline
    /// disarmed — each track ends cleanly before the next is built.
    func testEnginePipelineConstructionHonoursGaplessOff() throws {
        UserDefaults.standard.set(false, forKey: GaplessPreference.defaultsKey)
        let dir = NSTemporaryDirectory() + "lyrebird-normalization-\(UUID().uuidString)"
        let core = try LyrebirdCore(config: CoreConfig(dataDir: dir, deviceName: "normalization-test"))
        let engine = AudioEngine(core: core)
        engine.dspPipelineEnabled = true
        engine.setVolume(0.5)

        let pipeline = try XCTUnwrap(engine.dspPipeline)
        XCTAssertFalse(pipeline.gaplessEnabled)
        XCTAssertFalse(pipeline.transitionArmingEnabled)
    }
}
