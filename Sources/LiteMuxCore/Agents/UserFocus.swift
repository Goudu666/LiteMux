import Foundation

/// What the user is looking at in LiteMux, written by the app to
/// `~/.config/litemux/focus.json` so a coding agent can ask "which file do
/// you mean?" instead of guessing.
public struct UserFocus: Codable, Equatable, Sendable {
    public struct Selection: Codable, Equatable, Sendable {
        /// 1-based, inclusive.
        public var startLine: Int
        public var endLine: Int
        public var text: String
        public var truncated: Bool

        public init(startLine: Int, endLine: Int, text: String, truncated: Bool = false) {
            self.startLine = startLine
            self.endLine = endLine
            self.text = text
            self.truncated = truncated
        }
    }

    public struct File: Codable, Equatable, Sendable {
        public var hostID: String
        public var host: String
        public var path: String
        public var cursorLine: Int?
        public var selection: Selection?
        public var unsaved: Bool

        public init(hostID: String, host: String, path: String, cursorLine: Int? = nil,
                    selection: Selection? = nil, unsaved: Bool = false) {
            self.hostID = hostID
            self.host = host
            self.path = path
            self.cursorLine = cursorLine
            self.selection = selection
            self.unsaved = unsaved
        }
    }

    public struct Pane: Codable, Equatable, Sendable {
        public var hostID: String
        public var host: String
        /// The pane's tmux session (`lm_2`, `train`), what `read_terminal` takes.
        public var session: String?
        public var readOnly: Bool

        public init(hostID: String, host: String, session: String?, readOnly: Bool = false) {
            self.hostID = hostID
            self.host = host
            self.session = session
            self.readOnly = readOnly
        }
    }

    public struct Browser: Codable, Equatable, Sendable {
        public var hostID: String
        public var host: String
        public var directory: String
        public var selected: String?

        public init(hostID: String, host: String, directory: String, selected: String? = nil) {
            self.hostID = hostID
            self.host = host
            self.directory = directory
            self.selected = selected
        }
    }

    public var updated: Date
    /// False once LiteMux has quit.
    public var running: Bool
    /// "terminal", "editor" or "none".
    public var view: String
    public var pane: Pane?
    public var file: File?
    public var browser: Browser?
    /// Other open editor tabs, `host:path`.
    public var openFiles: [String]

    public init(updated: Date = Date(), running: Bool = true, view: String = "none", pane: Pane? = nil,
                file: File? = nil, browser: Browser? = nil, openFiles: [String] = []) {
        self.updated = updated
        self.running = running
        self.view = view
        self.pane = pane
        self.file = file
        self.browser = browser
        self.openFiles = openFiles
    }

    /// Equal apart from the timestamp.
    public func sameContent(as other: UserFocus) -> Bool {
        var a = self, b = other
        a.updated = .distantPast
        b.updated = .distantPast
        return a == b
    }

    public static func url(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".config/litemux/focus.json")
    }

    public static func load(home: String = NSHomeDirectory()) -> UserFocus? {
        guard let data = try? Data(contentsOf: url(home: home)) else { return nil }
        return try? JSONDecoder.litemux.decode(UserFocus.self, from: data)
    }

    public func save(home: String = NSHomeDirectory()) throws {
        let u = Self.url(home: home)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder.litemux.encode(self).write(to: u, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }

    /// 1-based line of a UTF-16 offset, and the selected lines, for an editor's text.
    public static func selection(in text: String, location: Int, length: Int, limit: Int = 8192) -> (cursorLine: Int, selection: Selection?) {
        let ns = text as NSString
        let loc = max(0, min(location, ns.length))
        let len = max(0, min(length, ns.length - loc))
        func line(at offset: Int) -> Int {
            var count = 1
            var i = 0
            while i < offset {
                let r = ns.range(of: "\n", options: [], range: NSRange(location: i, length: offset - i))
                if r.location == NSNotFound { break }
                count += 1
                i = r.location + 1
            }
            return count
        }
        let start = line(at: loc)
        guard len > 0 else { return (start, nil) }
        var endOffset = loc + len
        // A selection that ends right after a newline does not include the next line.
        if endOffset > loc, ns.character(at: endOffset - 1) == 10 { endOffset -= 1 }
        let end = max(start, line(at: endOffset))
        var selected = ns.substring(with: NSRange(location: loc, length: len))
        var truncated = false
        if selected.utf8.count > limit {
            selected = String(selected.prefix(limit))
            truncated = true
        }
        return (start, Selection(startLine: start, endLine: end, text: selected, truncated: truncated))
    }

    /// The text `get_user_focus` returns.
    public func describe(now: Date = Date()) -> String {
        var lines: [String] = []
        let age = Int(max(0, now.timeIntervalSince(updated)))
        if !running {
            lines.append("LiteMux 没有在运行（以下是它退出前的状态，\(Self.ago(age))）。")
        } else if age > 120 {
            lines.append("（\(Self.ago(age))更新）")
        }
        switch view {
        case "editor":
            if let f = file {
                var head = "用户正在看文件 \(f.host):\(f.path)"
                if let c = f.cursorLine { head += "，光标在第 \(c) 行" }
                if f.unsaved { head += "（有未保存的修改，以下选区来自编辑器里的版本）" }
                lines.append(head)
            }
        case "terminal":
            if let p = pane {
                var head = "用户正在看 \(p.host) 的终端"
                if let s = p.session { head += "，tmux 会话 \(s)（read_terminal 可读）" }
                if p.readOnly { head += "，只读旁观中" }
                lines.append(head)
            }
        default:
            lines.append("用户当前没有打开终端或文件。")
        }
        if let s = file?.selection, view == "editor" {
            let range = s.startLine == s.endLine ? "第 \(s.startLine) 行" : "第 \(s.startLine)–\(s.endLine) 行"
            lines.append("")
            lines.append("选中了 \(range)\(s.truncated ? "（太长，只给出开头 8 KB）" : "")：")
            lines.append("```")
            lines.append(s.text)
            lines.append("```")
        }
        if let b = browser {
            lines.append("")
            var l = "文件树：\(b.host):\(b.directory)"
            if let sel = b.selected { l += "，选中 \(sel)" }
            lines.append(l)
        }
        let others = openFiles.filter { f in file.map { "\($0.host):\($0.path)" != f } ?? true }
        if !others.isEmpty {
            lines.append("其他打开的文件：" + others.joined(separator: "、"))
        }
        return lines.joined(separator: "\n")
    }

    static func ago(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3600) 小时前"
    }
}
