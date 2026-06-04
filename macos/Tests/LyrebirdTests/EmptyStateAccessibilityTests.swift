import SwiftUI
import XCTest

@testable import Lyrebird

/// Accessibility coverage for the empty-state surfaces (#99 / #294).
///
/// The bug these pin: `.accessibilityElement(children: .combine)` *flattens* a
/// subtree into one static element. Applied to a view that contains an
/// interactive CTA button, it strips the button of its `.isButton` trait and
/// tap action, so VoiceOver users can't reach or activate it. The fix is to
/// `.contain` (keep descendants individually focusable) whenever a CTA is
/// present.
///
/// `EmptyStateView`'s container strategy is a `private` computed property and
/// the resolved accessibility tree can't be introspected headlessly, so the
/// contract is asserted against source — the same structural-read pattern
/// `FullScreenChromeTests` uses for window-server-dependent wiring. A second
/// group exercises the public `hasCTA`-driven factories so a regression in the
/// *presence* of CTAs (which selects the strategy) is also caught at runtime.
final class EmptyStateAccessibilityTests: XCTestCase {

    // MARK: - Source-read: container strategy

    /// `EmptyStateView` must `.contain` (not `.combine`) when CTAs are present
    /// so the primary/secondary buttons stay individually actionable.
    func testEmptyStateViewUsesContainWhenCTAPresent() throws {
        let source = try Self.readSource("Sources/Lyrebird/Components/EmptyStateView.swift")
        XCTAssertTrue(
            source.contains(".accessibilityElement(children: hasCTA ? .contain : .combine)"),
            "EmptyStateView must switch to .contain when a CTA is present so its buttons stay reachable"
        )
        // The unconditional `.combine` that swallowed the buttons must be gone.
        XCTAssertFalse(
            source.contains(".accessibilityElement(children: .combine)\n    }"),
            "EmptyStateView must not unconditionally .combine — that flattens the CTA buttons"
        )
    }

    /// `EmptyLibraryState` contains the "Open Jellyfin web" button, so it must
    /// `.contain`, not `.combine`.
    func testEmptyLibraryStateUsesContain() throws {
        let source = try Self.readSource("Sources/Lyrebird/Components/EmptyLibraryState.swift")
        XCTAssertTrue(
            source.contains(".accessibilityElement(children: .contain)"),
            "EmptyLibraryState must .contain so the 'Open Jellyfin web' button stays actionable"
        )
        XCTAssertFalse(
            source.contains(".accessibilityElement(children: .combine)"),
            "EmptyLibraryState must not .combine — it flattens the interactive button"
        )
    }

    // MARK: - Runtime: CTA presence drives the strategy

    /// The text-only presets carry no CTA — they're free to `.combine`. The
    /// presets that take a handler must expose one. These pin the inputs that
    /// select the accessibility strategy in `body`.
    func testFactoryPresetsCTAPresenceMatchesAccessibilityNeed() {
        // No CTA: text-only, safe to combine.
        XCTAssertNil(EmptyStateView.noFavorites().primaryCTA)
        XCTAssertNil(EmptyStateView.noFavorites().secondaryCTA)
        XCTAssertNil(EmptyStateView.noDownloads().primaryCTA)
        XCTAssertNil(EmptyStateView.emptyPlaylist(onAddTracks: nil).primaryCTA)

        // Has CTA: must keep the button reachable → .contain.
        XCTAssertNotNil(EmptyStateView.firstRunNoLibrary(onChangeLibrary: {}).primaryCTA)
        XCTAssertNotNil(EmptyStateView.emptyPlaylist(onAddTracks: {}).primaryCTA)
    }

    // MARK: - Helpers

    private static func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let macosDir = thisFile
            .deletingLastPathComponent() // LyrebirdTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
        let url = macosDir.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
