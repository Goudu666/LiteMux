import Foundation

/// One `ssh` invocation taken apart: the options that pick the connection,
/// the destination, and the command it runs on the other side.
public struct SSHArgv: Hashable, Sendable {
    /// Option words before (and right after) the destination, without the remote command.
    public var optionWords: [String]
    public var destination: String
    /// What runs remotely, joined the way ssh joins it. Empty for an interactive login.
    public var remoteCommand: String
    /// The endpoint LiteMux would use for the same server (ControlMaster options removed).
    public var endpoint: SSHEndpoint
    /// `-S path` or `-o ControlPath=path`, as written.
    public var controlPath: String?
    /// `-M` or `-o ControlMaster=…`.
    public var controlMaster: String?
    /// `-O check|exit|forward…`: talking to a master, not a session.
    public var muxCommand: String?
    /// `-N`: only forwards ports, runs nothing.
    public var noCommand: Bool
    /// `-L` / `-R` / `-D` specs.
    public var forwards: [String]
    /// `-G` (print config) or `-V`: not a connection at all.
    public var isQuery: Bool

    /// Options whose argument is the next word, from `man ssh`.
    static let valueOptions: Set<Character> = [
        "B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l", "m", "O", "o", "p", "Q", "R", "S", "W", "w",
    ]

    /// Words for `ssh -G …`: the same connection, nothing that runs.
    public var resolveArguments: [String] {
        ["-G"] + optionWords.filter { !["-f", "-N", "-n", "-T", "-t", "-tt", "-M", "-v", "-q"].contains($0) } + [destination]
    }

    /// `words` without the leading `ssh`.
    public static func parse(_ words: [String]) -> SSHArgv? {
        var options: [String] = []
        var destination: String?
        var remote: [String] = []
        var controlPath: String?
        var controlMaster: String?
        var muxCommand: String?
        var noCommand = false
        var forwards: [String] = []
        var isQuery = false

        var i = 0
        while i < words.count {
            let word = words[i]
            if destination != nil, !word.hasPrefix("-") {
                remote.append(contentsOf: words[i...])
                break
            }
            if word == "--" {
                i += 1
                if destination == nil, i < words.count { destination = words[i]; i += 1 }
                if i < words.count { remote.append(contentsOf: words[i...]) }
                break
            }
            if word.hasPrefix("-"), word.count >= 2 {
                options.append(word)
                let flags = Array(word.dropFirst())
                var j = 0
                while j < flags.count {
                    let flag = flags[j]
                    if valueOptions.contains(flag) {
                        let value: String
                        if j + 1 < flags.count {
                            value = String(flags[(j + 1)...])
                        } else {
                            i += 1
                            guard i < words.count else { break }
                            value = words[i]
                            options.append(value)
                        }
                        switch flag {
                        case "S": controlPath = value
                        case "O": muxCommand = value
                        case "L", "R", "D": forwards.append("-\(flag) \(value)")
                        case "o":
                            let (k, v) = splitOption(value)
                            switch k.lowercased() {
                            case "controlpath": controlPath = v
                            case "controlmaster": controlMaster = v
                            case "localforward": forwards.append("-L \(v)")
                            case "remoteforward": forwards.append("-R \(v)")
                            case "dynamicforward": forwards.append("-D \(v)")
                            default: break
                            }
                        default: break
                        }
                        break
                    }
                    switch flag {
                    case "M": controlMaster = controlMaster ?? "yes"
                    case "N": noCommand = true
                    case "G", "V": isQuery = true
                    default: break
                    }
                    j += 1
                }
                i += 1
                continue
            }
            destination = word
            i += 1
        }
        guard let destination, !destination.isEmpty else { return nil }

        // Reuse the paste parser for user/port/identity/jump, then drop the
        // multiplexing options: LiteMux brings its own.
        let line = (options + [destination]).map(ShellWords.quote).joined(separator: " ")
        guard var endpoint = SSHCommandParser.parseLine(line) else { return nil }
        endpoint.options.removeAll { opt in
            let key = opt.split(separator: "=", maxSplits: 1).first.map { $0.lowercased() } ?? ""
            return key.hasPrefix("control") || key == "batchmode" || key == "loglevel"
                || key.hasSuffix("forward") || key == "requesttty" || key == "sessiontype"
        }
        return SSHArgv(optionWords: options, destination: destination,
                       remoteCommand: remote.joined(separator: " "),
                       endpoint: endpoint, controlPath: controlPath, controlMaster: controlMaster,
                       muxCommand: muxCommand, noCommand: noCommand, forwards: forwards, isQuery: isQuery)
    }

    static func splitOption(_ s: String) -> (String, String) {
        if let eq = s.firstIndex(of: "=") {
            return (String(s[..<eq]).trimmingCharacters(in: .whitespaces),
                    String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
        }
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first ?? s, parts.count > 1 ? parts[1] : "")
    }

