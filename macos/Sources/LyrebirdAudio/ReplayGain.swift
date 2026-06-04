import AVFoundation
import Foundation
import os

private let replayGainLog = Logger(subsystem: "org.lyrebird.desktop", category: "replaygain")

/// Loudness-normalization mode mirrored from the app's `NormalizationMode`
/// preference. Kept local to `LyrebirdAudio` so the engine has no reverse
/// dependency on the `Lyrebird` app target — `AppModel` maps its
/// `@AppStorage("playback.normalization")` value onto this enum when it seeds
/// the engine. See issue #42.
public enum ReplayGainMode: String, Sendable {
    /// No gain is applied. The engine leaves `AVAudioMix` untouched so the
    /// player runs at the raw stream level.
    case off
    /// Use `REPLAYGAIN_TRACK_GAIN` (per-track loudness match).
    case track
    /// Use `REPLAYGAIN_ALBUM_GAIN`, preserving the relative levels of tracks
    /// within an album. Falls back to track gain when no album gain is tagged.
    case album
}

/// ReplayGain tag parsing + dB→linear conversion.
///
/// This is the **interim** normalization path for issue #42: rather than
/// rewriting the engine around `AVAudioEngine`, we read the loudness metadata
/// that already rides along with the stream (`AVAsset` exposes Vorbis comments,
/// iTunes atoms, and ID3 `TXXX` frames) and apply a single linear gain through
/// an `AVAudioMix` on the playing `AVPlayerItem`. When no usable tag is present
/// the resolver returns `nil` and the engine simply leaves the level alone — a
/// graceful no-op, never a volume change.
///
/// Everything except `gain(for:asset:)` is pure and side-effect free so the
/// parsing + math can be unit-tested without a live `AVAsset` or the network.
public enum ReplayGain {
    /// The loudness gains (in dB) parsed from a single item's metadata. Any
    /// field is `nil` when the corresponding tag was absent or unparseable.
    public struct Gains: Equatable, Sendable {
        /// `REPLAYGAIN_TRACK_GAIN`, in dB. Negative attenuates a loud track.
        public var trackGainDb: Double?
        /// `REPLAYGAIN_ALBUM_GAIN`, in dB.
        public var albumGainDb: Double?
        /// Best-effort dB derived from an iTunes `iTunNORM` atom, used only as
        /// a fallback when no ReplayGain tag is present.
        public var iTunNormDb: Double?

        public init(trackGainDb: Double? = nil, albumGainDb: Double? = nil, iTunNormDb: Double? = nil) {
            self.trackGainDb = trackGainDb
            self.albumGainDb = albumGainDb
            self.iTunNormDb = iTunNormDb
        }

        /// `true` when no loudness information of any kind was found.
        public var isEmpty: Bool {
            trackGainDb == nil && albumGainDb == nil && iTunNormDb == nil
        }
    }

    /// Hard clamp applied to the *total* gain (ReplayGain + pre-gain) before it
    /// is turned into a linear multiplier. ReplayGain payloads are occasionally
    /// garbage (e.g. a mis-scanned `+60 dB`); clamping keeps a bad tag from
    /// blowing the user's speakers or driving the output to silence. ±15 dB
    /// comfortably covers every legitimate ReplayGain value (real-world track
    /// gains sit within roughly ±12 dB) while still bounding the worst case.
    public static let maxAbsGainDb: Double = 15.0

    // MARK: - dB ↔ linear

    /// Convert a dB gain to a linear amplitude multiplier (`10^(dB/20)`).
    ///
    /// 0 dB → 1.0 (unchanged), −6 dB → ~0.501, +6 dB → ~1.995.
    public static func linearGain(fromDb db: Double) -> Float {
        Float(pow(10.0, db / 20.0))
    }

    // MARK: - Resolution

