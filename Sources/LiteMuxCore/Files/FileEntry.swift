import Foundation

/// A directory entry, local or remote.
public struct FileEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case file, directory, symlink, other }

    public var name: String
    public var path: String
    public var kind: Kind
    /// For symlinks: whether the target turned out to be a directory.
    public var symlinkIsDirectory: Bool
    public var size: UInt64
    public var permissions: UInt32?
    public var modified: Date?

    public init(name: String, path: String, kind: Kind, symlinkIsDirectory: Bool = false,
                size: UInt64 = 0, permissions: UInt32? = nil, modified: Date? = nil) {
        self.name = name
        self.path = path
        self.kind = kind
        self.symlinkIsDirectory = symlinkIsDirectory
        self.size = size
        self.permissions = permissions
        self.modified = modified
    }

    public var id: String { path }
    public var isHidden: Bool { name.hasPrefix(".") }
    public var behavesAsDirectory: Bool { kind == .directory || (kind == .symlink && symlinkIsDirectory) }

    public var fileExtension: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// Folders first, then files; each group by case-insensitive name.
    public static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            if a.behavesAsDirectory != b.behavesAsDirectory { return a.behavesAsDirectory }
            let c = a.name.compare(b.name, options: [.caseInsensitive, .numeric])
            if c != .orderedSame { return c == .orderedAscending }
            return a.name < b.name
        }
    }
}

public enum RemotePath {
    public static func join(_ dir: String, _ name: String) -> String {
        if dir.isEmpty { return name }
        if dir.hasSuffix("/") { return dir + name }
        return dir + "/" + name
    }

    public static func parent(_ path: String) -> String {
        guard path != "/" else { return "/" }
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let idx = p.lastIndex(of: "/") else { return "." }
        if idx == p.startIndex { return "/" }
        return String(p[..<idx])
    }

    public static func lastComponent(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let idx = p.lastIndex(of: "/") else { return p }
        return String(p[p.index(after: idx)...])
    }

    /// Breadcrumb components: `/home/a/b` → `[("/", "/"), ("home", "/home"), …]`.
    public static func breadcrumbs(_ path: String) -> [(name: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        var acc = ""
        for part in path.split(separator: "/") {
            acc += "/" + part
            result.append((String(part), acc))
        }
        return result
    }
}

/// Decides whether a file may be opened in the built-in editor.
public enum TextFileGate {
    public static let maxEditableSize: UInt64 = 5 * 1024 * 1024
    public static let sniffLength = 8192

    public enum Verdict: Equatable, Sendable {
        case editable
        case tooLarge(UInt64)
        case binary
    }

    public static func check(size: UInt64) -> Verdict? {
        size > maxEditableSize ? .tooLarge(size) : nil
    }

    public static func check(head: Data) -> Verdict {
        head.contains(0) ? .binary : .editable
    }

    public static let knownTextExtensions: Set<String> = [
        "py", "yaml", "yml", "json", "toml", "sh", "bash", "zsh", "md", "txt", "log", "conf", "cfg", "ini",
        "csv", "tsv", "js", "ts", "c", "h", "cpp", "hpp", "cc", "cu", "swift", "go", "rs", "java", "rb",
        "env", "xml", "html", "css", "sql", "lua", "r", "ipynb", "gitignore", "dockerfile", "makefile",
    ]

    public static let knownBinaryExtensions: Set<String> = [
        "pt", "pth", "ckpt", "safetensors", "bin", "onnx", "npy", "npz", "pkl", "h5", "zip", "gz", "tgz",
        "tar", "xz", "7z", "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "mp4", "mov", "pdf", "so",
        "o", "a", "dylib", "exe", "whl", "parquet", "arrow", "db", "sqlite",
    ]
}

/// Picks a non-colliding download destination: `name.txt`, `name 2.txt`, …
public enum DownloadNaming {
    public static func uniqueURL(in directory: URL, for name: String, exists: (URL) -> Bool) -> URL {
        let candidate = directory.appendingPathComponent(name)
        if !exists(candidate) { return candidate }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        var n = 2
        while true {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let url = directory.appendingPathComponent(next)
            if !exists(url) { return url }
            n += 1
        }
    }
}

public extension UInt64 {
    /// `412G`, `1.2G`, `830M` style binary units for the status bar and file sizes.
    var compactByteString: String {
        let units = ["B", "K", "M", "G", "T", "P"]
        var value = Double(self)
        var i = 0
        while value >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
        if i == 0 { return "\(self)B" }
        if value >= 100 { return String(format: "%.0f%@", value, units[i]) }
        return String(format: "%.1f%@", value, units[i])
    }
}
