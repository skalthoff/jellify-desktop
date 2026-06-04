import SwiftUI
import XCTest

@testable import Lyrebird

/// Coverage for `DynamicTypeReflow.decide` — the pure reducer that decides
/// whether the persistent chrome (PlayerBar + Sidebar) should reflow at large
/// Dynamic Type sizes (#338).
///
/// The decision is exercised through the pure helper so the threshold and the
/// resulting metrics are verified without realizing a SwiftUI scene or reading
/// back a rendered `some View` — the player bar's stacked layout and the
/// sidebar's wrap allowance both branch on exactly these fields.
final class DynamicTypeReflowTests: XCTestCase {

    // MARK: - Non-accessibility sizes keep the horizontal layout

    /// Every standard (non-accessibility) step — `xSmall`…`xxxLarge` — must
    /// leave the chrome in its historical horizontal layout. The design widths
    /// were sized with `xxxLarge` headroom, so reflowing before the
    /// accessibility range would make the bar feel broken for a one-notch bump.
    func testStandardSizesDoNotReflow() {
        let standard: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large,
            .xLarge, .xxLarge, .xxxLarge,
        ]
        for size in standard {
            let decision = DynamicTypeReflow.decide(
                dynamicTypeSize: size,
                hasContextLabel: false
            )
            XCTAssertFalse(
                decision.shouldReflow,
                "\(size) is below the accessibility range and must not reflow"
            )
            XCTAssertFalse(
                decision.stackPlayerBar,
                "\(size): player bar stays horizontal below the accessibility range"
            )
            XCTAssertEqual(
                decision.sidebarLabelLineLimit,
                DynamicTypeReflow.sidebarLabelLineLimit,
                "\(size): sidebar labels stay on one line below the accessibility range"
            )
        }
    }

    // MARK: - Accessibility sizes reflow

    /// Every accessibility step — `accessibility1`…`accessibility5` — must
    /// flip the chrome into its reflowed layout: player bar stacks, sidebar
    /// labels may wrap.
    func testAccessibilitySizesReflow() {
        let accessibility: [DynamicTypeSize] = [
            .accessibility1, .accessibility2, .accessibility3,
            .accessibility4, .accessibility5,
        ]
        for size in accessibility {
            let decision = DynamicTypeReflow.decide(
                dynamicTypeSize: size,
                hasContextLabel: false
            )
            XCTAssertTrue(
                decision.shouldReflow,
                "\(size) is in the accessibility range and must reflow"
            )
            XCTAssertTrue(
                decision.stackPlayerBar,
                "\(size): player bar stacks vertically in the accessibility range"
            )
            XCTAssertEqual(
                decision.sidebarLabelLineLimit,
                DynamicTypeReflow.sidebarReflowLabelLineLimit,
                "\(size): sidebar labels may wrap to a second line"
            )
        }
    }

    // MARK: - The reflow floor lines up with the SDK's accessibility flag

    /// The reflow gate is a `>=` against `reflowFloor`. That floor must align
    /// exactly with the SDK's own `isAccessibilitySize` partition: every size
    /// the SDK calls an accessibility size reflows, and no size it calls a
    /// standard size does. Asserting it here means a future SDK reshuffle of
    /// the enum can't silently drift our threshold off the accessibility
    /// boundary without a red test.
    func testReflowDecisionMatchesSDKAccessibilityFlag() {
        for size in DynamicTypeSize.allCases {
            let decision = DynamicTypeReflow.decide(
                dynamicTypeSize: size,
                hasContextLabel: false
            )
            XCTAssertEqual(
                decision.shouldReflow,
                size.isAccessibilitySize,
                "\(size): reflow must match the SDK's isAccessibilitySize"
            )
        }
    }

    /// `accessibility1` is the exact boundary — the first size that reflows.
    /// The step just below it (`xxxLarge`) must not. Pinning both sides of the
    /// edge guards against an off-by-one in the `>=` comparison.
    func testBoundaryIsAccessibilityOne() {
        XCTAssertEqual(DynamicTypeReflow.reflowFloor, .accessibility1)
        XCTAssertFalse(
            DynamicTypeReflow.decide(dynamicTypeSize: .xxxLarge, hasContextLabel: false)
                .shouldReflow,
            "the step below the floor must not reflow"
        )
        XCTAssertTrue(
            DynamicTypeReflow.decide(dynamicTypeSize: .accessibility1, hasContextLabel: false)
                .shouldReflow,
            "the floor itself must reflow"
        )
    }

    // MARK: - Min bar height tracks the context label below the floor

    /// Below the reflow floor the bar's `minHeight` is the historical fixed
    /// height, which depends on whether the "Playing from {source}" label is
    /// present (78 without, 96 with). Applying that as a floor — rather than an
    /// exact frame — preserves the stable chrome while still letting a one-notch
    /// glyph overflow nudge the bar taller.
    func testMinBarHeightTracksContextLabelBelowFloor() {
        let noLabel = DynamicTypeReflow.decide(
            dynamicTypeSize: .large,
            hasContextLabel: false
        )
        XCTAssertEqual(
            noLabel.minBarHeight,
            DynamicTypeReflow.baseBarHeight,
            "no context label: bar floors at the base height"
        )

        let withLabel = DynamicTypeReflow.decide(
            dynamicTypeSize: .large,
            hasContextLabel: true
        )
        XCTAssertEqual(
            withLabel.minBarHeight,
            DynamicTypeReflow.contextBarHeight,
            "with a context label: bar floors a few points taller"
        )
        XCTAssertGreaterThan(
            withLabel.minBarHeight,
            noLabel.minBarHeight,
            "the context label must only ever grow the bar, never shrink it"
        )
    }

    /// Once reflowing, the bar adopts the taller stacked floor regardless of
    /// the context label — the three stacked rows dominate the height, so the
    /// label's couple of points no longer move the floor and both cases land on
    /// `stackedMinBarHeight`.
    func testReflowUsesStackedMinHeightRegardlessOfContextLabel() {
        let noLabel = DynamicTypeReflow.decide(
            dynamicTypeSize: .accessibility3,
            hasContextLabel: false
        )
        let withLabel = DynamicTypeReflow.decide(
            dynamicTypeSize: .accessibility3,
            hasContextLabel: true
        )
        XCTAssertEqual(noLabel.minBarHeight, DynamicTypeReflow.stackedMinBarHeight)
        XCTAssertEqual(withLabel.minBarHeight, DynamicTypeReflow.stackedMinBarHeight)
    }

    /// The stacked floor must be taller than either resting height, otherwise
    /// reflowing would shrink the bar and re-introduce the clipping the reflow
    /// exists to fix.
    func testStackedMinHeightExceedsRestingHeights() {
        XCTAssertGreaterThan(
            DynamicTypeReflow.stackedMinBarHeight,
            DynamicTypeReflow.contextBarHeight,
            "the stacked layout needs more vertical room than the tallest resting bar"
        )
    }

    // MARK: - Decision is a pure function of its inputs

    /// The reducer is side-effect-free: same inputs, same `Decision`. Equatable
    /// conformance backs the `onChange`-style comparisons the views rely on to
    /// avoid redundant layout churn.
    func testDecisionIsDeterministic() {
        let a = DynamicTypeReflow.decide(dynamicTypeSize: .accessibility2, hasContextLabel: true)
        let b = DynamicTypeReflow.decide(dynamicTypeSize: .accessibility2, hasContextLabel: true)
        XCTAssertEqual(a, b)
    }
}