    /// Resolve the linear volume multiplier to hand to
    /// `AVAudioMixInputParameters.setVolume` for the given mode, parsed gains,
    /// and user pre-gain.
    ///
    /// Returns `nil` when normalization is off, or when the selected mode has
    /// no usable tag — the caller treats `nil` as "leave the level untouched"
    /// so an untagged track plays at its natural volume rather than being
    /// silently adjusted. The combined dB (ReplayGain + pre-gain) is clamped to
    /// ±``maxAbsGainDb`` before conversion.
    public static func linearVolume(
        mode: ReplayGainMode,
        gains: Gains,
        preGainDb: Double = 0
    ) -> Float? {
        guard mode != .off else { return nil }
        guard let replayGainDb = replayGainDb(mode: mode, gains: gains) else { return nil }
        let total = (replayGainDb + preGainDb).clamped(to: -maxAbsGainDb...maxAbsGainDb)
        return linearGain(fromDb: total)
    }

    /// Pick the ReplayGain dB value for `mode`, applying the documented
    /// fallbacks: album mode falls back to the track gain when no album gain is
    /// tagged; both modes fall back to the iTunNORM-derived value when no
    /// ReplayGain tag exists at all. `nil` when nothing usable is present.
    static func replayGainDb(mode: ReplayGainMode, gains: Gains) -> Double? {
        switch mode {
        case .off:
            return nil
        case .track:
            return gains.trackGainDb ?? gains.iTunNormDb
        case .album:
            // Preserve intra-album dynamics: prefer the album gain, but a file
            // tagged with only a track gain still normalizes sensibly.
            return gains.albumGainDb ?? gains.trackGainDb ?? gains.iTunNormDb
        }
    }

    // MARK: - Tag parsing

    /// Parse loudness gains from a flat list of `(key, value)` metadata pairs.
    ///
    /// Keys are matched case-insensitively and tolerate the `com.apple.iTunes.`
    /// namespace prefix that AVFoundation prepends to iTunes-atom ReplayGain
    /// tags, so all of these resolve to the track gain:
    ///   * `REPLAYGAIN_TRACK_GAIN`         (Vorbis comment / FLAC)
    ///   * `replaygain_track_gain`         (lower-case Vorbis variant)
    ///   * `com.apple.iTunes.replaygain_track_gain` (iTunes atom)
    ///   * ID3 `TXXX` descriptions surface with the same `REPLAYGAIN_*` text.
    ///
    /// Values like `"-7.60 dB"`, `"-7.60"`, or `"+3 dB"` all parse; the unit
    /// suffix and leading sign are tolerated. An `iTunNORM` atom is parsed as a
    /// best-effort fallback (see ``iTunNormDb(from:)``).
    public static func parseGains<S: StringProtocol>(
        from pairs: [(key: S, value: S)]
    ) -> Gains {
        var gains = Gains()
        for (rawKey, rawValue) in pairs {
            let key = normalizedKey(String(rawKey))
            let value = String(rawValue)
            switch key {
            case "replaygain_track_gain":
                if let db = parseGainDb(value) { gains.trackGainDb = db }
            case "replaygain_album_gain":
                if let db = parseGainDb(value) { gains.albumGainDb = db }
            case "itunnorm":
                if let db = iTunNormDb(from: value) { gains.iTunNormDb = db }
            default:
                continue
            }
        }
        return gains
    }

    /// Lower-cased key with the iTunes namespace prefix stripped so Vorbis,
    /// ID3, and iTunes spellings collapse onto one canonical token.
    private static func normalizedKey(_ key: String) -> String {
        var k = key.lowercased()
        let prefix = "com.apple.itunes."
        if k.hasPrefix(prefix) {
            k.removeFirst(prefix.count)
        }
        return k
    }

    /// Parse a ReplayGain dB string (`"-7.60 dB"`, `"+3"`, `"-7.60dB"`). The
    /// numeric prefix is taken up to the first non-numeric character so a
    /// trailing `" dB"` (or none) is handled uniformly. `nil` for a value with
    /// no leading number or a non-finite parse.
    static func parseGainDb(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var numeric = ""
        for (index, ch) in trimmed.enumerated() {
            if ch.isNumber || ch == "." {
                numeric.append(ch)
            } else if (ch == "+" || ch == "-") && index == 0 {
                numeric.append(ch)
            } else {
                break
            }
        }
        guard let value = Double(numeric), value.isFinite else { return nil }
        return value
    }

