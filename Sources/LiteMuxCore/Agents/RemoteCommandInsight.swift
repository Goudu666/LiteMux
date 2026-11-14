import Foundation

/// What a remote command is about, so a row can say "python train.py in
/// ~/yolo, tmux train" and LiteMux knows where to look.
public struct RemoteCommandInsight: Hashable, Sendable {
    /// The first `cd` target.
    public var directory: String?
    /// tmux sessions it creates, attaches to, types into or reads, in order.
    public var tmuxSessions: [String]
    /// Whether it starts a detached session (`tmux new -d`): a long job to watch.
    public var startsTmuxSession: Bool
    /// Files it writes its output to, or follows with `tail -f`.
    public var logFiles: [String]
    /// The command that matters, without `cd`, `source`, `conda activate` and redirections.
    public var headline: String
    /// No command at all: an interactive login.
    public var isInteractive: Bool

    public init(directory: String? = nil, tmuxSessions: [String] = [], startsTmuxSession: Bool = false,
                logFiles: [String] = [], headline: String = "", isInteractive: Bool = false) {
        self.directory = directory
        self.tmuxSessions = tmuxSessions
        self.startsTmuxSession = startsTmuxSession
        self.logFiles = logFiles
        self.headline = headline
        self.isInteractive = isInteractive
    }

    /// Commands that only set the stage.
    static let setup: Set<String> = [
        "cd", "source", ".", "export", "set", "unset", "ulimit", "umask", "eval", "true", ":", "module", "pushd", "popd",
        "conda", "mamba", "micromamba", "pyenv", "nvm", "echo", "printf", "sleep", "wait", "trap", "shopt", "alias",
        "[", "[[", "test", "mkdir", "hash", "type", "which", "local", "declare", "readonly", "exit", "return", "fi", "done", "esac",
    ]

    /// Long-running-looking commands whose redirections are worth following.
    static let jobLike: Set<String> = [
        "python", "python3", "torchrun", "accelerate", "deepspeed", "bash", "sh", "zsh", "make", "yolo", "jupyter",
        "tensorboard", "uv", "poetry", "srun", "sbatch", "mpirun", "horovodrun", "node", "npm", "cargo", "go",
    ]

    public static func analyze(_ command: String, script: String? = nil) -> RemoteCommandInsight {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = trimmed
        // `bash -s` / `sh` with a heredoc: the script is the real command.
        if let script, !script.isEmpty {
            let first = ShellScan.strippingWrappers(ShellWords.split(trimmed)).first.map { ($0 as NSString).lastPathComponent } ?? ""
            if trimmed.isEmpty || ["bash", "sh", "zsh", "python", "python3"].contains(first) {
                body = trimmed.isEmpty ? script : trimmed + "\n" + script
            }
        }
        if body.isEmpty { return RemoteCommandInsight(headline: "交互式登录", isInteractive: true) }

        var insight = RemoteCommandInsight()
        var headline: String?
        var fallback: String?
        collect(body, into: &insight, headline: &headline, fallback: &fallback, depth: 0)
        insight.headline = clip(headline ?? fallback ?? body)
        return insight
    }

    private static func collect(_ text: String, into insight: inout RemoteCommandInsight,
                                headline: inout String?, fallback: inout String?, depth: Int) {
        guard depth < 4 else { return }
        for segment in ShellScan.segments(text) {
            let words = ShellScan.strippingWrappers(segment.words)
            guard let first = words.first else { continue }
            let name = (first as NSString).lastPathComponent

            if name == "cd", words.count > 1, insight.directory == nil, words[1] != "-" {
                insight.directory = words[1]
            }
            if name == "tmux" {
                readTmux(Array(words.dropFirst()), into: &insight, headline: &headline, fallback: &fallback, depth: depth)
                continue
            }
            if name == "tail", words.contains(where: { $0 == "-f" || $0 == "-F" || $0.hasPrefix("-f") || $0.hasPrefix("-F") || $0 == "--follow" }) {
                if let file = words.dropFirst().last(where: { !$0.hasPrefix("-") && !$0.allSatisfy(\.isNumber) }) {
                    add(file, to: &insight.logFiles)
                }
            }
            if name == "tee" {
                for w in words.dropFirst() where !w.hasPrefix("-") { add(w, to: &insight.logFiles) }
            }
            if ["bash", "sh", "zsh"].contains(name), let c = words.firstIndex(where: { $0 == "-c" || $0 == "-lc" || $0 == "-ic" }),
               c + 1 < words.count {
                collect(words[c + 1], into: &insight, headline: &headline, fallback: &fallback, depth: depth + 1)
                continue
            }
            if jobLike.contains(name) || name.hasPrefix("python") {
                for (k, w) in words.enumerated() where ShellScan.isRedirection(w) && !w.contains("&1") && !w.contains("&2") {
                    let inline = w.drop { $0 == ">" || $0 == "<" || $0 == "&" || $0.isNumber }
                    let target = inline.isEmpty ? (k + 1 < words.count ? words[k + 1] : "") : String(inline)
                    if !target.isEmpty, !target.hasPrefix("/dev/"), !w.contains("<") { add(target, to: &insight.logFiles) }
                }
            }
            let cleaned = clean(words)
            if cleaned.isEmpty { continue }
            // `bash -s` reading a heredoc is not the interesting part; its script is.
            let bareShell = ["bash", "sh", "zsh"].contains(name) && words.dropFirst().allSatisfy { $0.hasPrefix("-") }
            if setup.contains(name) || bareShell {
                if fallback == nil { fallback = cleaned }
            } else if headline == nil {
                headline = cleaned
            }
        }
    }

