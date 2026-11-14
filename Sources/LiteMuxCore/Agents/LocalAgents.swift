import Foundation

/// The coding agents LiteMux recognises in the local process tree.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode, codex, antigravity, cursor, windsurf, gemini, aider, opencode, goose, amp

    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .gemini: return "Gemini CLI"
        case .aider: return "Aider"
        case .opencode: return "OpenCode"
        case .goose: return "Goose"
        case .amp: return "Amp"
        }
    }

    /// Two letters for the little badge in front of a row.
    public var monogram: String {
        switch self {
        case .claudeCode: return "CC"
        case .codex: return "CX"
        case .antigravity: return "AG"
        case .cursor: return "CU"
        case .windsurf: return "WS"
        case .gemini: return "GE"
        case .aider: return "AI"
        case .opencode: return "OC"
        case .goose: return "GO"
        case .amp: return "AM"
        }
    }

    /// Recognises an agent from one process's command line.
    public static func detect(command: String) -> AgentKind? {
        let lower = command.lowercased()
        let words = lower.split(separator: " ", maxSplits: 3).map(String.init)
        let names = words.prefix(2).map { ($0 as NSString).lastPathComponent }
        func named(_ n: String) -> Bool { names.contains(n) }

        if named("claude") || lower.contains("@anthropic-ai/claude-code") || lower.contains("/.claude/local/")
            || lower.contains("claude-code/cli") || lower.contains("/.claude/shell-snapshots/") { return .claudeCode }
        if named("codex") || lower.contains("@openai/codex") || names.first?.hasPrefix("codex-") == true { return .codex }
        if lower.contains("antigravity") { return .antigravity }
        if lower.contains("/cursor.app/") || named("cursor-agent") { return .cursor }
        if lower.contains("windsurf") { return .windsurf }
        if named("gemini") || lower.contains("@google/gemini-cli") { return .gemini }
        if named("aider") { return .aider }
        if named("opencode") || lower.contains("opencode-ai") { return .opencode }
        if named("goose") { return .goose }
        if named("amp") || lower.contains("@sourcegraph/amp") { return .amp }
        return nil
    }

    /// The `clientInfo.name` an MCP client sends to LiteMux Bridge.
    public static func fromClientName(_ name: String) -> AgentKind? {
        let n = name.lowercased()
        if n.contains("claude") { return .claudeCode }
        if n.contains("codex") { return .codex }
        if n.contains("antigravity") { return .antigravity }
        if n.contains("cursor") { return .cursor }
        if n.contains("windsurf") { return .windsurf }
        if n.contains("gemini") { return .gemini }
        if n.contains("opencode") { return .opencode }
        if n.contains("goose") { return .goose }
        if n.contains("amp") { return .amp }
        return nil
    }
}

/// One line of `ps`.
public struct LocalProcess: Hashable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    /// Seconds since it started.
    public var elapsed: TimeInterval
    public var command: String

    public init(pid: Int32, ppid: Int32, elapsed: TimeInterval, command: String) {
        self.pid = pid
        self.ppid = ppid
        self.elapsed = elapsed
        self.command = command
    }

    /// `ps` shows arguments joined by spaces; good enough for ssh, whose
    /// remote command is joined the same way before it reaches the server.
    public var words: [String] { command.split(separator: " ").map(String.init) }

    public var executableName: String {
        (String(command.prefix { $0 != " " }) as NSString).lastPathComponent
    }
}

public enum ProcessTable {
    public static let psPath = "/bin/ps"
    public static let psArguments = ["-axww", "-o", "pid=,ppid=,etime=,command="]

    public static func parse(_ output: String) -> [LocalProcess] {
        var out: [LocalProcess] = []
        for raw in output.split(separator: "\n") {
            var rest = Substring(raw)
            func field() -> Substring? {
                rest = rest.drop { $0 == " " || $0 == "\t" }
                guard !rest.isEmpty else { return nil }
                let f = rest.prefix { $0 != " " && $0 != "\t" }
                rest = rest.dropFirst(f.count)
                return f
            }
            guard let p = field(), let pid = Int32(p), let pp = field(), let ppid = Int32(pp),
                  let e = field(), let elapsed = parseElapsed(String(e)) else { continue }
            let command = rest.drop { $0 == " " || $0 == "\t" }
            guard !command.isEmpty else { continue }
            out.append(LocalProcess(pid: pid, ppid: ppid, elapsed: elapsed, command: String(command)))
        }
        return out
    }

