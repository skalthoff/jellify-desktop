import SwiftUI

/// Discover — the "find something new" surface. For now this is a simple
/// header + Instant Mix CTA (#248). Richer recommendations (recently added,
/// more like this, genre tiles, etc.) land in follow-ups.
///
/// Title is italic 34pt, subline 14pt `ink2`, right-aligned primary "Start
/// Instant Mix" + ghost "Generate new mix" — per `06-screen-specs.md`.
struct DiscoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .background(backgroundWash)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("DISCOVER")
                    .font(Theme.font(12, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .tracking(2)
                Text("Discover")
                    .font(Theme.font(34, weight: .black, italic: true))
                    .foregroundStyle(Theme.ink)
                Text("A fresh mix seeded from your library — press play and keep going.")
                    .font(Theme.font(14, weight: .medium))
                    .foregroundStyle(Theme.ink2)
            }
            Spacer()
            HStack(spacing: 10) {
                // TODO: #144 / #327 — Instant Mix FFI + modal not yet wired.
                // The AppModel stub logs to stdout for now so the CTA has a
                // landing pad.
                Button {
                    model.startInstantMix()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .bold))
                        Text("Start Instant Mix")
                            .font(Theme.font(13, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(Theme.accent)
                    )
                    .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 6)
                }
                .buttonStyle(.plain)

                Button {
                    // TODO: #144 / #327 — Regenerate also routes through the
                    // Instant Mix FFI once it lands. Same stub for now.
                    model.startInstantMix()
                } label: {
                    Text("Generate new mix")
                        .font(Theme.font(13, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .stroke(Theme.borderStrong, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var backgroundWash: some View {
        LinearGradient(
            colors: [Theme.accent.opacity(0.15), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .blur(radius: 80)
        .frame(height: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
    }
}
