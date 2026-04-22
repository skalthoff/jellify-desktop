import SwiftUI
import AppKit
import CoreText

/// Jellify brand tokens. Mirrors `core/src/configs/tamagui.config.ts` and the
/// design's `jellify.css`. For M2 we ship the `purple` preset in `dark` mode.
enum Theme {
    // Surfaces
    static let bg = Color(hex: 0x0C0622)        // Figma deep purple
    static let bgAlt = Color(hex: 0x140B30)
    static let surface = Color(rgba: (126, 114, 175, 0.08))
    static let surface2 = Color(rgba: (126, 114, 175, 0.14))
    static let rowHover = Color(rgba: (126, 114, 175, 0.10))

    // Text
    static let ink = Color.white
    static let ink2 = Color(rgba: (126, 114, 175, 1.0))
    static let ink3 = Color(rgba: (126, 114, 175, 0.65))

    // Brand
    static let primary = Color(hex: 0x887BFF)
    static let accent = Color(hex: 0xCC2F71)
    static let accentHot = Color(hex: 0xFF066F)
    static let teal = Color(hex: 0x57E9C9)

    // Status
    static let danger = Color(hex: 0xFF4757)
    static let warning = Color(hex: 0xF5A623)

    // Borders
    static let border = Color(rgba: (126, 114, 175, 0.18))
    static let borderStrong = Color(rgba: (126, 114, 175, 0.35))

    // Type
    static func font(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        let name: String
        switch weight {
        case .black: name = italic ? "Figtree-BlackItalic" : "Figtree-Black"
        case .heavy: name = "Figtree-ExtraBold"
        case .bold: name = "Figtree-Bold"
        case .semibold: name = "Figtree-SemiBold"
        case .medium: name = "Figtree-Medium"
        case .light, .thin, .ultraLight: name = "Figtree-Light"
        default: name = italic ? "Figtree-Italic" : "Figtree-Regular"
        }
        return Font.custom(name, size: size).weight(weight)
    }
}

enum FontRegistration {
    private static var registered = false

    /// Registers the bundled Figtree fonts with CoreText so SwiftUI can resolve
    /// them by name. Safe to call more than once.
    static func register() {
        guard !registered else { return }
        registered = true
        let bundle = Bundle.module
        for name in [
            "Figtree-Regular", "Figtree-Italic", "Figtree-Medium",
            "Figtree-SemiBold", "Figtree-Bold", "Figtree-ExtraBold",
            "Figtree-Black", "Figtree-Light",
        ] {
            guard let url = bundle.url(forResource: name, withExtension: "otf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
    init(rgba: (Double, Double, Double, Double)) {
        self.init(.sRGB, red: rgba.0 / 255.0, green: rgba.1 / 255.0, blue: rgba.2 / 255.0, opacity: rgba.3)
    }
}
