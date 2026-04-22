import SwiftUI

/// Displays an artwork image if the Jellyfin `image_tag` is available, otherwise
/// renders a deterministic gradient placeholder matching the design's Artwork.jsx.
struct Artwork: View {
    let url: URL?
    let seed: String
    var size: CGFloat = 120
    var radius: CGFloat = 8
    var overlayLabel: String?

    var body: some View {
        ZStack {
            if let url = url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure, .empty:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
    }

    private var placeholder: some View {
        let palette = Artwork.palette(for: seed)
        return LinearGradient(
            colors: [palette.0, palette.1],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .bottomLeading) {
            if let label = overlayLabel {
                Text(label)
                    .font(Theme.font(size * 0.085, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(size * 0.08)
                    .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 2)
            }
        }
    }

    private static let paletteHexes: [(UInt32, UInt32)] = [
        (0x2B1E5C, 0x887BFF),
        (0x4B0FD6, 0xFF066F),
        (0x0F3D48, 0x57E9C9),
        (0x3A1655, 0xCC2F71),
        (0x1F1A4A, 0x4B7DD7),
        (0x271055, 0xA96BFF),
        (0x541A2E, 0xFF6625),
        (0x10314F, 0x2FA6D9),
        (0x4A2260, 0xECECEC),
        (0x223355, 0x887BFF),
    ]

    static func palette(for seed: String) -> (Color, Color) {
        var hash: UInt32 = 0
        for byte in seed.utf8 {
            hash = hash &* 31 &+ UInt32(byte)
        }
        let pair = paletteHexes[Int(hash) % paletteHexes.count]
        return (Color(hex: pair.0), Color(hex: pair.1))
    }
}
