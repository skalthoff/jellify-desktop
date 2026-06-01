import SwiftUI

/// Contrast-aware accessor for `Theme` color tokens.
///
/// Most call sites read the base `Theme` tokens (`ink2`, `ink3`, `border`,
/// `borderStrong`) directly; those are already appearance-adaptive and lift
/// to their high-contrast values automatically when Increase Contrast is on.
/// `AccessibleTheme` is the escape hatch for the few views that have a reason
/// to branch explicitly on `@Environment(\.colorSchemeContrast)` — e.g. when
/// the same view needs the standard and high-contrast values side by side, or
/// when it composes a color that isn't a single token. It maps the contrast
/// setting to a fixed standard/high-contrast pair so the dispatch is
/// deterministic and unit-testable.
///
/// Usage:
/// ```swift
/// struct Row: View {
///     @Environment(\.colorSchemeContrast) private var contrast
///     var body: some View {
///         let theme = AccessibleTheme(contrast)
///         Text("Subtitle").foregroundStyle(theme.ink3)
///     }
/// }
/// ```
///
/// Because `colorSchemeContrast` is an environment value, any view that reads
/// it (directly or via this wrapper) re-renders when the user toggles Increase
/// Contrast — no manual observation needed.
struct AccessibleTheme {
	let isIncreased: Bool

	init(_ contrast: ColorSchemeContrast) {
		isIncreased = contrast == .increased
	}

	/// Secondary text. Lifts to an opaque ≈7:1 value under Increase Contrast.
	var ink2: Color { isIncreased ? Theme.ink2HighContrast : Theme.ink2Base }

	/// Tertiary text. The standard token is alpha-blended and fails at small
	/// sizes; the HC variant is opaque and reaches ≈7:1.
	var ink3: Color { isIncreased ? Theme.ink3HighContrast : Theme.ink3Base }

	/// Body accent. Upgrades from `accent` to the brighter `accentHot` so
	/// accent-colored text clears 4.5:1.
	var accent: Color { isIncreased ? Theme.accentHighContrast : Theme.accent }

	/// Hairline border. Becomes a solid, visible line under Increase Contrast
	/// instead of an alpha-blended near-invisible one.
	var border: Color { isIncreased ? Theme.borderHighContrast : Theme.borderBase }

	/// Strong border / divider. Solid under Increase Contrast.
	var borderStrong: Color {
		isIncreased ? Theme.borderStrongHighContrast : Theme.borderStrongBase
	}
}

extension EnvironmentValues {
	/// Convenience accessor that bundles the current contrast setting into an
	/// `AccessibleTheme`, so a view can write
	/// `@Environment(\.accessibleTheme) var theme`.
	var accessibleTheme: AccessibleTheme {
		AccessibleTheme(colorSchemeContrast)
	}
}
