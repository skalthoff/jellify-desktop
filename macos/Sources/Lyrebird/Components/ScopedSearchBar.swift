import SwiftUI

/// A compact, in-content search bar for scoping a single detail view's track
/// list. Visually distinct from the full-screen global Search surface
/// (`SearchView`): smaller type, a tighter `surface2` pill, and it lives
/// *inside* the content column rather than spanning a dedicated screen.
///
/// Focus is driven externally so the owning view can pull focus into it when
/// ⌘F fires (via `AppModel.requestFind` → `scopedSearchFocusRequest`). The
/// owner binds a `@FocusState` to `isFocused` and the query `Binding`; this
/// view stays state-light so the parent fully controls lifecycle (clearing
/// the query on navigation away, etc.).
///
/// Escape clears a non-empty query (and resigns focus when already empty),
/// matching the global search field's `onExitCommand` behavior.
struct ScopedSearchBar: View {
	@Binding var query: String
	/// Bind the owner's `@FocusState` projected value here so it can both
	/// observe and drive focus.
	@FocusState.Binding var isFocused: Bool
	/// Placeholder, e.g. "Filter songs" or "Filter tracks".
	let placeholder: String

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "magnifyingglass")
				.foregroundStyle(Theme.ink3)
				.font(.system(size: 13))

			TextField(placeholder, text: $query)
				.textFieldStyle(.plain)
				.font(Theme.font(13, weight: .medium))
				.foregroundStyle(Theme.ink)
				.focused($isFocused)
				.onExitCommand {
					if query.isEmpty {
						isFocused = false
					} else {
						query = ""
					}
				}

			if !query.isEmpty {
				Button {
					query = ""
					isFocused = true
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(Theme.ink3)
						.font(.system(size: 13))
				}
				.buttonStyle(.plain)
				.help("Clear filter")
				.accessibilityLabel("Clear filter")
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 7)
		.frame(maxWidth: 320, alignment: .leading)
		.background(Theme.surface2)
		.overlay(
			RoundedRectangle(cornerRadius: 9)
				.stroke(isFocused ? Theme.borderStrong : Theme.border, lineWidth: 1)
		)
		.clipShape(RoundedRectangle(cornerRadius: 9))
		.animation(.easeInOut(duration: 0.12), value: isFocused)
	}
}