    private static func readTmux(_ args: [String], into insight: inout RemoteCommandInsight,
                                 headline: inout String?, fallback: inout String?, depth: Int) {
        var i = 0
        // Global options before the subcommand.
        while i < args.count, args[i].hasPrefix("-") {
            if ["-L", "-S", "-f", "-T"].contains(args[i]) { i += 1 }
            i += 1
        }
        guard i < args.count else { return }
        let sub = args[i]
        let rest = Array(args[(i + 1)...])
        let creates = ["new-session", "new"].contains(sub)
        let targets: Set<String> = ["attach-session", "attach", "a", "at", "send-keys", "send", "capture-pane", "capturep",
                                    "kill-session", "has-session", "has", "switch-client", "switchc", "select-window", "selectw",
                                    "list-panes", "lsp", "list-windows", "lsw", "pipe-pane", "pipep", "respawn-pane", "respawnp",
                                    "display-message", "display", "new-window", "neww", "split-window", "splitw", "rename-session"]
        var j = 0
        var detached = false
        var payload: [String] = []
        while j < rest.count {
            let w = rest[j]
            if w == "-d" { detached = true; j += 1; continue }
            if w == "-s" || w == "-t", j + 1 < rest.count {
                // `new -t` names a group, not the session.
                if (creates ? w == "-s" : w == "-t") { add(sessionName(rest[j + 1]), to: &insight.tmuxSessions) }
                j += 2
                continue
            }
            if w.hasPrefix("-") {
                // Options with a value: -n name, -c dir, -x/-y size, -e VAR=1, -F fmt, -S start.
                if ["-n", "-c", "-x", "-y", "-e", "-F", "-S", "-E", "-l", "-f"].contains(w), j + 1 < rest.count {
                    if w == "-c", insight.directory == nil { insight.directory = rest[j + 1] }
                    j += 2
                } else {
                    j += 1
                }
                continue
            }
            payload = Array(rest[j...])
            break
        }
        if creates {
            if detached { insight.startsTmuxSession = true }
            if !payload.isEmpty {
                collect(payload.joined(separator: " "), into: &insight, headline: &headline, fallback: &fallback, depth: depth + 1)
            }
            if headline == nil, let s = insight.tmuxSessions.last { fallback = fallback ?? "tmux new \(s)" }
        } else if targets.contains(sub), sub == "send-keys" || sub == "send" {
            // The keys typed are a command line, minus a trailing Enter / C-m.
            let keys = payload.filter { !["Enter", "C-m", "KPEnter"].contains($0) }
            if !keys.isEmpty, headline == nil {
                headline = clip(keys.joined(separator: " "))
            }
        } else if headline == nil, let s = insight.tmuxSessions.last {
            fallback = fallback ?? "tmux \(sub) \(s)"
        }
    }

    /// `=train:0.1` → `train`.
    static func sessionName(_ target: String) -> String {
        var t = target
        if t.hasPrefix("=") { t.removeFirst() }
        if let colon = t.firstIndex(of: ":") { t = String(t[..<colon]) }
        if let dot = t.firstIndex(of: "."), !t.contains(":") { t = String(t[..<dot]) }
        return t
    }

    private static func clean(_ words: [String]) -> String {
        var out: [String] = []
        var skipNext = false
        for w in words {
            if skipNext { skipNext = false; continue }
            if ShellScan.isRedirection(w) {
                let rest = w.drop { $0 == ">" || $0 == "<" || $0 == "&" || $0.isNumber }
                if rest.isEmpty && !w.hasSuffix("&1") && !w.hasSuffix("&2") { skipNext = true }
                continue
            }
            out.append(w.contains(" ") ? ShellWords.quote(w) : w)
        }
        return out.joined(separator: " ")
    }

