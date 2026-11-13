import Foundation

/// A TCP port something listens on, from `ss -ltnp`, `lsof` or `netstat`.
public struct ListeningPort: Hashable, Sendable, Identifiable {
    public var port: Int
    /// Bind addresses, e.g. `0.0.0.0`, `[::]`, `127.0.0.1`.
    public var addresses: [String]
    public var process: String?
    public var pid: Int?

    public init(port: Int, addresses: [String], process: String? = nil, pid: Int? = nil) {
        self.port = port
        self.addresses = addresses
        self.process = process
        self.pid = pid
    }

    public var id: Int { port }

    /// Reachable only from the host itself, which is what a tunnel is for.
    public var isLoopbackOnly: Bool {
        !addresses.isEmpty && addresses.allSatisfy { a in
            let s = a.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return s.hasPrefix("127.") || s == "::1" || s == "localhost" || s.hasPrefix("::ffff:127.")
        }
    }

    static let known: [Int: String] = [
        22: "SSH", 80: "HTTP", 443: "HTTPS", 3000: "Web", 3306: "MySQL", 5000: "Web", 5432: "PostgreSQL",
        5173: "Vite", 6006: "TensorBoard", 6379: "Redis", 7860: "Gradio", 8000: "Web", 8080: "Web",
        8188: "ComfyUI", 8265: "Ray Dashboard", 8501: "Streamlit", 8888: "Jupyter", 8889: "Jupyter",
        9090: "Prometheus", 11434: "Ollama",
    ]

    /// "TensorBoard", "Jupyter", or the program name.
    public var label: String {
        let p = (process ?? "").lowercased()
        if p.hasPrefix("tensorboa") { return "TensorBoard" }
        if p.hasPrefix("jupyter") { return "Jupyter" }
        if p.hasPrefix("code-server") { return "code-server" }
        if p == "sshd" { return "SSH" }
        if let k = Self.known[port], k != "Web" || process == nil { return k }
        return process ?? Self.known[port] ?? "TCP"
    }

    /// Worth offering as a browser tunnel: not ssh, DNS, mail or a database.
    public var looksLikeWeb: Bool {
        let skip: Set<Int> = [22, 25, 53, 111, 631, 3306, 5432, 6379, 27017, 2049]
        if skip.contains(port) { return false }
        let p = (process ?? "").lowercased()
        if ["sshd", "systemd-resolve", "containerd", "dockerd", "rpcbind", "cupsd", "master", "exim4", "chronyd"].contains(p) { return false }
        return port >= 80
    }

    /// Parses lines prefixed with the tool that produced them (`ss `, `lsof `, `netstat `),
    /// or plain `ss -ltn` lines. One entry per port, sorted.
    public static func parse(_ text: String) -> [ListeningPort] {
        var byPort: [Int: ListeningPort] = [:]
        for raw in text.split(separator: "\n") {
            var f = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard !f.isEmpty else { continue }
            var tool = "ss"
            if ["ss", "lsof", "netstat"].contains(f[0]) { tool = f.removeFirst() }
            var local: String?
            var process: String?
            var pid: Int?
            switch tool {
            case "lsof":
                // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME (LISTEN)
                guard f.count >= 9 else { continue }
                process = f[0].replacingOccurrences(of: "\\x20", with: " ")
                pid = Int(f[1])
                local = f.last(where: { $0.contains(":") && !$0.hasPrefix("(") })
            case "netstat":
                // tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN 812/sshd
                guard f.count >= 6, f[0].hasPrefix("tcp") else { continue }
                local = f[3]
                if let last = f.last, let slash = last.firstIndex(of: "/") {
                    pid = Int(last[..<slash])
                    process = String(last[last.index(after: slash)...])
                }
            default:
                // LISTEN 0 4096 0.0.0.0:6006 0.0.0.0:* users:(("tensorboard",pid=1234,fd=3))
                if f[0] == "LISTEN", f.count >= 4 {
                    local = f[3]
                } else if f[0] == "tcp", f.count >= 5 {
                    local = f[4]
                } else {
                    continue
                }
                if let users = f.first(where: { $0.hasPrefix("users:") }) {
                    if let a = users.range(of: "((\""), let b = users[a.upperBound...].firstIndex(of: "\"") {
                        process = String(users[a.upperBound..<b])
                    }
                    if let p = users.range(of: "pid=") {
                        pid = Int(users[p.upperBound...].prefix { $0.isNumber })
                    }
                }
            }
            guard let local, let colon = local.lastIndex(of: ":"), let port = Int(local[local.index(after: colon)...]) else { continue }
            var address = String(local[..<colon])
            if let pct = address.firstIndex(of: "%") { address = String(address[..<pct]) }
            if var existing = byPort[port] {
                if !existing.addresses.contains(address) { existing.addresses.append(address) }
                if existing.process == nil { existing.process = process; existing.pid = pid }
                byPort[port] = existing
            } else {
                byPort[port] = ListeningPort(port: port, addresses: [address], process: process, pid: pid)
            }
        }
        return byPort.values.sorted { $0.port < $1.port }
    }
}
