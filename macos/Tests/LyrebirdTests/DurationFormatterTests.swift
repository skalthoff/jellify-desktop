import XCTest

@testable import Lyrebird
@testable import LyrebirdCore

/// Coverage for the shared `DurationFormatter` (#349) and the two `Track`
/// conveniences that route through it.
///
/// `DurationFormatter` is pure + `nonisolated`, so every case is exercised
/// directly without realizing a SwiftUI view or an `AppModel`. Two distinct
/// outputs are under test:
///   * `colon(_:)` — the locale-invariant visual timecode (`3:05`, `1:02:05`).
///   * `spokenAccessibility(_:)` — the spelled-out VoiceOver value
///     ("3 minutes 5 seconds").
final class DurationFormatterTests: XCTestCase {

    // MARK: - colon(_:) visual timecode

    func testColonZero() {
        XCTAssertEqual(DurationFormatter.colon(0), "0:00")
    }

    func testColonSubMinutePadsSeconds() {
        // 5 seconds reads "0:05", not "0:5" — the seconds field is zero-padded.
        XCTAssertEqual(DurationFormatter.colon(5), "0:05")
        XCTAssertEqual(DurationFormatter.colon(9), "0:09")
    }

    func testColonExactMinuteHasZeroSeconds() {
        XCTAssertEqual(DurationFormatter.colon(60), "1:00")
        XCTAssertEqual(DurationFormatter.colon(600), "10:00")
    }

    func testColonMinutesAndSeconds() {
        XCTAssertEqual(DurationFormatter.colon(185), "3:05")
        XCTAssertEqual(DurationFormatter.colon(599), "9:59")
    }

    func testColonRollsOverToHoursAtAndPastOneHour() {
        // The minutes field zero-pads only once the hour field appears, so a
        // 1h02m05s runtime reads "1:02:05" rather than "62:05".
        XCTAssertEqual(DurationFormatter.colon(3600), "1:00:00")
        XCTAssertEqual(DurationFormatter.colon(3725), "1:02:05")
        XCTAssertEqual(DurationFormatter.colon(7384), "2:03:04")
    }

    func testColonRoundsToNearestSecond() {
        // 184.6s rounds up to 185 → "3:05"; 184.4 rounds down to "3:04".
        XCTAssertEqual(DurationFormatter.colon(184.6), "3:05")
        XCTAssertEqual(DurationFormatter.colon(184.4), "3:04")
    }

    func testColonGuardsNonFiniteAndNegative() {
        // An unloaded AVPlayer item reports NaN duration; negatives are clamped.
        XCTAssertEqual(DurationFormatter.colon(.nan), "0:00")
        XCTAssertEqual(DurationFormatter.colon(.infinity), "0:00")
        XCTAssertEqual(DurationFormatter.colon(-5), "0:00")
    }

    func testColonWholeSecondsOverloadClampsNegative() {
        XCTAssertEqual(DurationFormatter.colon(wholeSeconds: 185), "3:05")
        XCTAssertEqual(DurationFormatter.colon(wholeSeconds: -1), "0:00")
        XCTAssertEqual(DurationFormatter.colon(wholeSeconds: 3725), "1:02:05")
    }

    // MARK: - spokenAccessibility(_:) VoiceOver value

    func testSpokenZeroIsZeroSeconds() {
        // A value is always produced, even at zero, so the label is never empty.
        XCTAssertEqual(DurationFormatter.spokenAccessibility(0), "0 seconds")
    }

    func testSpokenSingularSecond() {
        XCTAssertEqual(DurationFormatter.spokenAccessibility(1), "1 second")
    }

    func testSpokenPluralSecondsOnly() {
        XCTAssertEqual(DurationFormatter.spokenAccessibility(45), "45 seconds")
    }

    func testSpokenSingularMinuteDropsZeroSeconds() {
        // A whole minute drops the "0 seconds" tail.
        XCTAssertEqual(DurationFormatter.spokenAccessibility(60), "1 minute")
    }

    func testSpokenPluralMinutesOnly() {
        XCTAssertEqual(DurationFormatter.spokenAccessibility(120), "2 minutes")
    }

    func testSpokenMinutesAndSeconds() {
        XCTAssertEqual(DurationFormatter.spokenAccessibility(185), "3 minutes 5 seconds")
    }

    func testSpokenMinuteAndSingularSecond() {
        XCTAssertEqual(DurationFormatter.spokenAccessibility(61), "1 minute 1 second")
    }

    func testSpokenHoursMinutesSeconds() {
        XCTAssertEqual(
            DurationFormatter.spokenAccessibility(3725),
            "1 hour 2 minutes 5 seconds"
        )
    }

    func testSpokenHourDropsZeroComponents() {
        // 1h flat → "1 hour"; 1h05s → "1 hour 5 seconds" (zero minutes dropped).
        XCTAssertEqual(DurationFormatter.spokenAccessibility(3600), "1 hour")
        XCTAssertEqual(DurationFormatter.spokenAccessibility(3605), "1 hour 5 seconds")
    }

    func testSpokenPluralHours() {
        XCTAssertEqual(DurationFormatter.spokenAccessibility(7200), "2 hours")
    }

    func testSpokenGuardsNonFinite() {
        XCTAssertEqual(DurationFormatter.spokenAccessibility(.nan), "0 seconds")
        XCTAssertEqual(DurationFormatter.spokenAccessibility(-5), "0 seconds")
    }

    // MARK: - Track conveniences

    /// `runtimeTicks` is Jellyfin's 100-ns count: seconds * 10_000_000.
    private func makeTrack(runtimeTicks: UInt64) -> Track {
        Track(
            id: "t1",
            name: "Song",
            albumId: nil,
            albumName: nil,
            artistName: "Artist",
            artistId: nil,
            indexNumber: nil,
            discNumber: nil,
            year: nil,
            runtimeTicks: runtimeTicks,
            isFavorite: false,
            playCount: 0,
            container: nil,
            bitrate: nil,
            imageTag: nil,
            playlistItemId: nil,
            userData: nil
        )
    }

    func testTrackDurationFormattedRoutesThroughColon() {
        // 185s = 1_850_000_000 ticks → "3:05".
        let track = makeTrack(runtimeTicks: 1_850_000_000)
        XCTAssertEqual(track.durationFormatted, "3:05")
    }

    func testTrackDurationAccessibilityValueRoutesThroughSpoken() {
        let track = makeTrack(runtimeTicks: 1_850_000_000)
        XCTAssertEqual(track.durationAccessibilityValue, "3 minutes 5 seconds")
    }

    func testTrackZeroRuntimeFormatsAsZero() {
        let track = makeTrack(runtimeTicks: 0)
        XCTAssertEqual(track.durationFormatted, "0:00")
        XCTAssertEqual(track.durationAccessibilityValue, "0 seconds")
    }

    func testTrackHourLongRuntime() {
        // 1h02m05s = 3725s = 37_250_000_000 ticks.
        let track = makeTrack(runtimeTicks: 37_250_000_000)
        XCTAssertEqual(track.durationFormatted, "1:02:05")
        XCTAssertEqual(track.durationAccessibilityValue, "1 hour 2 minutes 5 seconds")
    }
}