    /// `[[dd-]hh:]mm:ss`.
    public static func parseElapsed(_ s: String) -> TimeInterval? {
        var days = 0.0
        var clock = Substring(s)
        if let dash = s.firstIndex(of: "-") {
            guard let d = Double(s[..<dash]) else { return nil }
            days = d
            clock = s[s.index(after: dash)...]
        }
        let parts = clock.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        var seconds = 0.0
        for p in parts { seconds = seconds * 60 + p! }
        return days * 86_400 + seconds
    }
}

/// An `ssh` running on this Mac that LiteMux did not start.
public struct ObservedSSH: Hashable, Sendable, Identifiable {
    public var pid: Int32
    /// Coding agent above it in the process tree; nil for a terminal the user typed in.
    public var agent: AgentKind?
    public var agentPID: Int32?
    /// The app it runs under when it is not an agent: "iTerm2", "Terminal", "Ghostty".
    public var app: String?
    public var argv: SSHArgv
    public var elapsed: TimeInterval

    public var id: Int32 { pid }
    public var insight: RemoteCommandInsight { RemoteCommandInsight.analyze(argv.remoteCommand) }
}

/// A ControlPersist master in the background (`ssh: <socket> [mux]`).
public struct ObservedMaster: Hashable, Sendable, Identifiable {
    public var pid: Int32
    public var socketPath: String
    public var id: Int32 { pid }
}

public enum LocalSSHScan {
    public struct Result: Equatable, Sendable {
        public var connections: [ObservedSSH]
        public var masters: [ObservedMaster]
    }

    /// Picks out ssh sessions and masters. LiteMux's own (its terminals, SFTP,
    /// probes and Bridge calls, all under `controlDirectory`) are left out,
    /// as is anything below LiteMux in the tree unless an agent sits between.
    public static func scan(_ processes: [LocalProcess], selfPID: Int32, controlDirectory: String) -> Result {
        var byPID: [Int32: LocalProcess] = [:]
        for p in processes { byPID[p.pid] = p }
        var connections: [ObservedSSH] = []
        var masters: [ObservedMaster] = []

        for p in processes {
            if let socket = SSHArgv.muxMasterSocket(fromTitle: p.command) {
                if !socket.hasPrefix(controlDirectory) { masters.append(ObservedMaster(pid: p.pid, socketPath: socket)) }
                continue
            }
            guard p.executableName == "ssh", !p.command.contains(controlDirectory + "/") else { continue }
            // ProxyJump / ProxyCommand helpers are children of another ssh.
            if let parent = byPID[p.ppid], parent.executableName == "ssh" { continue }
            guard let argv = SSHArgv.parse(Array(p.words.dropFirst())), argv.muxCommand == nil, !argv.isQuery else { continue }

            var agent: AgentKind?
            var agentPID: Int32?
            var app: String?
            var ours = false
            var cursor = p.ppid
            var hops = 0
            while cursor > 1, hops < 40, let a = byPID[cursor] {
                if a.pid == selfPID { ours = true; break }
                if let kind = AgentKind.detect(command: a.command) { agent = kind; agentPID = a.pid; break }
                if app == nil, let name = appName(a.command) { app = name }
                cursor = a.ppid
                hops += 1
            }
            if ours { continue }
            if agent != nil { app = nil }
            connections.append(ObservedSSH(pid: p.pid, agent: agent, agentPID: agentPID, app: app, argv: argv, elapsed: p.elapsed))
        }
        connections.sort { ($0.agent == nil ? 1 : 0, $0.elapsed) < ($1.agent == nil ? 1 : 0, $1.elapsed) }
        return Result(connections: connections, masters: masters)
    }

    /// `/Applications/iTerm.app/Contents/MacOS/iTerm2` → `iTerm2`.
    static func appName(_ command: String) -> String? {
        guard let range = command.range(of: ".app/") else { return nil }
        let before = command[..<range.lowerBound]
        let name = before.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }
}
