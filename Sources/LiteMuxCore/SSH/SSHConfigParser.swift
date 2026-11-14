import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One concrete, directly connectable host found in `~/.ssh/config`.
public struct SSHConfigHost: Hashable, Sendable {
    public var alias: String
    public var otherAliases: [String]
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?
    public var sourceFile: String

    /// The dimmed second line in the sidebar.
    public var subtitle: String {
        var target = hostName ?? alias
        if let user { target = "\(user)@\(target)" }
        if let port, port != 22 { target += ":\(port)" }
        var parts: [String] = []
        if !otherAliases.isEmpty { parts.append(otherAliases.joined(separator: ", ")) }
        if target != alias { parts.append(target) }
        if let proxyJump { parts.append("via \(proxyJump)") }
        return parts.joined(separator: " · ")
    }
}

/// Read-only parser for OpenSSH client configuration.
///
/// - Follows `Include` recursively (globs, `~`, paths relative to `~/.ssh`).
/// - Skips `Host` blocks whose patterns contain `*`, `?` or `!`, and `Match` blocks.
/// - Never writes anything.
public struct SSHConfigParser {
    public var home: String
    public var readFile: (String) -> String?
    public var expandGlob: (String) -> [String]
    public var maxIncludeDepth = 16

    public init(home: String = NSHomeDirectory(),
                readFile: @escaping (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
                expandGlob: @escaping (String) -> [String] = SSHConfigParser.systemGlob) {
        self.home = home
        self.readFile = readFile
        self.expandGlob = expandGlob
    }

    public var userConfigPath: String { home + "/.ssh/config" }

    public func parseUserConfig() -> [SSHConfigHost] {
        parse(path: userConfigPath)
    }

    public func parse(path: String) -> [SSHConfigHost] {
        var state = State()
        var visited = Set<String>()
        process(path: path, depth: 0, state: &state, visited: &visited)
        state.flush()
        var seen = Set<String>()
        return state.hosts.filter { seen.insert($0.alias).inserted }
    }

    /// Parses configuration text directly (used by tests).
    public func parse(text: String, sourceFile: String = "config") -> [SSHConfigHost] {
        var state = State()
        var visited = Set<String>()
        process(text: text, sourceFile: sourceFile, depth: 0, state: &state, visited: &visited)
        state.flush()
        var seen = Set<String>()
        return state.hosts.filter { seen.insert($0.alias).inserted }
    }

    // MARK: - Internals

    private struct State {
        var hosts: [SSHConfigHost] = []
        var current: SSHConfigHost? = nil
        /// true while inside a block we are ignoring (wildcard Host or Match).
        var ignoring = false

        mutating func flush() {
            if let current { hosts.append(current) }
            current = nil
        }
    }

    private func process(path: String, depth: Int, state: inout State, visited: inout Set<String>) {
        guard depth <= maxIncludeDepth, !visited.contains(path), let text = readFile(path) else { return }
        visited.insert(path)
        process(text: text, sourceFile: path, depth: depth, state: &state, visited: &visited)
    }

    private func process(text: String, sourceFile: String, depth: Int, state: inout State, visited: inout Set<String>) {
        for rawLine in text.components(separatedBy: .newlines) {
            guard let (keyword, args) = Self.splitDirective(rawLine) else { continue }
            switch keyword {
            case "host":
                state.flush()
                let patterns = args
                let isPattern = patterns.contains { $0.contains("*") || $0.contains("?") || $0.hasPrefix("!") }
                if isPattern || patterns.isEmpty {
                    state.ignoring = true
                } else {
                    state.ignoring = false
                    state.current = SSHConfigHost(alias: patterns[0], otherAliases: Array(patterns.dropFirst()),
                                                  hostName: nil, user: nil, port: nil, identityFile: nil,
                                                  proxyJump: nil, sourceFile: sourceFile)
                }
            case "match":
                state.flush()
                state.ignoring = true
            case "include":
                for pattern in args {
                    for file in resolveInclude(pattern) {
                        process(path: file, depth: depth + 1, state: &state, visited: &visited)
                    }
                }
            default:
                guard !state.ignoring, state.current != nil, let value = args.first else { continue }
                switch keyword {
                case "hostname": if state.current!.hostName == nil { state.current!.hostName = value }
                case "user": if state.current!.user == nil { state.current!.user = value }
                case "port": if state.current!.port == nil { state.current!.port = Int(value) }
                case "identityfile": if state.current!.identityFile == nil { state.current!.identityFile = value }
                case "proxyjump": if state.current!.proxyJump == nil, value.lowercased() != "none" { state.current!.proxyJump = value }
                default: break
                }
            }
        }
    }

    private func resolveInclude(_ pattern: String) -> [String] {
        var path = ShellWords.expandTilde(pattern, home: home)
        if !path.hasPrefix("/") { path = home + "/.ssh/" + path }
        if path.contains("*") || path.contains("?") || path.contains("[") {
            return expandGlob(path).sorted()
        }
        return [path]
    }

    /// Splits `Keyword value value` or `Keyword=value`; returns a lower-cased keyword.
    static func splitDirective(_ rawLine: String) -> (String, [String])? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { return nil }
        var keyword = ""
        var rest = Substring(line)
        if let idx = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) {
            keyword = String(line[..<idx])
            rest = line[idx...]
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            if rest.first == "=" { rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) }
        } else {
            keyword = line
            rest = ""
        }
        // Strip a trailing comment introduced by whitespace + '#'.
        var args = ShellWords.split(String(rest))
        if let hash = args.firstIndex(where: { $0.hasPrefix("#") }) { args = Array(args[..<hash]) }
        return (keyword.lowercased(), args)
    }

    public static func systemGlob(_ pattern: String) -> [String] {
        var gt = glob_t()
        defer { globfree(&gt) }
        guard glob(pattern, 0, nil, &gt) == 0 else { return [] }
        var result: [String] = []
        for i in 0..<Int(gt.gl_pathc) {
            if let p = gt.gl_pathv[i], let s = String(validatingCString: p) { result.append(s) }
        }
        return result
    }
}
