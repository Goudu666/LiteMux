import Foundation

/// How to reach a remote machine with `/usr/bin/ssh`.
///
/// For hosts that come from `~/.ssh/config` only `host` (the alias) is set and
/// OpenSSH resolves the rest itself, so `ProxyJump`, `Match` and friends keep
/// working exactly as they do in Terminal.
public struct SSHEndpoint: Codable, Hashable, Sendable {
    public var host: String
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?
    /// Extra `-o Key=Value` options copied from a pasted command.
    public var options: [String]

    public init(host: String, user: String? = nil, port: Int? = nil,
                identityFile: String? = nil, proxyJump: String? = nil, options: [String] = []) {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.options = options
    }

    /// `user@host` (IPv6 literals are left bare; ssh accepts them with -l too).
    public var destination: String {
        if let user, !user.isEmpty { return "\(user)@\(host)" }
        return host
    }

    /// Arguments that select this endpoint, ending with the destination.
    public func arguments(home: String = NSHomeDirectory()) -> [String] {
        var args: [String] = []
        if let port, port != 22 { args += ["-p", String(port)] }
        if let identityFile, !identityFile.isEmpty {
            args += ["-i", ShellWords.expandTilde(identityFile, home: home)]
        }
        if let proxyJump, !proxyJump.isEmpty { args += ["-J", proxyJump] }
        for option in options { args += ["-o", option] }
        args.append(destination)
        return args
    }

    /// A copy-pasteable `ssh ...` command line.
    public var commandLine: String {
        var parts = ["ssh"]
        if let port, port != 22 { parts += ["-p", String(port)] }
        if let identityFile, !identityFile.isEmpty { parts += ["-i", ShellWords.quote(identityFile)] }
        if let proxyJump, !proxyJump.isEmpty { parts += ["-J", ShellWords.quote(proxyJump)] }
        for option in options { parts += ["-o", ShellWords.quote(option)] }
        parts.append(ShellWords.quote(destination))
        return parts.joined(separator: " ")
    }

    /// Short human description such as `root@connect.westb.seetacloud.com:38192`.
    public var summary: String {
        var s = destination
        if let port, port != 22 { s += ":\(port)" }
        return s
    }
}

public enum HostKind: String, Codable, Sendable {
    case local, bookmark, config
}

/// A saved "temporary compute" bookmark, typically a rented GPU instance.
public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var endpoint: SSHEndpoint
    public var hasSavedPassword: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, endpoint: SSHEndpoint,
                hasSavedPassword: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.hasSavedPassword = hasSavedPassword
        self.createdAt = createdAt
    }

    public var hostID: String { "bookmark:\(id.uuidString)" }
}

/// Anything that can be shown in the sidebar and opened in a pane.
public struct HostEntry: Identifiable, Hashable, Sendable {
    public static let localID = "local"

    public var id: String
    public var kind: HostKind
    public var title: String
    public var subtitle: String
    public var endpoint: SSHEndpoint?
    public var hasSavedPassword: Bool

    public init(id: String, kind: HostKind, title: String, subtitle: String,
                endpoint: SSHEndpoint?, hasSavedPassword: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.endpoint = endpoint
        self.hasSavedPassword = hasSavedPassword
    }

    public var isLocal: Bool { kind == .local }

    public static let local = HostEntry(id: localID, kind: .local, title: "Local Mac",
                                        subtitle: "本机登录 Shell", endpoint: nil)

    public static func from(_ bookmark: Bookmark) -> HostEntry {
        HostEntry(id: bookmark.hostID, kind: .bookmark, title: bookmark.name,
                  subtitle: bookmark.endpoint.summary, endpoint: bookmark.endpoint,
                  hasSavedPassword: bookmark.hasSavedPassword)
    }

    public static func from(_ host: SSHConfigHost) -> HostEntry {
        HostEntry(id: "config:\(host.alias)", kind: .config, title: host.alias,
                  subtitle: host.subtitle, endpoint: SSHEndpoint(host: host.alias))
    }
}