    private static func add(_ value: String, to list: inout [String]) {
        if !value.isEmpty, !list.contains(value) { list.append(value) }
    }

    static func clip(_ s: String, to limit: Int = 140) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        return one.count > limit ? String(one.prefix(limit - 1)) + "…" : one
    }
}

/// One place a coding agent's shell command reaches a server.
public struct RemoteTouch: Hashable, Sendable {
    public enum Kind: String, Sendable { case shell, copy }

    public var kind: Kind
    /// `ssh`, `scp`, `rsync` or `sftp`.
    public var tool: String
    /// For `ssh`.
    public var argv: SSHArgv?
    /// The destination as typed: an alias or `user@host`.
    public var destination: String
    public var endpoint: SSHEndpoint
    /// What runs remotely (`ssh`), or a short description of the copy.
    public var command: String
    /// A heredoc fed to ssh's stdin.
    public var script: String?
    /// Remote paths of a copy.
    public var remotePaths: [String]

    public var insight: RemoteCommandInsight {
        switch kind {
        case .shell: return RemoteCommandInsight.analyze(command, script: script)
        case .copy:
            let dir = remotePaths.first.map { p -> String in
                p.hasSuffix("/") ? p : (p as NSString).deletingLastPathComponent
            }
            return RemoteCommandInsight(directory: (dir?.isEmpty ?? true) ? nil : dir, headline: RemoteCommandInsight.clip(command))
        }
    }

    /// Every ssh / scp / rsync / sftp in a local command line.
    public static func find(in commandLine: String) -> [RemoteTouch] {
        var out: [RemoteTouch] = []
        for segment in ShellScan.segments(commandLine) {
            let words = ShellScan.strippingWrappers(segment.words)
            guard let first = words.first else { continue }
            let tool = (first as NSString).lastPathComponent
            switch tool {
            case "ssh":
                guard let argv = SSHArgv.parse(Array(words.dropFirst())), argv.muxCommand == nil, !argv.isQuery else { continue }
                out.append(RemoteTouch(kind: .shell, tool: "ssh", argv: argv, destination: argv.destination,
                                       endpoint: argv.endpoint, command: argv.remoteCommand, script: segment.heredoc,
                                       remotePaths: []))
            case "scp", "rsync", "sftp":
                if let t = copy(tool: tool, args: Array(words.dropFirst())) { out.append(t) }
            default:
                continue
            }
        }
        return out
    }

    static func copy(tool: String, args: [String]) -> RemoteTouch? {
        var port: Int?
        var identity: String?
        var operands: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("-") {
                if tool == "scp" || tool == "sftp", a == "-P", i + 1 < args.count { port = Int(args[i + 1]); i += 2; continue }
                if a == "-i", i + 1 < args.count { identity = args[i + 1]; i += 2; continue }
                if tool == "rsync", a == "-e" || a == "--rsh", i + 1 < args.count {
                    let inner = ShellWords.split(args[i + 1])
                    if let p = inner.firstIndex(of: "-p"), p + 1 < inner.count { port = Int(inner[p + 1]) }
                    i += 2
                    continue
                }
                if ["-o", "-F", "-J", "-c", "-l", "-S"].contains(a) { i += 2; continue }
                i += 1
                continue
            }
            operands.append(a)
            i += 1
        }
        // The first operand of the form [user@]host:path names the server.
        var destination: String?
        var paths: [String] = []
        for op in operands {
            if op.hasPrefix("/") || op.hasPrefix("./") || op.hasPrefix("~") { continue }
            guard let colon = op.firstIndex(of: ":") else {
                if tool == "sftp", destination == nil { destination = op }
                continue
            }
            let host = String(op[..<colon])
            guard !host.isEmpty, !host.contains("/"), host.count > 1 else { continue }
            if destination == nil { destination = host }
            if host == destination { paths.append(String(op[op.index(after: colon)...])) }
        }
        guard let destination else { return nil }
        var endpoint = SSHCommandParser.parseLine(destination) ?? SSHEndpoint(host: destination)
        if let port { endpoint.port = port }
        if let identity { endpoint.identityFile = identity }
        let local = operands.filter { !$0.contains(":") }.map { ($0 as NSString).lastPathComponent }
        let remote = paths.first.map { $0.isEmpty ? "~" : $0 } ?? ""
        let upload = operands.last.map { $0.contains(":") } ?? false
        let summary = upload
            ? "\(tool) \(local.joined(separator: " ")) → \(remote)"
            : "\(tool) \(remote) → \(local.last ?? ".")"
        return RemoteTouch(kind: .copy, tool: tool, argv: nil, destination: destination, endpoint: endpoint,
                           command: summary, script: nil, remotePaths: paths)
    }
}