    /// A process title like `ssh: /Users/me/.ssh/cm-root@gpu:22 [mux]`: a
    /// ControlPersist master that went to the background.
    public static func muxMasterSocket(fromTitle command: String) -> String? {
        guard command.hasPrefix("ssh: "), command.hasSuffix("[mux]") else { return nil }
        let path = command.dropFirst(5).dropLast(5).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    /// `cm-root@connect.westb.seetacloud.com:38192` → user, host, port, for
    /// sockets named with the common `%r@%h:%p` pattern.
    public static func endpoint(fromSocketName path: String) -> SSHEndpoint? {
        var name = (path as NSString).lastPathComponent
        for prefix in ["cm-", "cm_", "ssh-", "ssh_", "mux-", "master-", "control-", "socket-"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        guard let at = name.firstIndex(of: "@"), let colon = name.lastIndex(of: ":"), at < colon,
              let port = Int(name[name.index(after: colon)...]) else { return nil }
        let user = String(name[..<at])
        let host = String(name[name.index(after: at)..<colon])
        guard !user.isEmpty, !host.isEmpty, !user.contains("/"), !host.contains("/") else { return nil }
        return SSHEndpoint(host: host, user: user, port: port == 22 ? nil : port)
    }
}

/// What `ssh -G` says a destination really resolves to.
public struct ResolvedSSHTarget: Hashable, Sendable {
    public var hostName: String
    public var user: String?
    public var port: Int
    /// The expanded ControlPath, or nil for `none` / unset.
    public var controlPath: String?
    public var controlMaster: String?
    public var proxyJump: String?

    public init(hostName: String, user: String? = nil, port: Int = 22, controlPath: String? = nil,
                controlMaster: String? = nil, proxyJump: String? = nil) {
        self.hostName = hostName
        self.user = user
        self.port = port
        self.controlPath = controlPath
        self.controlMaster = controlMaster
        self.proxyJump = proxyJump
    }

    /// Parses `ssh -G` output (`keyword value` per line, lower-case keywords).
    public static func parse(_ output: String, home: String = NSHomeDirectory()) -> ResolvedSSHTarget? {
        var values: [String: String] = [:]
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = line[..<space].lowercased()
            if values[key] == nil { values[key] = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces) }
        }
        guard let host = values["hostname"], !host.isEmpty else { return nil }
        var path = values["controlpath"]
        if let p = path, p == "none" || p.isEmpty || p.contains("%") { path = nil }
        path = path.map { ShellWords.expandTilde($0, home: home) }
        let jump = values["proxyjump"].flatMap { $0 == "none" ? nil : $0 }
        return ResolvedSSHTarget(hostName: host, user: values["user"], port: Int(values["port"] ?? "") ?? 22,
                                 controlPath: path, controlMaster: values["controlmaster"], proxyJump: jump)
    }
}

/// Finds the LiteMux host an agent's connection goes to.
public enum HostMatcher {
    /// - Parameters:
    ///   - alias: the destination as typed (a config alias or `user@host`).
    ///   - resolved: `ssh -G` for it, when known.
    public static func match(alias: String, endpoint: SSHEndpoint, resolved: ResolvedSSHTarget?,
                             bookmarks: [Bookmark], config: [SSHConfigHost]) -> String? {
        let typed = alias.split(separator: "@").last.map(String.init) ?? alias
        if let c = config.first(where: { $0.alias == typed || $0.otherAliases.contains(typed) }),
           endpoint.user == nil || c.user == nil || endpoint.user == c.user, endpoint.port == nil || endpoint.port == (c.port ?? 22) {
            return "config:\(c.alias)"
        }
        let host = (resolved?.hostName ?? endpoint.host).lowercased()
        let port = resolved?.port ?? endpoint.port ?? 22
        let user = endpoint.user ?? resolved?.user

        func same(_ h: String, _ p: Int?, _ u: String?) -> Bool {
            guard h.lowercased() == host, (p ?? 22) == port else { return false }
            if let u, let user { return u == user }
            return true
        }
        if let b = bookmarks.first(where: { same($0.endpoint.host, $0.endpoint.port, $0.endpoint.user) }) {
            return b.hostID
        }
        if let c = config.first(where: { same($0.hostName ?? $0.alias, $0.port, $0.user) }) {
            return "config:\(c.alias)"
        }
        return nil
    }
}

extension SSHEndpoint {
    /// A `ControlPath=` option pointing at somebody else's live master (set
    /// when LiteMux rides a coding agent's connection), if its folder exists.
    public var adoptedControlPath: String? {
        for option in options {
            let (k, v) = SSHArgv.splitOption(option)
            guard k.lowercased() == "controlpath", !v.isEmpty, v != "none", !v.contains("%") else { continue }
            let path = ShellWords.expandTilde(v)
            var isDir: ObjCBool = false
            let dir = (path as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue { return path }
        }
        return nil
    }

    /// The same endpoint riding a given ControlMaster socket.
    public func riding(controlPath: String) -> SSHEndpoint {
        var copy = self
        copy.options.removeAll { SSHArgv.splitOption($0).0.lowercased() == "controlpath" }
        copy.options.append("ControlPath=\(controlPath)")
        return copy
    }
}
