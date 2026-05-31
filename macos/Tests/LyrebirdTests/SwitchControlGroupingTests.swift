import XCTest
@testable import Lyrebird

/// Encodes the acceptance criteria for the Switch Control "Group items"
/// grouping: the shell exposes exactly three top-level groups labelled
/// "Sidebar", "Content", and "Player Bar", in that scan order. These assert
/// against `SwitchControlGroup`, the same enum `MainShell` reads for its
/// `.accessibilityLabel` modifiers, so the labels and the test can't drift.
final class SwitchControlGroupingTests: XCTestCase {
	func testExactlyThreeTopLevelGroups() {
		XCTAssertEqual(SwitchControlGroup.allCases.count, 3)
	}

	func testGroupLabelsMatchAcceptanceCriteria() {
		XCTAssertEqual(SwitchControlGroup.sidebar.rawValue, "Sidebar")
		XCTAssertEqual(SwitchControlGroup.content.rawValue, "Content")
		XCTAssertEqual(SwitchControlGroup.playerBar.rawValue, "Player Bar")
	}

	func testGroupScanOrderIsSidebarContentPlayerBar() {
		XCTAssertEqual(
			SwitchControlGroup.allCases.map(\.rawValue),
			["Sidebar", "Content", "Player Bar"]
		)
	}

	func testGroupLabelsAreUnique() {
		let labels = SwitchControlGroup.allCases.map(\.rawValue)
		XCTAssertEqual(Set(labels).count, labels.count)
	}
}
