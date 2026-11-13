import AppKit
import ImageIO
import SwiftUI
import LiteMuxCore

/// A decoded image plus what LiteMux knows about it: pixels for the hover
/// readout, and, for segmentation masks, the class ids and a coloured rendering.
struct PreviewImage {
    let name: String
    let place: String
    let byteCount: Int
    let width: Int
    let height: Int
    let original: CGImage
    let labelMap: LabelMap?
    let colored: CGImage?
    /// Tightly packed RGBA, kept for the pixel readout (nil for very large images).
    let rgba: [UInt8]?

    /// Distinct, calm colours for class ids; id 0 (background) stays dark.
    static let palette: [UInt32] = [
        0x2E7D74, 0xD08A2E, 0x5B7FC7, 0xC0504A, 0x8E6BB8, 0x58A06A, 0xC7699B, 0x4FA3B8,
        0xB89A3E, 0x7C8A99, 0xE07B53, 0x3E9C8F, 0xA8C256, 0x6F5FA8, 0xD9A6A0, 0x2F6F99,
        0xC2A878, 0x9B4F6B, 0x6CB0A0, 0xE0C060,
    ]

    static func color(for value: UInt32, in map: LabelMap) -> UInt32 {
        if map.kind == .color { return value }
        if value == 0 { return 0x1E1F22 }
        if value == 255 && map.labels.count <= 3 { return 0xF2EFE6 } // 0/255 binary masks: white stays white
        let index = map.labels.firstIndex { $0.value == value } ?? Int(value)
        return palette[(index - (map.labels.first?.value == 0 ? 1 : 0) + palette.count) % palette.count]
    }

    static func decode(_ data: Data, name: String, place: String) -> PreviewImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        let count = w * h
        var rgba: [UInt8]?
        var labelMap: LabelMap?
        var colored: CGImage?
        if count > 0, count <= 40_000_000 {
            var buf = [UInt8](repeating: 0, count: count * 4)
            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            if ok {
                rgba = buf
                labelMap = LabelMap.analyze(rgba: buf, pixelCount: count)
                if let map = labelMap, map.kind == .gray {
                    colored = colorize(buf, width: w, height: h, map: map)
                }
            }
        }
        return PreviewImage(name: name, place: place, byteCount: data.count, width: w, height: h, original: image,
                            labelMap: labelMap, colored: colored, rgba: rgba)
    }

    private static func colorize(_ gray: [UInt8], width w: Int, height h: Int, map: LabelMap) -> CGImage? {
        var lut = [UInt32](repeating: 0, count: 256)
        for v in 0..<256 { lut[v] = color(for: UInt32(v), in: map) }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let c = lut[Int(gray[i * 4])]
            out[i * 4] = UInt8((c >> 16) & 0xff)
            out[i * 4 + 1] = UInt8((c >> 8) & 0xff)
            out[i * 4 + 2] = UInt8(c & 0xff)
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8)? {
        guard let rgba, x >= 0, y >= 0, x < width, y < height else { return nil }
        let o = (y * width + x) * 4
        return (rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3])
    }
}

/// Opens previews in their own small windows, like Quick Look.
@MainActor
enum ImagePreviewWindows {
    private static var open: [NSWindow] = []

    static func show(_ image: PreviewImage) {
        let view = ImagePreviewView(image: image)
        let host = NSHostingController(rootView: view)
        let maxSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let scale = min(1, (maxSize.width * 0.7) / CGFloat(image.width), (maxSize.height * 0.7) / CGFloat(image.height))
        let side: CGFloat = image.labelMap != nil ? 220 : 0
        let size = NSSize(width: max(420, CGFloat(image.width) * scale + side), height: max(320, CGFloat(image.height) * scale + 64))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        window.setContentSize(size)
        window.title = image.name
        window.subtitle = image.place
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        open.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated {
                open.removeAll { $0 === (note.object as? NSWindow) }
            }
        }
    }
}

struct ImagePreviewView: View {
    let image: PreviewImage
    @State private var showColored: Bool
    @State private var hover: (x: Int, y: Int)?