    /// Derive a best-effort dB adjustment from an iTunes `iTunNORM` atom.
    ///
    /// `iTunNORM` is a string of ten space-separated 8-digit hex values; the
    /// first two are the per-channel loudness measurements on a scale where
    /// `1000` ≈ 0 dB. The volume adjustment for a channel is
    /// `-10 * log10(value / 1000)` — a value above 1000 means a loud channel
    /// that should be attenuated. We take the *smaller-magnitude* (less
    /// aggressive) of the two channels so a single hot channel can't drive the
    /// whole track to silence, then clamp.
    ///
    /// This is intentionally a fallback only — `iTunNORM` is iTunes' own
    /// loudness scheme, not ReplayGain, and is less precise. `nil` when the
    /// atom is malformed or the channels read as zero.
    static func iTunNormDb(from raw: String) -> Double? {
        let fields = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2 else { return nil }
        guard
            let left = UInt32(fields[0], radix: 16),
            let right = UInt32(fields[1], radix: 16)
        else { return nil }
        guard left > 0, right > 0 else { return nil }
        let leftDb = -10.0 * log10(Double(left) / 1000.0)
        let rightDb = -10.0 * log10(Double(right) / 1000.0)
        // Less aggressive of the two channels (smaller absolute adjustment).
        let chosen = abs(leftDb) <= abs(rightDb) ? leftDb : rightDb
        guard chosen.isFinite else { return nil }
        return chosen.clamped(to: -maxAbsGainDb...maxAbsGainDb)
    }

    // MARK: - AVFoundation bridge

    /// Load `asset`'s metadata across every available format and parse the
    /// loudness gains out of it. Runs the async `AVAsset` metadata loads; safe
    /// to call off the main actor (it never touches `@MainActor` state).
    ///
    /// AVFoundation surfaces ReplayGain under format-specific metadata, not
    /// `commonMetadata`: Vorbis comments (`org.xiph.vorbis-comment`) carry the
    /// raw `REPLAYGAIN_*` keys, iTunes atoms (`com.apple.itunes`) carry the
    /// namespaced spelling plus `iTunNORM`, and ID3 `TXXX` frames carry the
    /// description text. We read them all and let ``parseGains(from:)`` sort
    /// the keys out. Returns empty `Gains` (never throws) on any failure so the
    /// caller falls back to "no adjustment".
    public static func gains(for asset: AVAsset) async -> Gains {
        var pairs: [(key: String, value: String)] = []
        do {
            let formats = try await asset.load(.availableMetadataFormats)
            for format in formats {
                let items = (try? await asset.loadMetadata(for: format)) ?? []
                for item in items {
                    guard let key = await metadataKey(of: item) else { continue }
                    // `load(.stringValue)` is `String?`; `try?` flattens the
                    // throwing+optional result to a single `String?`, so one
                    // optional-bind unwraps both the error and the nil case.
                    guard let value = try? await item.load(.stringValue) else { continue }
                    pairs.append((key: key, value: value))
                }
            }
        } catch {
            replayGainLog.debug("metadata load failed; treating as untagged: \(error.localizedDescription, privacy: .public)")
            return Gains()
        }
        return parseGains(from: pairs)
    }

    /// Best string identifier for a metadata item. Vorbis comments expose the
    /// raw tag name via `.key` (e.g. `REPLAYGAIN_TRACK_GAIN`); iTunes atoms
    /// expose it via `.identifier` (`itlk/com.apple.iTunes.iTunNORM`), so we
    /// fall back to the trailing path component of the identifier. Returns the
    /// canonical lookup token for ``parseGains(from:)``.
    private static func metadataKey(of item: AVMetadataItem) async -> String? {
        // `.key` is the unprocessed tag name for Vorbis/ID3 — exactly the
        // REPLAYGAIN_* / iTunNORM token we want.
        if let key = item.key as? String, !key.isEmpty {
            return key
        }
        if let key = item.key as? NSString {
            return key as String
        }
        // iTunes atoms expose the tag through the identifier's keyspace-scoped
        // string (e.g. `itlk/com.apple.iTunes.iTunNORM`). Take the part after
        // the last `/` so the namespace-prefixed token reaches the parser.
        if let identifier = item.identifier?.rawValue, let tail = identifier.split(separator: "/").last {
            return String(tail)
        }
        return nil
    }
}

private extension Comparable {
    /// Clamp `self` into `range`.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
