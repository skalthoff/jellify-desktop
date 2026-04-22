import SwiftUI

/// Banner shown at the top of the content column when the system is offline.
///
/// Design tokens: `danger` background at 10% opacity, a 3pt `danger` left
/// border, and a `Retry` action that re-evaluates network state and refetches
/// the library via `AppModel`. The banner hides automatically when
/// connectivity returns (debounced by `NetworkMonitor`).
struct OfflineBanner: View {
    let onRetry: () -> Void

    private let message = "You're offline. Playing from downloaded tracks only."

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .accessibilityHidden(true)

            Text(message)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button(action: onRetry) {
                Text("Retry")
                    .font(Theme.font(12, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.danger.opacity(0.25))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.danger, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry network connection")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.10))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.danger)
                .frame(width: 3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityAddTraits(.isStaticText)
    }
}

#Preview("Offline banner") {
    OfflineBanner(onRetry: {})
        .frame(width: 720)
        .padding()
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
