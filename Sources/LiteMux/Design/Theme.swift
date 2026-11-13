import AppKit
import SwiftUI
import SwiftTerm
import LiteMuxCore

/// Semantic surfaces. Everything is derived from the effective appearance so
/// the whole window follows macOS light/dark (or the user's override) without
/// any component hard-coding a colour.
enum Theme {
    static func isDark(_ appearance: NSAppearance?) -> Bool {
        (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Main canvas: terminal background and editor background share it so
    /// panes read as one quiet surface.
    static let canvas = NSColor(name: "lm.canvas") { a in
        isDark(a) ? NSColor(srgbRed: 0.105, green: 0.108, blue: 0.118, alpha: 1)
                  : NSColor(srgbRed: 0.988, green: 0.986, blue: 0.978, alpha: 1)
    }

    static let canvasText = NSColor(name: "lm.canvasText") { a in
        isDark(a) ? NSColor(srgbRed: 0.86, green: 0.86, blue: 0.85, alpha: 1)
                  : NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1)
    }

    /// Top bar and status bar, one step away from the canvas.
    static let chrome = NSColor(name: "lm.chrome") { a in
        isDark(a) ? NSColor(srgbRed: 0.135, green: 0.138, blue: 0.150, alpha: 1)
                  : NSColor(srgbRed: 0.955, green: 0.953, blue: 0.945, alpha: 1)
    }

    static let hairline = NSColor(name: "lm.hairline") { a in
        isDark(a) ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.09)
    }

    static let selection = NSColor(name: "lm.selection") { a in
        isDark(a) ? NSColor(srgbRed: 0.30, green: 0.42, blue: 0.62, alpha: 0.55)
                  : NSColor(srgbRed: 0.62, green: 0.74, blue: 0.95, alpha: 0.55)
    }

    static let caret = NSColor(name: "lm.caret") { a in
        isDark(a) ? NSColor(srgbRed: 0.80, green: 0.80, blue: 0.78, alpha: 1)
                  : NSColor(srgbRed: 0.25, green: 0.25, blue: 0.27, alpha: 1)
    }

    static let online = NSColor.systemGreen
    static let warning = NSColor.systemOrange
    static let offline = NSColor.tertiaryLabelColor

    // SwiftUI mirrors.
    static var canvasColor: SwiftUI.Color { SwiftUI.Color(nsColor: canvas) }
    static var chromeColor: SwiftUI.Color { SwiftUI.Color(nsColor: chrome) }
    static var hairlineColor: SwiftUI.Color { SwiftUI.Color(nsColor: hairline) }

    static func monoFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    // MARK: - Terminal palettes ("darkroom" and "paper")

    private static func c(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16((hex >> 16) & 0xff), green8: UInt16((hex >> 8) & 0xff), blue8: UInt16(hex & 0xff))
    }

    static let darkANSI: [SwiftTerm.Color] = ([UInt32]([
        0x1b1c1f, 0xe06c6c, 0x8cc085, 0xd9b96e, 0x6f9fe0, 0xb88ad6, 0x62b8c2, 0xc9c9c6,
        0x5d6068, 0xf08a8a, 0xa6d69f, 0xeccf8a, 0x8eb7f0, 0xcda5e6, 0x85d0d8, 0xf1f1ee,
    ])).map { Theme.c($0) }

    static let lightANSI: [SwiftTerm.Color] = ([UInt32]([
        0x2a2a2c, 0xc2413b, 0x3f8a3a, 0x9a6b00, 0x2f62b5, 0x8a45a8, 0x1f7f8a, 0xb9b8b2,
        0x6c6c70, 0xd85a54, 0x55a14f, 0xb5850e, 0x4a7fd1, 0xa560c4, 0x2f98a3, 0x4a4a4e,
    ])).map { Theme.c($0) }
}

extension TerminalView {
    /// Applies the LiteMux palette for the view's current appearance.
    func applyLiteMuxTheme() {
        let dark = Theme.isDark(effectiveAppearance)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeBackgroundColor = Theme.canvas.usingColorSpace(.sRGB) ?? Theme.canvas
            nativeForegroundColor = Theme.canvasText.usingColorSpace(.sRGB) ?? Theme.canvasText
            caretColor = Theme.caret.usingColorSpace(.sRGB) ?? Theme.caret
            selectedTextBackgroundColor = Theme.selection.usingColorSpace(.sRGB) ?? Theme.selection
        }
        installColors(dark ? Theme.darkANSI : Theme.lightANSI)
    }
}

extension View {
    /// Hairline separator in the theme colour.
    func hairline(_ edge: Edge) -> some View {
        overlay(alignment: edge.alignment) {
            Rectangle().fill(Theme.hairlineColor)
                .frame(width: edge.isHorizontal ? 1 : nil, height: edge.isHorizontal ? nil : 1)
        }
    }
}

private extension Edge {
    var alignment: Alignment {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
    var isHorizontal: Bool { self == .leading || self == .trailing }
}
