import XCTest

@testable import Lyrebird

/// Coverage for the pure value logic behind the Library filter popover (#214):
/// format-container matching, duration bucketing, and the active-group count
/// that drives the pink dot on the filter icon. These are deliberately
/// `AppModel`-free — the per-item `passesFilter` predicates that consult the
/// model live on `LibraryView`; here we lock down the standalone primitives.
final class LibraryFilterTests: XCTestCase {

    // MARK: - TrackFormat

    func testFlacMatchesOnlyFlacContainer() {
        XCTAssertTrue(TrackFormat.flac.matches(container: "flac"))
        XCTAssertTrue(TrackFormat.flac.matches(container: "FLAC"))
        XCTAssertFalse(TrackFormat.flac.matches(container: "mp3"))
        XCTAssertFalse(TrackFormat.flac.matches(container: nil))
        XCTAssertFalse(TrackFormat.flac.matches(container: "  "))
    }

    func testAlacMatchesM4aAndMp4Containers() {
        // Jellyfin ships ALAC inside an m4a/mp4 container, so both spellings
        // plus the codec name itself must count.
        XCTAssertTrue(TrackFormat.alac.matches(container: "m4a"))
        XCTAssertTrue(TrackFormat.alac.matches(container: "MP4"))
        XCTAssertTrue(TrackFormat.alac.matches(container: "alac"))
        XCTAssertFalse(TrackFormat.alac.matches(container: "flac"))
    }

    func testAlacAndAacShareTheM4aMp4Container() {
        // ALAC and AAC both live in m4a/mp4; the loaded Track payload has no
        // codec field, so the filter can only match at container granularity.
        // Both formats therefore match the shared containers — selecting either
        // keeps every m4a/mp4 track. This is the deliberate (documented)
        // limitation; it replaces the old behaviour where ALAC silently kept
        // lossy AAC files while pretending to be codec-accurate.
        for container in ["m4a", "MP4", "M4B"] {
            XCTAssertTrue(
                TrackFormat.alac.matches(container: container),
                "ALAC should match \(container)")
            XCTAssertTrue(
                TrackFormat.aac.matches(container: container),
                "AAC should match \(container)")
        }
        // Lossless FLAC is a distinct container and must not be swept in.
        XCTAssertFalse(TrackFormat.aac.matches(container: "flac"))
        XCTAssertFalse(TrackFormat.alac.matches(container: "flac"))
    }

    func testAacIsAnOfferedFormat() {
        XCTAssertTrue(TrackFormat.allCases.contains(.aac))
    }

    func testMp3MatchesMpegSpelling() {
        XCTAssertTrue(TrackFormat.mp3.matches(container: "mp3"))
        XCTAssertTrue(TrackFormat.mp3.matches(container: "MPEG"))
        // mp3 is its own container and must not collide with the m4a family.
        XCTAssertFalse(TrackFormat.mp3.matches(container: "m4a"))
    }

    // MARK: - DurationBucket

    func testDurationBucketBoundaries() {
        // < 3m
        XCTAssertTrue(DurationBucket.short.matches(seconds: 179))
        XCTAssertFalse(DurationBucket.short.matches(seconds: 180))
        // 3–6m inclusive on both ends
        XCTAssertTrue(DurationBucket.medium.matches(seconds: 180))
        XCTAssertTrue(DurationBucket.medium.matches(seconds: 360))
        XCTAssertFalse(DurationBucket.medium.matches(seconds: 179))
        XCTAssertFalse(DurationBucket.medium.matches(seconds: 361))
        // > 6m
        XCTAssertTrue(DurationBucket.long.matches(seconds: 361))
        XCTAssertFalse(DurationBucket.long.matches(seconds: 360))
    }

    func testDurationBucketsArePartition() {
        // Every positive runtime falls in exactly one bucket.
        for seconds in stride(from: 0.0, through: 1200.0, by: 7.0) {
            let hits = DurationBucket.allCases.filter { $0.matches(seconds: seconds) }
            XCTAssertEqual(hits.count, 1, "seconds=\(seconds) hit \(hits.count) buckets")
        }
    }

    // MARK: - LibraryFilter.activeGroupCount

    func testEmptyFilterIsInactive() {
        let f = LibraryFilter()
        XCTAssertFalse(f.isActive)
        XCTAssertEqual(f.activeGroupCount, 0)
    }

    func testActiveGroupCountCountsEachGroupOnce() {
        var f = LibraryFilter()
        f.genres = ["Rock", "Jazz"]   // one group despite two selections
        f.formats = [.flac, .mp3]     // one group despite two selections
        XCTAssertEqual(f.activeGroupCount, 2)
        XCTAssertTrue(f.isActive)

        f.onlyFavorited = true
        f.yearRange = 1990...2000
        f.durations = [.short]
        XCTAssertEqual(f.activeGroupCount, 5)
    }

