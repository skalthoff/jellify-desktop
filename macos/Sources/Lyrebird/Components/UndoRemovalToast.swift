import SwiftUI

/// Bottom-anchored toast offering a 10-second undo window after a batch of
/// tracks is removed from a playlist. The host owns the timer and the
/// `AppModel.pendingPlaylistRemoval` stash; this view is presentation-only.
/// Shown by `PlaylistView` (#74 / #985).
struct UndoRemovalToast: View {
    let count: Int
    let onUndo: () -> Void
    let onDismiss: () -> Void

    private var message: String {
        "Removed \(CountStrings.label(count, .tracks))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .accessibilityHidden(true)

            Text(message)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.ink)

            Spacer(minLength: 12)

            Button(action: onUndo) {
                Text("Undo")
                    .font(Theme.font(12, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.accent.opacity(0.28))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.accent, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Undo remove")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgAlt)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.accent).frame(width: 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: Color.black.opacity(0.35), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }
}
