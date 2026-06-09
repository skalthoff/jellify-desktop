import AppKit
import SwiftUI

/// Shared gesture plumbing for multi-selectable track rows. Used by
/// `TrackListRow` (Library Tracks tab, #217) and `TrackRow` (playlist detail,
/// #985) so both row families resolve Cmd-toggle / Shift-range / bare-click
/// through identical arbitration. Extracted from `TrackListRow`'s private
/// helpers when `TrackRow` grew the same selection API.

/// Routes clicks to a multi-select host when one is wired up. When `onSelect`
/// is nil the modifier is a no-op so the row's own play-on-tap interaction
/// (a wrapping `Button` for `TrackListRow`, a bare tap for `TrackRow`) drives
/// clicks exactly as before. When present, three tap gestures disambiguate
/// Cmd-toggle / Shift-range / bare-click and forward the modifier flags so
/// the host can resolve the selection (#74 / #217).
struct SelectionClickModifier: ViewModifier {
    let onSelect: ((NSEvent.ModifierFlags) -> Void)?

    func body(content: Content) -> some View {
        if let onSelect {
            content
                .gesture(
                    TapGesture().modifiers(.command).onEnded { onSelect(.command) }
                )
                .gesture(
                    TapGesture().modifiers(.shift).onEnded { onSelect(.shift) }
                )
                // Bare-tap routes to selection at *normal* priority (not
                // `.simultaneousGesture`) so an interactive subview — the
                // favorite heart — can claim a tap that lands on it via a
                // `.highPriorityGesture` and stop it bubbling to selection.
                // A `.simultaneousGesture` here would always co-fire and
                // re-introduce the heart-tap-clears-selection regression
                // (#217 review), and would co-fire with the Cmd/Shift taps
                // (which would defeat multiselect).
                .gesture(
                    TapGesture().onEnded { onSelect([]) }
                )
        } else {
            content
        }
    }
}

/// Lets the favorite-heart `Button` win the gesture arbitration against the
/// row's bare-tap selection gesture on the multi-select path. When `onSelect`
/// is non-nil the row owns a normal-priority bare-tap `.gesture`; attaching a
/// `.highPriorityGesture` here makes the heart consume taps that land on it,
/// so toggling a favorite never also clears the selection or starts playback.
/// When `onSelect` is nil there is no competing row gesture, so this is a
/// no-op and the plain `Button` action handles the tap unchanged. See #217.
struct FavoriteTapShield: ViewModifier {
    let onSelect: ((NSEvent.ModifierFlags) -> Void)?
    let toggle: () -> Void

    func body(content: Content) -> some View {
        if onSelect != nil {
            content.highPriorityGesture(
                TapGesture().onEnded { toggle() }
            )
        } else {
            content
        }
    }
}

/// Play-on-tap fallback for rows whose single-select path is a bare tap
/// rather than a wrapping `Button` (`TrackRow`). Attaches the tap only when
/// no selection host is wired, so `SelectionClickModifier`'s gestures own
/// every click on the multi-select path. See #985.
struct PlayTapWhenUnselectableModifier: ViewModifier {
    let onSelect: ((NSEvent.ModifierFlags) -> Void)?
    let onPlay: (() -> Void)?

    func body(content: Content) -> some View {
        if onSelect == nil {
            content.onTapGesture(count: 1) { onPlay?() }
        } else {
            content
        }
    }
}
