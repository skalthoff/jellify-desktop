import XCTest

@testable import Lyrebird

/// Coverage for the Mini Player click-through-to-detail feature (#110):
///
/// 1. The **tap-vs-drag discrimination** boundary used by
///    `MiniPlayerDragHandle` to tell a click (open the album page) from a
///    window reposition. Exercised through the pure
///    `MiniPlayerView_dragExceedsThreshold` helper so the threshold is
///    verified without a live window-server event stream, which a headless
///    test run doesn't have.
/// 2. The **nav routing** the artwork / artist taps invoke
///    (`AppModel.openInMainWindowFromMiniPlayer`): that it drills the main
///    window's `navPath` to the right `Route`, and — unlike
///    `returnToFullWindow` — leaves the mini player open so an always-on-top
///    widget keeps floating over the now-foregrounded detail page.
///
/// `AppModel` is `@MainActor`, so the routing half of the suite is
/// main-actor isolated. Constructing it boots a live `LyrebirdCore`; we
/// redirect the core's data directory to a throwaway temp dir via
/// `XDG_DATA_HOME` (honoured by `storage::default_data_dir()`) so the test
/// never touches the real app's database.
@MainActor
final class MiniPlayerClickThroughTests: XCTestCase {

    /// Point the core at a unique temp data dir before the first `AppModel()`
    /// in the process, mirroring `MiniPlayerStateTests`.
    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    // MARK: - Tap-vs-drag threshold

    func testReleaseInPlaceIsATap() {
        // Press and release at the same point: zero travel → a tap.
        let start = CGPoint(x: 100, y: 100)
        XCTAssertFalse(
            MiniPlayerView_dragExceedsThreshold(from: start, to: start),
            "a press released in place must read as a tap, not a drag"
        )
    }

    func testSubThresholdJitterIsStillATap() {
        // A couple of points of incidental jitter during a click must not be
        // promoted to a window drag, or the click-through would never fire.
        let start = CGPoint(x: 100, y: 100)
        let jittered = CGPoint(x: 100 + 2, y: 100 - 2) // |(2,-2)| ≈ 2.83 < 4
        XCTAssertFalse(
            MiniPlayerView_dragExceedsThreshold(from: start, to: jittered),
            "movement under the \(MiniPlayerDragHandle.dragThreshold)pt threshold stays a tap"
        )
    }

    func testMovementJustPastThresholdIsADrag() {
        // Travel comfortably past the threshold on one axis → a drag.
        let start = CGPoint(x: 100, y: 100)
        let dragged = CGPoint(x: 100 + MiniPlayerDragHandle.dragThreshold + 1, y: 100)
        XCTAssertTrue(
            MiniPlayerView_dragExceedsThreshold(from: start, to: dragged),
            "horizontal travel past the threshold must read as a window drag"
        )
    }

    func testDiagonalMovementPastThresholdIsADrag() {
        // Euclidean distance, not per-axis: (3,3) ≈ 4.24 > 4 even though
        // neither axis alone clears the 4pt bar.
        let start = CGPoint(x: 0, y: 0)
        let dragged = CGPoint(x: 3, y: 3)
        XCTAssertTrue(
            MiniPlayerView_dragExceedsThreshold(from: start, to: dragged),
            "diagonal travel is measured by distance, so (3,3) clears a 4pt threshold"
        )
    }

    func testVerticalDragIsDetectedRegardlessOfDirection() {
        // Dragging upward (negative dy) is just as much a drag as downward.
        let start = CGPoint(x: 50, y: 50)
        let up = CGPoint(x: 50, y: 50 - (MiniPlayerDragHandle.dragThreshold + 2))
        XCTAssertTrue(
            MiniPlayerView_dragExceedsThreshold(from: start, to: up),
            "upward travel past the threshold is a drag too — sign must not matter"
        )
    }

    // MARK: - Nav routing

    func testArtworkTapDrillsMainWindowToAlbumRoute() throws {
        let model = try AppModel()
        XCTAssertTrue(model.navPath.isEmpty, "precondition: fresh model has an empty drill stack")

        model.openInMainWindowFromMiniPlayer(.album("album-42"))

        XCTAssertEqual(
            model.navPath.last,
            AppModel.Route.album("album-42"),
            "tapping mini-player artwork must push the album route onto the main window"
        )
    }

    func testArtistTapDrillsMainWindowToArtistRoute() throws {
        let model = try AppModel()

        model.openInMainWindowFromMiniPlayer(.artist("artist-7"))

        XCTAssertEqual(
            model.navPath.last,
            AppModel.Route.artist("artist-7"),
            "tapping the mini-player artist name must push the artist route"
        )
    }

    /// The defining difference from `returnToFullWindow`: a click-through is
    /// navigation, not a dismissal, so the mini player must stay open (an
    /// always-on-top widget keeps floating over the detail page it just
    /// opened).
    func testClickThroughDoesNotCloseTheMiniPlayer() throws {
        let model = try AppModel()
        model.isMiniPlayerVisible = true

        model.openInMainWindowFromMiniPlayer(.album("album-1"))

        XCTAssertTrue(
            model.isMiniPlayerVisible,
            "click-through navigates without dismissing the mini player"
        )
    }

    /// Two successive click-throughs stack as two drill entries — the seam is
    /// a plain push (matching `navigate(to:)`), not a replace, so back returns
    /// to the prior detail page.
    func testSuccessiveClickThroughsStackOnTheDrillPath() throws {
        let model = try AppModel()

        model.openInMainWindowFromMiniPlayer(.artist("artist-1"))
        model.openInMainWindowFromMiniPlayer(.album("album-2"))

        XCTAssertEqual(model.navPath.count, 2, "each click-through pushes a fresh drill entry")
        XCTAssertEqual(model.navPath.first, AppModel.Route.artist("artist-1"))
        XCTAssertEqual(model.navPath.last, AppModel.Route.album("album-2"))
    }
}
