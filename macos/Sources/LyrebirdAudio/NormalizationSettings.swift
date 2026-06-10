import Foundation

/// User-facing loudness state for the Playback pane's two gain groups:
/// **Replay Gain** (Off / Track / Album + pre-gain) and **Volume
/// Normalization** (toggle + target loudness slider).
///
/// This is the single value type that flows from the Preferences pane through
/// `AppModel.setNormalization` onto both engine paths — the AVQueuePlayer
/// path applies it per item via `AVAudioMix` (`AudioEngine.applyReplayGain`),
/// the DSP path via each deck's player gain stage
/// (`EngineDSPPipeline.applyNormalization`) — and round-trips to
/// `UserDefaults` so the choice survives relaunch. Same shape as
/// `EqualizerSettings` / `CrossfadeSettings`.
///
/// Four facts persist:
/// - `mode` — which ReplayGain tag drives the per-track gain. Reuses the
///   pre-existing `playback.normalization` key the Playback pane has written
///   since the pane first shipped, so a value set before the engine support
///   landed is honoured unchanged.
/// - `preGainDb` — user adjustment summed on top of the resolved gain
///   (`playback.preGainDb`, ±12 dB).
/// - `volumeNormalizationEnabled` — whether playback loudness is shifted to
///   the user's target instead of the ReplayGain reference.
/// - `targetLoudnessDb` — the loudness target in dB LUFS (−23…−14; −18 is
///   the ReplayGain 2.0 reference, i.e. "no shift").
///
/// All-off (`mode == .off`, normalization toggle off) is a true no-op on
/// both paths: no `AVAudioMix` is installed and every deck gain stage sits
/// at unity, byte-for-byte the pre-existing output.
public struct NormalizationSettings: Equatable, Sendable {
    // MARK: - Ranges

    /// Pre-gain slider range in dB. Values outside it (hand-edited defaults)
    /// are clamped on load; the resolved *total* gain is additionally bounded
    /// by `ReplayGain.maxAbsGainDb` before conversion.
    public static let preGainRange: ClosedRange<Double> = -12...12

    /// Volume-normalization target range in dB LUFS. −23 (EBU R128 broadcast)
    /// through −14 (streaming-loudness territory); −18 — the ReplayGain 2.0
    /// reference — sits inside it as the "no shift" default.
    public static let targetRange: ClosedRange<Double> = -23 ... -14

    /// Default target: the ReplayGain reference itself, so enabling the
    /// toggle without touching the slider applies the tags exactly as the
    /// Replay Gain group would.
    public static let defaultTargetLoudnessDb: Double = ReplayGain.referenceLoudnessDb

    // MARK: - State

    /// Which ReplayGain tag drives the per-track gain. `.off` with the
    /// normalization toggle on falls back to track gains — a loudness target
    /// needs *some* per-track measurement, and the track tag is the only one
    /// the stream carries.
    public var mode: ReplayGainMode

    /// User pre-gain in dB, summed on top of the resolved gain. Only matters
    /// while some gain resolves at all (`isActive` and a usable tag).
    public var preGainDb: Double

    /// Whether playback loudness is shifted to `targetLoudnessDb` instead of
    /// the ReplayGain reference.
    public var volumeNormalizationEnabled: Bool

    /// Loudness target in dB LUFS. Clamped to `targetRange`.
    public var targetLoudnessDb: Double

    public init(
        mode: ReplayGainMode = .off,
        preGainDb: Double = 0,
        volumeNormalizationEnabled: Bool = false,
        targetLoudnessDb: Double = NormalizationSettings.defaultTargetLoudnessDb
    ) {
        self.mode = mode
        self.preGainDb = NormalizationSettings.normalizedPreGain(preGainDb)
        self.volumeNormalizationEnabled = volumeNormalizationEnabled
        self.targetLoudnessDb = NormalizationSettings.normalizedTarget(targetLoudnessDb)
    }

    /// Whether any gain resolution should run at all. `false` means both
    /// groups are off — the engines skip metadata reads and leave levels
    /// untouched.
    public var isActive: Bool {
        mode != .off || volumeNormalizationEnabled
    }

    // MARK: - Normalization

    /// Coerce an arbitrary persisted pre-gain into a valid one: zero
    /// non-finite values (a corrupted plist must never reach the gain math)
    /// and clamp to `preGainRange`.
    public static func normalizedPreGain(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        return min(max(raw, preGainRange.lowerBound), preGainRange.upperBound)
    }

