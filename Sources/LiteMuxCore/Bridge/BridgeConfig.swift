import Foundation

/// What a connected coding agent may do through LiteMux Bridge.
public enum BridgeMode: String, Codable, Sendable, CaseIterable {
    /// Only reading tools are offered; commands and writes do not exist.
    case readOnly
    /// Reading is free; every command or write asks in a LiteMux dialog.
    case confirm
    /// Everything runs without asking.
    case trusted

    public var title: String {
        switch self {
        case .readOnly: return "只读"
        case .confirm: return "执行前确认"
        case .trusted: return "完全信任"
        }
    }

    public var explanation: String {
        switch self {
        case .readOnly: return "Agent 只能看：终端输出、训练进度、GPU、文件。没有执行和写入工具。"
        case .confirm: return "看是自由的；执行命令、发送按键、写文件前，LiteMux 会弹窗让你确认。"
        case .trusted: return "不再询问。只建议在一次性的租用机器上使用。"
        }
    }
}

/// `~/.config/litemux/bridge.json`. Missing or broken files fall back to `confirm`.
public struct BridgeConfig: Codable, Equatable, Sendable {
    public var mode: BridgeMode = .confirm

    public init(mode: BridgeMode = .confirm) { self.mode = mode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(BridgeMode.self, forKey: .mode)) ?? .confirm
    }

    public static func url(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".config/litemux/bridge.json")
    }

    public static func load(home: String = NSHomeDirectory()) -> BridgeConfig {
        guard let data = try? Data(contentsOf: url(home: home)),
              let config = try? JSONDecoder().decode(BridgeConfig.self, from: data) else { return BridgeConfig() }
        return config
    }

    public func save(home: String = NSHomeDirectory()) throws {
        let u = Self.url(home: home)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: u, options: .atomic)
    }
}

/// One line of the activity log the app shows under "最近活动".
public struct BridgeActivity: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case ok, failed, denied
    }

    public var id: UUID
    public var time: Date
    public var client: String
    public var tool: String
    public var host: String?
    public var summary: String
    public var outcome: Outcome

    public init(id: UUID = UUID(), time: Date = Date(), client: String, tool: String,
                host: String?, summary: String, outcome: Outcome) {
        self.id = id
        self.time = time
        self.client = client
        self.tool = tool
        self.host = host
        self.summary = summary
        self.outcome = outcome
    }
}

/// Append-only JSON-lines log, trimmed to its newer half past `limit` bytes.
public struct BridgeActivityLog: Sendable {
    public var url: URL
    public var limit: Int

    public init(home: String = NSHomeDirectory(), limit: Int = 512 * 1024) {
        url = URL(fileURLWithPath: home).appendingPathComponent(".config/litemux/bridge-activity.jsonl")
        self.limit = limit
    }

    public init(url: URL, limit: Int = 512 * 1024) {
        self.url = url
        self.limit = limit
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func append(_ activity: BridgeActivity) {
        guard var line = try? Self.encoder.encode(activity) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        // Read-write: trimming reads the file back through the same locked handle.
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        // An advisory lock keeps two agents' lines from interleaving.
        flock(handle.fileDescriptor, LOCK_EX)
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
        if let size = try? handle.offset(), size > UInt64(limit) { trim(handle) }
    }

    private func trim(_ handle: FileHandle) {
        try? handle.seek(toOffset: 0)
        guard let data = try? handle.readToEnd() else { return }
        var keep = data.suffix(limit / 2)
        if let nl = keep.firstIndex(of: 0x0A) { keep = keep[(nl + 1)...] }
        try? handle.truncate(atOffset: 0)
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Data(keep))
    }

    /// Newest first.
    public func recent(_ count: Int = 50) -> [BridgeActivity] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let lines = data.split(separator: 0x0A).suffix(count)
        return lines.reversed().compactMap { try? Self.decoder.decode(BridgeActivity.self, from: Data($0)) }
    }
}
