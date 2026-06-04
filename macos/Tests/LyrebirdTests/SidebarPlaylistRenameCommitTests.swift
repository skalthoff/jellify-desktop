import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for the inline playlist-rename commit contract behind the audit
/// fix for the double-commit bug.
///
/// In the sidebar, pressing Return fired `commitSidebarPlaylistEdit()` and the
/// resulting resign-first-responder then flipped the field's focus, which ran
/// the `onChange(of: isFocused)` blur branch as a *second* commit. The view now
/// guards that with a `committed` flag, but the model itself must also be
/// idempotent so a stray second commit (from any path) can't double-apply: the
/// up-front clearing of `sidebarEditingPlaylistId` turns the second call into a
/// guarded no-op. These tests pin that model-level backstop.
///
/// `AppModel` is `@MainActor`; constructing it boots a live `LyrebirdCore`, so
/// the suite redirects the core's data dir to a throwaway temp dir via
/// `XDG_DATA_HOME` (honoured by `storage::default_data_dir()`) to avoid
/// touching the real app database. No session is established, so no network
/// round-trip runs — the tests exercise only the synchronous edit-state
/// transitions.
@MainActor
final class SidebarPlaylistRenameCommitTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory() + "lyrebird-tests-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", dir, 1)
    }

    private func makePlaylist(id: String, name: String) -> Playlist {
        Playlist(
            id: id,
            name: name,
            trackCount: 0,
            runtimeTicks: 0,
            imageTag: nil,
            userData: nil
        )
    }

    /// A commit clears the edit session up-front. This is the property the
    /// second (blur-driven) commit relies on: once the id is `nil`, the repeat
    /// call has nothing to act on.
    func testCommitClearsEditingState() async throws {
        let model = try AppModel()
        model.playlists = [makePlaylist(id: "pl-1", name: "Old Name")]
        model.sidebarEditingPlaylistId = "pl-1"
        model.sidebarEditingDraft = "Old Name" // same name → no network Task

        await model.commitSidebarPlaylistEdit()

        XCTAssertNil(
            model.sidebarEditingPlaylistId,
            "commit must clear the editing id so a follow-on blur can't re-commit"
        )
        XCTAssertEqual(
            model.sidebarEditingDraft,
            "",
            "commit must clear the draft"
        )
    }

    /// The double-commit guard: invoking commit a second time after the first
    /// has cleared the editing id is a no-op. Reproduces the Return-then-blur
    /// sequence at the model layer — the second call must not mutate playlists
    /// or crash. Uses an unchanged name so the (single legitimate) commit
    /// itself launches no async core call, keeping the assertion deterministic.
    func testSecondCommitAfterClearIsNoOp() async throws {
        let model = try AppModel()
        let original = makePlaylist(id: "pl-1", name: "Keep Me")
        model.playlists = [original]
        model.sidebarEditingPlaylistId = "pl-1"
        model.sidebarEditingDraft = "Keep Me"

        await model.commitSidebarPlaylistEdit() // first (Return)
        XCTAssertNil(model.sidebarEditingPlaylistId)

        // Second commit, simulating the blur that Return's focus loss triggers.
        await model.commitSidebarPlaylistEdit()

        XCTAssertEqual(model.playlists.count, 1, "no phantom playlist from a repeat commit")
        XCTAssertEqual(
            model.playlists.first?.name,
            "Keep Me",
            "a repeat commit with no live edit session must not mutate the list"
        )
        XCTAssertNil(model.sidebarEditingPlaylistId, "editing state stays cleared")
    }

    /// The Escape-then-blur path: cancelling clears the editing id, and a
    /// subsequent commit (from the blur the cancel triggers) must also no-op.
    func testCommitAfterCancelIsNoOp() async throws {
        let model = try AppModel()
        model.playlists = [makePlaylist(id: "pl-1", name: "Untouched")]
        model.sidebarEditingPlaylistId = "pl-1"
        model.sidebarEditingDraft = "Edited But Cancelled"

        model.cancelSidebarPlaylistEdit()
        XCTAssertNil(model.sidebarEditingPlaylistId)

        await model.commitSidebarPlaylistEdit()

        XCTAssertEqual(
            model.playlists.first?.name,
            "Untouched",
            "a commit after cancel must not apply the abandoned draft"
        )
    }
}
