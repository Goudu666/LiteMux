import Foundation

/// Decides whether an image is a segmentation label map (a mask) and summarises it.
///
/// Masks are usually stored as 8-bit PNGs whose pixel values are class ids
/// (0, 1, 2…), which look pitch black in any normal viewer, or as palette PNGs
/// (VOC style) with a handful of flat colours. Both are recognised from the RGBA
/// pixels: few distinct values, and no smooth gradients.
public struct LabelMap: Equatable, Sendable {
    public struct Label: Equatable, Sendable, Identifiable {
        /// Gray value (class id) for gray masks; packed 0xRRGGBB for colour masks.
        public let value: UInt32
        public let pixels: Int
        public let fraction: Double
        public var id: UInt32 { value }
    }

    public enum Kind: Equatable, Sendable {
        /// Single channel, values are class ids.
        case gray
        /// Flat RGB colours (palette PNG or a coloured mask).
        case color
    }

    public let kind: Kind
    /// Sorted by value.
    public let labels: [Label]

    /// At most this many distinct values for an image to count as a mask.
    public static let maxLabels = 64

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp", "gif", "tif", "tiff", "webp", "heic"]

    public static func isImage(_ fileName: String) -> Bool {
        imageExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// `rgba` is tightly packed 8-bit RGBA, `count` pixels. Large images are sampled.
    public static func analyze(rgba: UnsafeBufferPointer<UInt8>, pixelCount count: Int) -> LabelMap? {
        guard count > 0, rgba.count >= count * 4 else { return nil }
        let stride = max(1, count / 2_000_000)
        var gray = true
        var counts: [UInt32: Int] = [:]
        var sampled = 0
        var i = 0
        while i < count {
            let o = i * 4
            let r = rgba[o], g = rgba[o + 1], b = rgba[o + 2]
            if r != g || g != b { gray = false }
            let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
            counts[key, default: 0] += 1
            if counts.count > maxLabels { return nil }
            sampled += 1
            i += stride
        }
        // A plain black or white image is not a mask worth colouring.
        guard counts.count >= 2 else { return nil }
        let kind: Kind = gray ? .gray : .color
        let labels = counts.map { key, n -> Label in
            Label(value: gray ? key & 0xff : key, pixels: n * stride, fraction: Double(n) / Double(sampled))
        }.sorted { $0.value < $1.value }
        return LabelMap(kind: kind, labels: labels)
    }

    public static func analyze(rgba: [UInt8], pixelCount: Int) -> LabelMap? {
        rgba.withUnsafeBufferPointer { analyze(rgba: $0, pixelCount: pixelCount) }
    }

    /// Gray class ids (0, 1, 2…) look black as-is, so they are shown coloured by default.
    public var needsColoring: Bool { kind == .gray }
}
