import Foundation

/// Single source of truth for track / runtime duration strings (#349).
///
/// Before this existed, ~7 call sites each hand-rolled `String(format: "%d:%02d", …)`
/// (AppModel's `Track.durationFormatted`, PlayerBar, NowPlayingView, QueueInspector,
/// AlbumDetailView, TrackInfoSheet) plus a one-off spelled-out VoiceOver string in
/// PlayerBar. Consolidating here keeps the visual form and the spoken form from
/// drifting, and gives both a single tested implementation.
///
/// Two intentionally-distinct outputs:
///
/// * ``colon(_:)`` — the *visual* form (`3:05`, `1:02:09`). It is deliberately
///   **locale-invariant**: the `:` separator and zero-padding are the universal
///   convention for media timecodes (Apple Music, QuickTime, every player ships
///   `mm:ss` regardless of region), so this does NOT route through
///   `Duration.TimeFormatStyle` — that style swaps separators per locale and
///   would make the timecode read differently across regions for no benefit.
///
/// * ``spokenAccessibility(_:)`` — the spelled-out form for `accessibilityValue`
///   ("3 minutes 5 seconds"). VoiceOver reading "three oh five" for `3:05` is
///   ambiguous; the spoken words match Apple Music / Podcasts. This mirrors the
///   rest of the app's hard-coded English a11y strings (e.g. the `play` /
///   `plays` count readouts).
///
/// All members are `nonisolated` + pure so the test target and any `@MainActor`
/// view can call them from any context without constructing an `AppModel`.
enum DurationFormatter {

    /// Normalize an arbitrary seconds value into a whole-second, non-negative
    /// `Int`. Guards `NaN` / `±inf` (an unloaded AVPlayer item reports `NaN`
    /// duration) and clamps negatives to zero so the formatters never emit
    /// `-1:59` or crash on a non-finite `Int(_:)` conversion.
    private static func wholeSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return max(0, Int(seconds.rounded()))
    }

    /// Locale-invariant timecode: `m:ss` under an hour, `h:mm:ss` at or past it.
    ///
    /// Examples: `0` → `"0:00"`, `5` → `"0:05"`, `185` → `"3:05"`,
    /// `3725` → `"1:02:05"`.
    static func colon(_ seconds: Double) -> String {
        colon(wholeSeconds: wholeSeconds(seconds))
    }

    /// Overload for call sites that already hold an integer second count derived
    /// from Jellyfin's 100-ns `runtimeTicks` (avoids a Double round-trip).
    static func colon(wholeSeconds total: Int) -> String {
        let safe = max(0, total)
        let h = safe / 3600
        let m = (safe % 3600) / 60
        let s = safe % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Spelled-out duration for VoiceOver `accessibilityValue`.
    ///
    /// Examples: `0` → `"0 seconds"`, `1` → `"1 second"`, `45` → `"45 seconds"`,
    /// `60` → `"1 minute"`, `185` → `"3 minutes 5 seconds"`,
    /// `3725` → `"1 hour 2 minutes 5 seconds"`. Zero-valued components are
    /// dropped (`"1 hour 5 seconds"` for `3605`) so the readout stays terse;
    /// singular / plural is handled per component.
    static func spokenAccessibility(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60

        var parts: [String] = []
        if h > 0 { parts.append(unit(h, singular: "hour", plural: "hours")) }
        if m > 0 { parts.append(unit(m, singular: "minute", plural: "minutes")) }
        // Always speak seconds when nothing larger is present (so `0` and small
        // sub-minute values still produce a value); otherwise only when nonzero.
        if s > 0 || parts.isEmpty {
            parts.append(unit(s, singular: "second", plural: "seconds"))
        }
        return parts.joined(separator: " ")
    }

    private static func unit(_ value: Int, singular: String, plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }
}
