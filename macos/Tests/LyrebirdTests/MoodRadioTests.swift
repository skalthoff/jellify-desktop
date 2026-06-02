import XCTest

@testable import Lyrebird
import LyrebirdCore

/// Coverage for the Mood radio model (#256).
///
/// The mood set is pure value logic sourced from `06-screen-specs.md` §9
/// ("chill, focus, workout, sleep, party"), and `availableMoods` must start
/// empty so the Mood radio row hides itself on a library that hasn't been
/// probed / has no mood tags.
@MainActor
final class MoodRadioTests: XCTestCase {

	override class func setUp() {
		super.setUp()
		let dir = NSTemporaryDirectory() + "lyrebird-mood-\(UUID().uuidString)"
		setenv("XDG_DATA_HOME", dir, 1)
	}

	func testMoodSetMatchesSpecTagsInOrder() {
		XCTAssertEqual(
			AppModel.Mood.all.map(\.tag),
			["chill", "focus", "workout", "sleep", "party"],
			"the mood row carries the five spec moods, in spec order"
		)
	}

	func testEachMoodHasADistinctLabelAndSymbol() {
		let labels = AppModel.Mood.all.map(\.label)
		let symbols = AppModel.Mood.all.map(\.symbol)
		XCTAssertEqual(Set(labels).count, labels.count, "labels are distinct")
		XCTAssertEqual(Set(symbols).count, symbols.count, "tile glyphs are distinct")
		XCTAssertFalse(symbols.contains(where: \.isEmpty), "every mood carries a glyph")
	}

	func testAvailableMoodsStartsEmptySoTheRowHidesUntilProbed() throws {
		let model = try AppModel()
		XCTAssertTrue(
			model.availableMoods.isEmpty,
			"no moods are surfaced until probeAvailableMoods() confirms tagged tracks exist"
		)
	}
}
