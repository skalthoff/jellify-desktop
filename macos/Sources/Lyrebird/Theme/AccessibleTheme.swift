import SwiftUI

/// Contrast-aware accessor for `Theme` color tokens (#340).
///
/// `Theme` exposes both the standard brand tokens and their high-contrast
/// variants. Reading the right one requires knowing whether the user has
/// enabled System Settings ▸ Accessibility ▸ Display ▸ Increase Contrast,
/// which SwiftUI surfaces as `@Environment(\.colorSchemeContrast)`.
///
/// `AccessibleTheme` wraps that decision so views read a single property and
/// automatically get the high-contrast value when the setting is on — the
/// same approach `ThemedFocusRing` (#335) already uses for the focus ring.
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
	var ink2: Color { isIncreased ? Theme.ink2HighContrast : Theme.ink2 }

	/// Tertiary text. The standard token is alpha-blended and fails at small
	/// sizes; the HC variant is opaque and reaches ≈7:1.
	var ink3: Color { isIncreased ? Theme.ink3HighContrast : Theme.ink3 }

	/// Body accent. Upgrades from `accent` to the brighter `accentHot` so
	/// accent-colored text clears 4.5:1.
	var accent: Color { isIncreased ? Theme.accentHighContrast : Theme.accent }

	/// Hairline border. Becomes a solid, visible line under Increase Contrast
	/// instead of an alpha-blended near-invisible one.
	var border: Color { isIncreased ? Theme.borderHighContrast : Theme.border }

	/// Strong border / divider. Solid under Increase Contrast.
	var borderStrong: Color {
		isIncreased ? Theme.borderStrongHighContrast : Theme.borderStrong
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
