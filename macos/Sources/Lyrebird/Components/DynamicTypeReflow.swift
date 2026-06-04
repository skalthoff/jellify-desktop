import SwiftUI

/// Pure decision logic for Dynamic-Type-driven layout reflow of the persistent
/// chrome — the `PlayerBar` and the `Sidebar` (#338).
///
/// `#337` made every `Theme.font` call scale with the user's
/// System Settings → Display → Larger Text preference. That fixed the *type*,
/// but the chrome around it still used fixed widths / heights: the player bar
/// pins its left meta to 280pt, its right controls to 220pt, and the whole bar
/// to a hard 78/96pt height; the sidebar nav / stat rows render their labels
/// with no line limit. At the accessibility text sizes (`AX1`…`AX5`) the
/// scaled glyphs overflow those frames and clip or shove the transport off the
/// edge of the window.
///
/// The fix is layout reflow, not more font work: above a threshold text size
/// the player bar stacks its three regions (meta / transport / volume)
/// vertically instead of crowding them onto one fixed-width row, and the bar's
/// fixed height becomes a *minimum* height so the taller stacked content can
/// grow downward instead of truncating. The sidebar rows let their labels wrap
/// to a second line rather than eliding to an unreadable ellipsis.
///
/// This type captures the "should we reflow, and to what metrics" contract as a
/// single pure, allocation-free, side-effect-free function so the threshold
/// behaviour is unit-testable without booting a SwiftUI scene or introspecting
/// `some View`. The views own the `@Environment(\.dynamicTypeSize)` read and
/// feed the value in here; everything visual downstream is a branch on the
/// returned `Decision`.
enum DynamicTypeReflow {
    /// The smallest text size that triggers reflow. We reflow at the
    /// *accessibility* sizes only (`.accessibility1` and up): the five
    /// non-accessibility steps (`xSmall`…`xxxLarge`) keep the horizontal
    /// layout because the design widths were sized with `xxxLarge` headroom in
    /// mind and a premature stack would make the bar feel broken for users who
    /// only nudged the slider one notch. `DynamicTypeSize` is `Comparable`, so
    /// the gate is a single `>=` against this floor — and it lines up exactly
    /// with the SDK's own `isAccessibilitySize`, which we assert in tests so a
    /// future SDK reshuffle can't silently drift the two apart.
    static let reflowFloor: DynamicTypeSize = .accessibility1

    /// The player bar's resting height at the body text sizes, with no
    /// "Playing from {source}" label present. Mirrors the historical hard
    /// `frame(height: 78)`; now used as a *minimum* so the row can grow when
    /// content needs more vertical space (see `Decision.minBarHeight`).
    static let baseBarHeight: CGFloat = 78

    /// The player bar's resting height when a "Playing from {source}" label is
    /// present. Mirrors the historical hard `frame(height: 96)`.
    static let contextBarHeight: CGFloat = 96

    /// Minimum height for the player bar once its regions stack vertically.
    /// Tall enough that the three stacked rows (meta, transport, scrubber +
    /// volume) clear each other at `AX5` without the bar collapsing; the frame
    /// is a `minHeight`, so real content taller than this still grows the bar
    /// rather than clipping.
    static let stackedMinBarHeight: CGFloat = 200

    /// Maximum number of lines a sidebar nav / stat / playlist label may use.
    /// At body sizes labels stay on one line (the design intent — these are
    /// short nav nouns). Once reflow engages we allow a second line so a
    /// scaled-up "Recently Added" / a long playlist name wraps instead of
    /// eliding mid-word to an unreadable ellipsis.
    static let sidebarLabelLineLimit = 1
    static let sidebarReflowLabelLineLimit = 2

    /// The outcome of a Dynamic Type size change for the persistent chrome.
    /// Equatable so it slots cleanly into tests and into `onChange`-style
    /// comparisons without bespoke equality.
    struct Decision: Equatable {
        /// True once the text size is at or above `reflowFloor`. Drives both
        /// the player-bar axis switch and the sidebar wrap allowance.
        var shouldReflow: Bool

        /// Whether the player bar should lay its three regions out vertically
        /// (`true`) or keep the historical single horizontal row (`false`).
        /// Identical to `shouldReflow` today; kept as a distinct field so a
        /// future intermediate breakpoint (e.g. a two-row hybrid) can diverge
        /// the player bar from the sidebar without touching call sites.
        var stackPlayerBar: Bool

        /// The `minHeight` the player bar should adopt. When not reflowing this
        /// is the historical fixed height for the current context-label state,
        /// applied as a floor rather than an exact height so a one-notch glyph
        /// overflow at the body sizes can still nudge the bar a couple of
        /// points taller instead of clipping. When reflowing it jumps to
        /// `stackedMinBarHeight` to seat the stacked rows.
        var minBarHeight: CGFloat

        /// Line limit for sidebar nav / stat / playlist labels. `1` at body
        /// sizes (design intent), `2` once reflowing so long labels wrap.
        var sidebarLabelLineLimit: Int
    }

    /// Pure reducer. Given the active `dynamicTypeSize` and whether the player
    /// bar currently shows a "Playing from {source}" context label, returns the
    /// reflow decision the chrome should adopt.
    ///
    /// Contract:
    ///   * Below `reflowFloor` (every non-accessibility size): no reflow. The
    ///     player bar keeps its horizontal layout and its historical
    ///     context-dependent height as a `minHeight`; sidebar labels stay on
    ///     one line.
    ///   * At or above `reflowFloor`: reflow on. The player bar stacks and
    ///     adopts `stackedMinBarHeight`; sidebar labels may wrap to two lines.
    static func decide(
        dynamicTypeSize: DynamicTypeSize,
        hasContextLabel: Bool
    ) -> Decision {
        let reflow = dynamicTypeSize >= reflowFloor
        let baseHeight = hasContextLabel ? contextBarHeight : baseBarHeight
        return Decision(
            shouldReflow: reflow,
            stackPlayerBar: reflow,
            minBarHeight: reflow ? stackedMinBarHeight : baseHeight,
            sidebarLabelLineLimit: reflow
                ? sidebarReflowLabelLineLimit
                : sidebarLabelLineLimit
        )
    }
}
