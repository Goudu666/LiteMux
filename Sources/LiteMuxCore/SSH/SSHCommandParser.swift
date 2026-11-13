import Foundation

/// Turns whatever a cloud GPU console lets you copy into an `SSHEndpoint`.
///
/// Accepted shapes include:
/// - `ssh -p 38192 root@connect.westb.seetacloud.com`
/// - `ssh -i ~/.ssh/id_ed25519 ubuntu@1.2.3.4 -p 2222`
/// - `user@host:port`, `ssh://user@host:port`, `[::1]:2222`
/// - multi-line pastes where the command is on one of the lines
public enum SSHCommandParser {

    public struct Result: Equatable, Sendable {
        public var endpoint: SSHEndpoint
        public var suggestedName: String
        /// A password-looking value that appeared next to the command
        /// (e.g. AutoDL shows "密码：xxxx" under the command).
        public var detectedPassword: String?
    }

    /// Options that take a value, from `man ssh`.
    private static let valueOptions: Set<Character> = [
        "B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l", "m", "O", "o", "p", "Q", "R", "S", "W", "w",
    ]

    public static func parse(_ input: String) -> Result? {
        let lines = input.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        // Prefer a line that starts with "ssh"; otherwise the first line that parses.
        let ordered = lines.filter { $0.hasPrefix("ssh ") || $0.hasPrefix("ssh://") } + lines
        var endpoint: SSHEndpoint? = nil
        for line in ordered {
            if let ep = parseLine(line) { endpoint = ep; break }
        }
        guard let endpoint else { return nil }
        return Result(endpoint: endpoint,
                      suggestedName: suggestName(for: endpoint),
                      detectedPassword: detectPassword(in: lines))
    }

    static func parseLine(_ line: String) -> SSHEndpoint? {
        var words = ShellWords.split(line)
        guard !words.isEmpty else { return nil }
        if words.first == "ssh" { words.removeFirst() }

        var user: String? = nil
        var port: Int? = nil
        var identity: String? = nil
        var jump: String? = nil
        var options: [String] = []
        var destination: String? = nil

        var i = 0
        while i < words.count {
            let word = words[i]
            if word == "--" { i += 1; if i < words.count, destination == nil { destination = words[i] }; break }
            if word.hasPrefix("-") && word.count >= 2 && (destination == nil || isKnownOption(word)) {
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
                        }
                        switch flag {
                        case "p": port = Int(value)
                        case "l": user = value
                        case "i": identity = value
                        case "J": jump = value
                        case "o":
                            let (k, v) = splitOption(value)
                            switch k.lowercased() {
                            case "port": port = Int(v)
                            case "user": user = v
                            case "identityfile": identity = v
                            case "proxyjump": jump = v
                            default: options.append("\(k)=\(v)")
                            }
                        default: break
                        }
                        break
                    }
                    j += 1
                }
                i += 1
                continue
            }
            if destination == nil {
                destination = word
                i += 1
                continue
            }
            // Anything after the destination that is not an option is a remote command; ignore it.
            i += 1
        }

        guard var dest = destination, !dest.isEmpty else { return nil }

        if dest.hasPrefix("ssh://") {
            dest = String(dest.dropFirst("ssh://".count))
            if dest.hasSuffix("/") { dest.removeLast() }
        }
        if let at = dest.lastIndex(of: "@") {
            let u = String(dest[..<at])
            if !u.isEmpty { user = user ?? u }
            dest = String(dest[dest.index(after: at)...])
        }
        // [v6]:port or host:port
        var host = dest
        if dest.hasPrefix("["), let close = dest.firstIndex(of: "]") {
            host = String(dest[dest.index(after: dest.startIndex)..<close])
            let rest = dest[dest.index(after: close)...]
            if rest.hasPrefix(":"), let p = Int(rest.dropFirst()) { port = port ?? p }
        } else if dest.filter({ $0 == ":" }).count == 1, let colon = dest.firstIndex(of: ":") {
            let p = dest[dest.index(after: colon)...]
            if let pv = Int(p) {
                host = String(dest[..<colon])
                port = port ?? pv
            }
        }
        guard isPlausibleHost(host) else { return nil }
        return SSHEndpoint(host: host, user: user, port: port, identityFile: identity, proxyJump: jump, options: options)
    }

    private static func isKnownOption(_ word: String) -> Bool {
        guard let f = word.dropFirst().first else { return false }
        return valueOptions.contains(f) || "46AaCfGgKkMNnqsTtVvXxYy".contains(f)
    }

    private static func splitOption(_ s: String) -> (String, String) {
        if let eq = s.firstIndex(of: "=") {
            return (String(s[..<eq]).trimmingCharacters(in: .whitespaces),
                    String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
        }
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first ?? s, parts.count > 1 ? parts[1] : "")
    }

    private static func isPlausibleHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count < 254 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:%"))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// `connect.westb.seetacloud.com:38192` → `autodl-westb-38192`.
    public static func suggestName(for endpoint: SSHEndpoint) -> String {
        let host = endpoint.host.lowercased()
        let portSuffix = endpoint.port.map { "-\($0)" } ?? ""
        if host.hasSuffix("seetacloud.com") || host.hasSuffix("autodl.com") || host.hasSuffix("autodl.pro") {
            let labels = host.split(separator: ".").map(String.init)
            let region = labels.dropLast(2).first(where: { $0 != "connect" && $0 != "ssh" })
            let cleaned = region.map { $0.replacingOccurrences(of: "region-", with: "r") }
            if let cleaned { return "autodl-\(cleaned)\(portSuffix)" }
            return "autodl\(portSuffix)"
        }
        let isIP = host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":")
        let short = isIP ? host : (host.split(separator: ".").first.map(String.init) ?? host)
        var name = short
        if let user = endpoint.user, user != "root" { name = "\(user)@\(short)" }
        if let port = endpoint.port, port != 22 { name += ":\(port)" }
        return name
    }

    /// Looks for `密码: xxx` / `password: xxx` lines in a multi-line paste.
    static func detectPassword(in lines: [String]) -> String? {
        let markers = ["密码", "password", "Password", "PASSWORD", "pwd", "passwd"]
        for line in lines {
            guard markers.contains(where: { line.contains($0) }) else { continue }
            let separators: [Character] = [":", "：", "="]
            if let idx = line.lastIndex(where: { separators.contains($0) }) {
                let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty, !value.contains(" ") { return value }
            }
        }
        return nil
    }
}