    /// `onlyDownloaded` must NOT count toward the active-group total: no
    /// `passesFilter` overload can honor it until a download-state query
    /// exists, and the toggle is UI-gated off, so counting it would light the
    /// dot badge and trip the no-results path while filtering nothing. See
    /// audit L724.
    func testOnlyDownloadedDoesNotMarkFilterActive() {
        var f = LibraryFilter()
        f.onlyDownloaded = true
        XCTAssertEqual(
            f.activeGroupCount, 0,
            "onlyDownloaded is inert until a download-state query lands; it must not count as an active group"
        )
        XCTAssertFalse(
            f.isActive,
            "a filter whose only set flag is the unhonorable onlyDownloaded must read as inactive"
        )
    }

    func testOnlyDownloadedDoesNotInflateAlongsideRealGroups() {
        var f = LibraryFilter()
        f.onlyFavorited = true
        f.genres = ["Rock"]
        let withoutDownloaded = f.activeGroupCount
        f.onlyDownloaded = true
        XCTAssertEqual(
            f.activeGroupCount, withoutDownloaded,
            "toggling the inert onlyDownloaded flag must not change the active-group count"
        )
    // MARK: - Per-tab applicability

    func testGenreAppliesOnlyToAlbumsAndArtists() {
        XCTAssertTrue(LibraryFilter.appliesGenre(on: .albums))
        XCTAssertTrue(LibraryFilter.appliesGenre(on: .artists))
        XCTAssertFalse(LibraryFilter.appliesGenre(on: .tracks))
        XCTAssertFalse(LibraryFilter.appliesGenre(on: .playlists))
        XCTAssertFalse(LibraryFilter.appliesGenre(on: .downloaded))
    }

    func testYearAppliesOnlyToAlbumsAndTracks() {
        XCTAssertTrue(LibraryFilter.appliesYear(on: .albums))
        XCTAssertTrue(LibraryFilter.appliesYear(on: .tracks))
        XCTAssertFalse(LibraryFilter.appliesYear(on: .artists))
        XCTAssertFalse(LibraryFilter.appliesYear(on: .playlists))
        XCTAssertFalse(LibraryFilter.appliesYear(on: .downloaded))
    }

    func testFormatAndDurationApplyOnlyToTracks() {
        XCTAssertTrue(LibraryFilter.appliesTrackFields(on: .tracks))
        for tab: LibraryTab in [.albums, .artists, .playlists, .downloaded] {
            XCTAssertFalse(
                LibraryFilter.appliesTrackFields(on: tab),
                "format/duration must not apply to \(tab)")
        }
    }

    // MARK: - RangeSlider drag math

    // The container is 216pt wide with a 16pt thumb, so the usable thumb-centre
    // travel is 200pt and the track's left edge (thumb centre at x=8) maps to
    // the lower bound. These lock down the fix for the year-slider snapping bug:
    // the cursor is read against the track, offset by half a thumb.
    private let usable: CGFloat = 200
    private let thumbSize: CGFloat = 16
    private let bounds: ClosedRange<Double> = 2000...2020

    func testCursorAtThumbCentreMapsToLowerBound() {
        // Cursor sitting exactly on the resting thumb centre (thumbSize/2) must
        // resolve to the lower bound — not snap somewhere else.
        let v = RangeSlider.value(
            forCursorX: thumbSize / 2, usable: usable, thumbSize: thumbSize, bounds: bounds)
        XCTAssertEqual(v, 2000, accuracy: 0.001)
    }

    func testCursorBeforeTrackClampsToLowerBound() {
        // Anything left of the track origin clamps to the lower bound rather
        // than going negative.
        let v = RangeSlider.value(
            forCursorX: 0, usable: usable, thumbSize: thumbSize, bounds: bounds)
        XCTAssertEqual(v, 2000, accuracy: 0.001)
    }

    func testCursorAtTrackEndMapsToUpperBound() {
        // Thumb centre travels to `usable + thumbSize/2` at the far end.
        let v = RangeSlider.value(
            forCursorX: usable + thumbSize / 2,
            usable: usable, thumbSize: thumbSize, bounds: bounds)
        XCTAssertEqual(v, 2020, accuracy: 0.001)
    }

    func testCursorAtTrackMidpointMapsToMidValue() {
        // Halfway along the usable travel (centre at thumbSize/2 + usable/2).
        let v = RangeSlider.value(
            forCursorX: thumbSize / 2 + usable / 2,
            usable: usable, thumbSize: thumbSize, bounds: bounds)
        XCTAssertEqual(v, 2010, accuracy: 0.001)
    }

    func testCursorTracksProportionallyNotAtLowerBound() {
        // Regression guard for the original bug, where mid-track drags collapsed
        // toward the lower bound. A cursor 3/4 of the way along must read ~2015,
        // nowhere near the lower bound.
        let v = RangeSlider.value(
            forCursorX: thumbSize / 2 + usable * 0.75,
            usable: usable, thumbSize: thumbSize, bounds: bounds)
        XCTAssertEqual(v, 2015, accuracy: 0.001)
    }
}