    init(image: PreviewImage) {
        self.image = image
        _showColored = State(initialValue: image.colored != nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                canvas
                infoBar
            }
            if let map = image.labelMap {
                Rectangle().fill(Theme.hairlineColor).frame(width: 1)
                legend(map).frame(width: 220)
            }
        }
        .background(Theme.canvasColor)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let fit = min(geo.size.width / CGFloat(image.width), geo.size.height / CGFloat(image.height), 8)
            let w = CGFloat(image.width) * fit, h = CGFloat(image.height) * fit
            ZStack {
                Checkerboard().frame(width: w, height: h)
                Image(decorative: showColored ? (image.colored ?? image.original) : image.original, scale: 1)
                    .resizable()
                    .interpolation(fit > 2 || image.labelMap != nil ? .none : .high)
                    .frame(width: w, height: h)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hover = (Int(p.x / fit), Int(p.y / fit))
                        case .ended: hover = nil
                        }
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(14)
    }

    private var infoBar: some View {
        HStack(spacing: 14) {
            Text("\(image.width)×\(image.height)")
            Text(Int64(image.byteCount).formatted(.byteCount(style: .file)))
            if let hover, let px = image.pixel(x: hover.x, y: hover.y) {
                Text("(\(hover.x), \(hover.y))")
                if let map = image.labelMap, map.kind == .gray {
                    Text("类别 \(px.0)").foregroundStyle(Theme.accentColor)
                } else {
                    Text("RGB \(px.0) \(px.1) \(px.2)" + (px.3 < 255 ? " α\(px.3)" : ""))
                }
            }
            Spacer()
            if image.colored != nil {
                Picker("", selection: $showColored) {
                    Text("原始").tag(false)
                    Text("按类别着色").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .font(.system(size: 11, design: .monospaced).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Theme.chromeColor)
        .hairline(.top)
    }

    private func legend(_ map: LabelMap) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(map.kind == .gray ? "分割标签图" : "调色板掩码").font(.system(size: 12.5, weight: .semibold))
                Text("\(map.labels.count) 个类别 · 按像素占比").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .padding(14)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(map.labels.sorted { $0.fraction > $1.fraction }) { label in
                        LegendRow(label: label, color: PreviewImage.color(for: label.value, in: map), kind: map.kind,
                                  highlighted: hoveredValue(map) == label.value)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(Theme.chromeColor.opacity(0.5))
    }

    private func hoveredValue(_ map: LabelMap) -> UInt32? {
        guard let hover, let px = image.pixel(x: hover.x, y: hover.y) else { return nil }
        return map.kind == .gray ? UInt32(px.0) : UInt32(px.0) << 16 | UInt32(px.1) << 8 | UInt32(px.2)
    }
}

private struct LegendRow: View {
    let label: LabelMap.Label
    let color: UInt32
    let kind: LabelMap.Kind
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(nsColor: NSColor(srgbRed: CGFloat((color >> 16) & 0xff) / 255,
                                                 green: CGFloat((color >> 8) & 0xff) / 255,
                                                 blue: CGFloat(color & 0xff) / 255, alpha: 1)))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.hairlineColor))
                    .frame(width: 14, height: 14)
                Text(kind == .gray ? "id \(label.value)" : String(format: "#%06X", label.value))
                    .font(.system(size: 11.5, weight: highlighted ? .semibold : .regular, design: .monospaced))
                Spacer()
                Text(String(format: label.fraction < 0.001 ? "<0.1%%" : "%.1f%%", label.fraction * 100))
                    .font(.system(size: 11, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                Capsule().fill(Color.primary.opacity(0.06))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accentColor.opacity(0.7)).frame(width: max(2, geo.size.width * label.fraction))
                    }
            }
            .frame(height: 3)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(highlighted ? Theme.raisedColor : .clear))
    }
}

/// Transparency backdrop.
private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for row in 0..<Int(ceil(size.height / s)) {
                for col in 0..<Int(ceil(size.width / s)) where (row + col) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)),
                             with: .color(Color.primary.opacity(0.05)))
                }
            }
        }
    }
}
