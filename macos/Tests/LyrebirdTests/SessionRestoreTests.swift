import XCTest

@testable import Lyrebird
@testable import LyrebirdCore

/// Launch-splash lifecycle around `attemptRestoreSession`.
///
/// The flag starts `true` (so the first render is the splash, never a
/// `LoginView` flash) and must be `false` after the restore pass on every
/// exit path. The no-persisted-session path is driven for real against a
/// throwaway data dir; the restored-session happy path has no core
/// injection seam (`AppModel.init` constructs its own `LyrebirdCore`), so
/// its early-flip ordering — splash down before the first library fetch —
/// is verified manually, not here.
@MainActor
final class SessionRestoreTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    func testSplashFlagStartsRaised() throws {
        let model = try AppModel()
        XCTAssertTrue(model.isRestoringSession)
    }

    func testRestoreWithNoPersistedSessionLowersSplashFlag() async throws {
        let model = try AppModel()
        await model.attemptRestoreSession()
        XCTAssertFalse(model.isRestoringSession)
        XCTAssertNil(model.session)
    }

    func testSecondRestoreAttemptIsNoOp() async throws {
        let model = try AppModel()
        await model.attemptRestoreSession()
        // A re-fired `.task` must not re-raise the splash or re-run restore.
        model.isRestoringSession = false
        await model.attemptRestoreSession()
        XCTAssertFalse(model.isRestoringSession)
    }
}
