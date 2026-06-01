import AppKit
import XCTest

@testable import Lyrebird

/// Pure-logic coverage for the Library Tracks tab multi-select state machine
/// (#217). Exercises every branch of `TrackSelectionResolver.resolve` — the
/// Cmd-toggle / Shift-range / bare-click-plays arithmetic that drives
/// `LibraryView.handleTrackClick` — without a SwiftUI scene graph or an
/// `AppModel`.
final class TrackSelectionResolverTests: XCTestCase {
	private let ids = ["a", "b", "c", "d", "e"]

	// MARK: - Bare click

	func testBareClickClearsSelectionAnchorsAndPlays() {
		let outcome = TrackSelectionResolver.resolve(
			clickedIndex: 2,
			trackIds: ids,
			currentSelection: ["a", "b"],
			anchorIndex: 0,
			modifiers: []
		)
		XCTAssertEqual(outcome, .init(selection: [], anchorIndex: 2, shouldPlay: true))
	}

	// MARK: - Cmd toggle

	func testCommandClickAddsRowWithoutPlaying() {
		let outcome = TrackSelectionResolver.resolve(
			clickedIndex: 1,
			trackIds: ids,
			currentSelection: ["a"],
			anchorIndex: 0,
			modifiers: .command
		)
		XCTAssertEqual(outcome, .init(selection: ["a", "b"], anchorIndex: 1, shouldPlay: false))
	}

	func testCommandClickRemovesAlreadySelectedRow() {
		let outcome = TrackSelectionResolver.resolve(
			clickedIndex: 1,
			trackIds: ids,
			currentSelection: ["a", "b"],
			anchorIndex: 0,
			modifiers: .command
		)
		XCTAssertEqual(outcome, .init(selection: ["a"], anchorIndex: 1, shouldPlay: false))
	}

	// MARK: - Shift range

	func testShiftClickExtendsRangeForwardFromAnchor() {
		let outcome = TrackSelectionResolver.resolve(
			clickedIndex: 3,
			trackIds: ids,
			currentSelection: ["a"],
			anchorIndex: 1,
			modifiers: .shift
		)
		// Anchor 1 (b) through 3 (d) inclusive, unioned with the prior "a".
		XCTAssertEqual(outcome, .init(selection: ["a", "b", "c", "d"], anchorIndex: 3, shouldPlay: false))
	}

	func testShiftClickExtendsRangeBackwardFromAnchor() {
		let outcome = TrackSelectionResolver.resolve(
			clickedIndex: 1,
			trackIds: ids,
			currentSelection: [],
			anchorIndex: 3,
			modifiers: .shift
		)
		XCTAssertEqual(outcome, .init(selection: ["b", "c", "d"], anchorIndex: 1, shouldPlay: false))
	}

	func testShiftClickWithoutAnchorSelectsOnlyHitRow() {
		let outcome = TrackSelectionResolver.resolve(
			clickedIndex: 2,
			trackIds: ids,
			currentSelection: [],
			anchorIndex: nil,
			modifiers: .shift
		)
		XCTAssertEqual(outcome, .init(selection: ["c"], anchorIndex: 2, shouldPlay: false))
	}

	// MARK: - Guards & edge cases

	func testOutOfBoundsIndexReturnsNil() {
		XCTAssertNil(
			TrackSelectionResolver.resolve(
				clickedIndex: 99,
				trackIds: ids,
				currentSelection: ["a"],
				anchorIndex: 0,
				modifiers: []
			)
		)
		XCTAssertNil(
			TrackSelectionResolver.resolve(
				clickedIndex: -1,
				trackIds: ids,
				currentSelection: [],
				anchorIndex: nil,
				modifiers: []
			)
		)
	}

	func testEmptyListReturnsNil() {
		XCTAssertNil(
			TrackSelectionResolver.resolve(
				clickedIndex: 0,
				trackIds: [],
				currentSelection: [],
				anchorIndex: nil,
				modifiers: []
			)
		)
	}

	func testCommandTakesPrecedenceOverShiftWhenBothHeld() {
		// AppKit reports both flags; the resolver checks `.command` first, so a
		// Cmd+Shift click toggles a single row rather than extending a range.
		let outcome = TrackSelectionResolver.resolve(
			clickedIndex: 4,
			trackIds: ids,
			currentSelection: ["a"],
			anchorIndex: 0,
			modifiers: [.command, .shift]
		)
		XCTAssertEqual(outcome, .init(selection: ["a", "e"], anchorIndex: 4, shouldPlay: false))
	}
}
