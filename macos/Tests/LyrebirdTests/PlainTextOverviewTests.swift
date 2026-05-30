import XCTest
@testable import Lyrebird

/// Unit coverage for `String.plainTextOverview`, the hand-rolled HTML→plain-text
/// strip used by the Artist detail About section (#62). The AppKit
/// `NSAttributedString` HTML importer is main-thread-only and slow, so the
/// biography text is sanitized by this pure function instead — which makes it
/// cheap to test in isolation.
final class PlainTextOverviewTests: XCTestCase {
	/// Plain text with no markup and no entities is returned verbatim
	/// (aside from surrounding-whitespace trimming).
	func testPlainTextPassesThroughTrimmed() {
		let input = "  Radiohead formed in Abingdon in 1985.  "
		XCTAssertEqual(
			input.plainTextOverview,
			"Radiohead formed in Abingdon in 1985.")
	}

	/// Inline tags are dropped and block-level tags collapse to newlines, so
	/// paragraph structure survives without leaking any `<...>` markup.
	func testStripsTagsAndConvertsBlockTagsToNewlines() {
		let input = "<p>First line.</p><p>Second <b>bold</b> line.<br>Third.</p>"
		let result = input.plainTextOverview
		XCTAssertFalse(result.contains("<"), "no markup should remain: \(result)")
		XCTAssertFalse(result.contains(">"), "no markup should remain: \(result)")
		XCTAssertEqual(
			result,
			"First line.\nSecond bold line.\nThird.")
	}

	/// The handful of HTML entities Jellyfin actually emits are decoded back to
	/// their literal characters.
	func testDecodesCommonEntities() {
		let input = "Simon &amp; Garfunkel said &quot;hello&quot; &lt;here&gt; &#39;now&#39;"
		XCTAssertEqual(
			input.plainTextOverview,
			"Simon & Garfunkel said \"hello\" <here> 'now'")
	}

	/// An empty / whitespace-only overview reduces to an empty string, which is
	/// the signal the About section uses to hide itself entirely.
	func testEmptyAndWhitespaceCollapseToEmpty() {
		XCTAssertEqual("".plainTextOverview, "")
		XCTAssertEqual("   \n\t  ".plainTextOverview, "")
		XCTAssertEqual("<p></p><br>".plainTextOverview, "")
	}
}
