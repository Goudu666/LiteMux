import AppKit
import SwiftUI
import SwiftTerm
import LiteMuxCore

/// One colour family's surfaces for one brightness.
struct Tones {
    var canvas: UInt32
    var text: UInt32
    var chrome: UInt32
    var sidebar: UInt32, sidebarAlpha: CGFloat
    var raised: UInt32, raisedAlpha: CGFloat = 1
    var hairline: UInt32, hairlineAlpha: CGFloat
    var accent: UInt32
    var selectionAlpha: CGFloat
}

/// A named colour family with a light and a dark rendition.
struct ColorThemeSpec {
    let id: PersistedState.ColorTheme
    let name: String
    let light: Tones
    let dark: Tones

    static func of(_ id: PersistedState.ColorTheme) -> ColorThemeSpec {
        switch id {
        case .paper: return paper
        case .apricot: return apricot
        case .mist: return mist
        case .sakura: return sakura
        }
    }

    static let all: [ColorThemeSpec] = PersistedState.ColorTheme.allCases.map { ColorThemeSpec.of($0) }

    /// Warm paper, ink text, deep teal.
    static let paper = ColorThemeSpec(id: .paper, name: "纸面 · 墨青",
        light: Tones(canvas: 0xFBFAF6, text: 0x2F2E2A, chrome: 0xF2F0EA, sidebar: 0xEDEAE2, sidebarAlpha: 0.78,
                     raised: 0xFFFEFB, hairline: 0x4A3F2A, hairlineAlpha: 0.12, accent: 0x2E7D74, selectionAlpha: 0.20),
        dark: Tones(canvas: 0x1B1C20, text: 0xDCDCD8, chrome: 0x222327, sidebar: 0x18191C, sidebarAlpha: 0.35,
                    raised: 0xFFFFFF, raisedAlpha: 0.075, hairline: 0xFFFFFF, hairlineAlpha: 0.08, accent: 0x6CC3B6, selectionAlpha: 0.28))

    /// Cream and apricot, like late-afternoon light on paper.
    static let apricot = ColorThemeSpec(id: .apricot, name: "杏橘",
        light: Tones(canvas: 0xFCF9F4, text: 0x33291F, chrome: 0xF6EEE3, sidebar: 0xF3E6D6, sidebarAlpha: 0.82,
                     raised: 0xFFFDF8, hairline: 0x6B4A22, hairlineAlpha: 0.13, accent: 0xD46A2A, selectionAlpha: 0.20),
        dark: Tones(canvas: 0x1F1B18, text: 0xE4DCD2, chrome: 0x28221D, sidebar: 0x1E1814, sidebarAlpha: 0.42,
                    raised: 0xFFF2E4, raisedAlpha: 0.08, hairline: 0xFFE6CC, hairlineAlpha: 0.09, accent: 0xF2A263, selectionAlpha: 0.28))

    /// Cool morning haze with a clear blue.
    static let mist = ColorThemeSpec(id: .mist, name: "雾蓝",
        light: Tones(canvas: 0xF8FAFC, text: 0x222A36, chrome: 0xEDF1F6, sidebar: 0xE5ECF4, sidebarAlpha: 0.82,
                     raised: 0xFFFFFF, hairline: 0x2A3B55, hairlineAlpha: 0.12, accent: 0x3A6FC6, selectionAlpha: 0.18),
        dark: Tones(canvas: 0x171B22, text: 0xD8DEE8, chrome: 0x1E232C, sidebar: 0x131720, sidebarAlpha: 0.42,
                    raised: 0xE8F0FF, raisedAlpha: 0.075, hairline: 0xD8E4FF, hairlineAlpha: 0.09, accent: 0x84AAEE, selectionAlpha: 0.28))

    /// Blush paper with a cherry-blossom pink.
    static let sakura = ColorThemeSpec(id: .sakura, name: "樱粉",
        light: Tones(canvas: 0xFDF9FA, text: 0x352A2F, chrome: 0xF8EDF0, sidebar: 0xF5E3E9, sidebarAlpha: 0.82,
                     raised: 0xFFFDFE, hairline: 0x6A3448, hairlineAlpha: 0.12, accent: 0xCF5786, selectionAlpha: 0.18),
        dark: Tones(canvas: 0x1F1A1D, text: 0xE8DDE2, chrome: 0x282126, sidebar: 0x1D161A, sidebarAlpha: 0.42,
                    raised: 0xFFE6EF, raisedAlpha: 0.075, hairline: 0xFFD6E5, hairlineAlpha: 0.09, accent: 0xF29CBD, selectionAlpha: 0.28))
}