    /// Coerce an arbitrary persisted target into a valid one: non-finite
    /// values fall back to the default, everything else clamps to
    /// `targetRange`.
    public static func normalizedTarget(_ raw: Double) -> Double {
        guard raw.isFinite else { return defaultTargetLoudnessDb }
        return min(max(raw, targetRange.lowerBound), targetRange.upperBound)
    }

    // MARK: - Resolution

    /// Resolve the linear volume multiplier for a track's parsed loudness
    /// tags under these settings. `nil` means "leave the level untouched" —
    /// both groups off, or no usable tag for the selected mode.
    public func linearVolume(gains: ReplayGain.Gains) -> Float? {
        ReplayGain.linearVolume(
            mode: mode,
            gains: gains,
            preGainDb: preGainDb,
            volumeNormalizationEnabled: volumeNormalizationEnabled,
            targetLoudnessDb: targetLoudnessDb
        )
    }

    // MARK: - Persistence

    /// `UserDefaults` keys. `mode` / `preGainDb` are the pre-existing
    /// Playback-pane keys (kept verbatim so prior choices survive); the
    /// volume-normalization pair is new with the Volume Normalization group.
    public enum DefaultsKey {
        public static let mode = "playback.normalization"
        public static let preGainDb = "playback.preGainDb"
        public static let volumeNormalizationEnabled = "playback.volumeNormalizationEnabled"
        public static let targetLoudnessDb = "playback.volumeNormalizationTargetDb"
    }

    /// Load persisted settings; missing/partial keys fall back to the shipped
    /// default (everything off, target at the reference) so a fresh install
    /// behaves exactly like the pre-existing output path.
    ///
    /// The target key needs an object probe: `double(forKey:)` returns `0`
    /// for a missing key, which `normalizedTarget` would clamp to −14 —
    /// silently shifting loudness for everyone who never touched the slider.
    public static func load(from defaults: UserDefaults) -> NormalizationSettings {
        let mode = defaults.string(forKey: DefaultsKey.mode)
            .flatMap(ReplayGainMode.init(rawValue:)) ?? .off
        let preGain = defaults.double(forKey: DefaultsKey.preGainDb)
        let enabled = defaults.bool(forKey: DefaultsKey.volumeNormalizationEnabled)
        let target: Double
        if defaults.object(forKey: DefaultsKey.targetLoudnessDb) != nil {
            target = defaults.double(forKey: DefaultsKey.targetLoudnessDb)
        } else {
            target = defaultTargetLoudnessDb
        }
        return NormalizationSettings(
            mode: mode,
            preGainDb: preGain,
            volumeNormalizationEnabled: enabled,
            targetLoudnessDb: target
        )
    }

    /// Persist all four facts as plist-native scalars so `defaults read`
    /// stays inspectable for support/debugging (same contract as the EQ and
    /// crossfade keys).
    public func save(to defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: DefaultsKey.mode)
        defaults.set(NormalizationSettings.normalizedPreGain(preGainDb), forKey: DefaultsKey.preGainDb)
        defaults.set(volumeNormalizationEnabled, forKey: DefaultsKey.volumeNormalizationEnabled)
        defaults.set(NormalizationSettings.normalizedTarget(targetLoudnessDb), forKey: DefaultsKey.targetLoudnessDb)
    }
}

/// The "Gapless playback" preference shared by both engine paths.
///
/// `AppModel.armNextTrackPreload` gates the AVQueuePlayer pre-insert on it,
/// and `AudioEngine.dspEnsurePipeline` seeds the DSP pipeline's buffered-join
/// arming from it — one key, one default-on contract, read here so the app
/// and engine layers can never drift.
public enum GaplessPreference {
    /// `UserDefaults` key, kept in sync with `PreferencesPlayback`'s
    /// `@AppStorage`.
    public static let defaultsKey = "playback.gaplessEnabled"

    /// Resolve the persisted flag, defaulting to `true` when the key has
    /// never been written. `bool(forKey:)` returns `false` for a missing
    /// key, which would silently invert the feature's "default on" contract
    /// (the toggle ships on), so probe for the object first.
    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return true }
        return defaults.bool(forKey: defaultsKey)
    }
}
