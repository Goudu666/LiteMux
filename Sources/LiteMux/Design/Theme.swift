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

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: name) { a in isDark(a) ? dark : light }
    }

    // "Paper" (light) is the primary look: warm off-white paper, ink-coloured
    // text, one calm teal accent. "Darkroom" mirrors it in low light.

    /// Main canvas: terminal and editor share it so panes read as one surface.
    static let canvas = dynamic("lm.canvas", light: rgb(0xFBFAF6), dark: rgb(0x1B1C20))

    static let canvasText = dynamic("lm.canvasText", light: rgb(0x2F2E2A), dark: rgb(0xDCDCD8))

    /// Top bar and status bar: one quiet step away from the paper.
    static let chrome = dynamic("lm.chrome", light: rgb(0xF2F0EA), dark: rgb(0x222327))

    /// Laid over the native sidebar vibrancy so it stays warm, not grey.
    static let sidebarTint = dynamic("lm.sidebarTint", light: rgb(0xEDEAE2, 0.78), dark: rgb(0x18191C, 0.35))

    /// The selected tab / segment: a sheet of paper lifted off the bar.
    static let raised = dynamic("lm.raised", light: rgb(0xFFFEFB), dark: rgb(0xFFFFFF, 0.075))

    static let hairline = dynamic("lm.hairline", light: rgb(0x4A3F2A, 0.12), dark: rgb(0xFFFFFF, 0.08))

    /// Signature accent: deep teal ink.
    static let accent = dynamic("lm.accent", light: rgb(0x2E7D74), dark: rgb(0x6CC3B6))

    static let selection = dynamic("lm.selection", light: rgb(0x2E7D74, 0.20), dark: rgb(0x6CC3B6, 0.28))

    static let caret = dynamic("lm.caret", light: rgb(0x2E7D74), dark: rgb(0x8AD3C7))

    static let online = dynamic("lm.online", light: rgb(0x3F9D66), dark: rgb(0x5CC48A))
    static let warning = dynamic("lm.warning", light: rgb(0xD08A2E), dark: rgb(0xE6A85A))
    static let offline = NSColor.tertiaryLabelColor

    // SwiftUI mirrors.
    static var canvasColor: SwiftUI.Color { SwiftUI.Color(nsColor: canvas) }
    static var chromeColor: SwiftUI.Color { SwiftUI.Color(nsColor: chrome) }
    static var hairlineColor: SwiftUI.Color { SwiftUI.Color(nsColor: hairline) }
    static var accentColor: SwiftUI.Color { SwiftUI.Color(nsColor: accent) }
    static var raisedColor: SwiftUI.Color { SwiftUI.Color(nsColor: raised) }
    static var sidebarTintColor: SwiftUI.Color { SwiftUI.Color(nsColor: sidebarTint) }

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

    /// Tuned for the warm paper canvas: every hue keeps readable contrast as
    /// text, and green stays soft enough to sit behind a tmux status line.
    static let lightANSI: [SwiftTerm.Color] = ([UInt32]([
        0x3A3934, 0xC0504A, 0x58A06A, 0xB07F22, 0x3B6DB3, 0x9356A3, 0x2B8A86, 0xD6D2C8,
        0x8C887E, 0xD5675F, 0x74B884, 0xC99A3B, 0x5888CC, 0xAD72BD, 0x44A39E, 0x55524B,
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