/// The selected colour family. SwiftUI views observe it; AppKit colours read
/// it at draw time.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()
    var current: PersistedState.ColorTheme = .paper {
        didSet { Theme.liveID = current }
    }
}

/// Semantic surfaces. Every colour follows both the effective appearance
/// (light/dark) and the selected colour family, so no component hard-codes one.
enum Theme {
    static func isDark(_ appearance: NSAppearance?) -> Bool {
        (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Read by AppKit colour providers without registering SwiftUI observation.
    nonisolated(unsafe) static var liveID: PersistedState.ColorTheme = .paper

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    /// How each token is made from a family's tones.
    enum Recipe {
        static let canvas: (Tones) -> NSColor = { Theme.rgb($0.canvas) }
        static let canvasText: (Tones) -> NSColor = { Theme.rgb($0.text) }
        static let chrome: (Tones) -> NSColor = { Theme.rgb($0.chrome) }
        static let sidebarTint: (Tones) -> NSColor = { Theme.rgb($0.sidebar, $0.sidebarAlpha) }
        static let raised: (Tones) -> NSColor = { Theme.rgb($0.raised, $0.raisedAlpha) }
        static let hairline: (Tones) -> NSColor = { Theme.rgb($0.hairline, $0.hairlineAlpha) }
        static let accent: (Tones) -> NSColor = { Theme.rgb($0.accent) }
        static let selection: (Tones) -> NSColor = { Theme.rgb($0.accent, $0.selectionAlpha) }
    }

    /// One family's tokens, fixed to that family (used by SwiftUI so a switch
    /// produces new colour values and the views redraw).
    struct Tokens {
        let canvas, chrome, sidebarTint, raised, hairline, accent: NSColor

        init(_ spec: ColorThemeSpec) {
            func pick(_ f: @escaping (Tones) -> NSColor) -> NSColor {
                NSColor(name: nil) { a in f(Theme.isDark(a) ? spec.dark : spec.light) }
            }
            canvas = pick(Recipe.canvas)
            chrome = pick(Recipe.chrome)
            sidebarTint = pick(Recipe.sidebarTint)
            raised = pick(Recipe.raised)
            hairline = pick(Recipe.hairline)
            accent = pick(Recipe.accent)
        }
    }

    private static let tokenSets: [PersistedState.ColorTheme: Tokens] =
        Dictionary(uniqueKeysWithValues: ColorThemeSpec.all.map { ($0.id, Tokens($0)) })

    static func tokens(_ id: PersistedState.ColorTheme) -> Tokens { tokenSets[id] ?? Tokens(.paper) }

    // MARK: AppKit tokens: stable objects that resolve the current family when drawn.

    private static func live(_ f: @escaping (Tones) -> NSColor) -> NSColor {
        NSColor(name: nil) { a in
            let spec = ColorThemeSpec.of(liveID)
            return f(isDark(a) ? spec.dark : spec.light)
        }
    }

    static let canvas = live(Recipe.canvas)
    static let canvasText = live(Recipe.canvasText)
    static let chrome = live(Recipe.chrome)
    static let hairline = live(Recipe.hairline)
    static let accent = live(Recipe.accent)
    static let selection = live(Recipe.selection)
    static let caret = live(Recipe.accent)

    static let online = NSColor(name: nil) { a in isDark(a) ? rgb(0x5CC48A) : rgb(0x3F9D66) }
    static let warning = NSColor(name: nil) { a in isDark(a) ? rgb(0xE6A85A) : rgb(0xD08A2E) }
    static let offline = NSColor.tertiaryLabelColor

    // MARK: SwiftUI mirrors: reading the store makes views redraw on a switch.

    private static var observed: Tokens { tokens(ThemeStore.shared.current) }
    static var canvasColor: SwiftUI.Color { SwiftUI.Color(nsColor: observed.canvas) }
    static var chromeColor: SwiftUI.Color { SwiftUI.Color(nsColor: observed.chrome) }
    static var hairlineColor: SwiftUI.Color { SwiftUI.Color(nsColor: observed.hairline) }
    static var accentColor: SwiftUI.Color { SwiftUI.Color(nsColor: observed.accent) }
    static var raisedColor: SwiftUI.Color { SwiftUI.Color(nsColor: observed.raised) }
    static var sidebarTintColor: SwiftUI.Color { SwiftUI.Color(nsColor: observed.sidebarTint) }

    /// Swatch for menus and pickers (light rendition of the accent).
    static func swatch(_ id: PersistedState.ColorTheme) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: rgb(ColorThemeSpec.of(id).light.accent))
    }

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
