import Foundation

/// Everything LiteMux remembers between launches. Host metadata and UI
/// preferences only: passwords live in the Keychain, never here.
public struct PersistedState: Codable, Equatable, Sendable {
    public enum Appearance: String, Codable, Sendable, CaseIterable { case system, light, dark }

    public var version: Int = 1
    public var bookmarks: [Bookmark] = []
    /// Per-host override of "auto attach remote tmux".
    public var autoTmux: [String: Bool] = [:]
    public var appearance: Appearance = .light
    public var fontSize: Double = 13
    public var sidebarWidth: Double = 240
    public var sidebarVisible: Bool = true
    public var sidebarMode: String = "hosts"
    public var showHiddenFiles: Bool = false
    public var useMetalRenderer: Bool = true
    public var tabs: [TabSnapshot] = []
    public var selectedTabIndex: Int? = nil
    /// Last directory browsed per host.
    public var lastDirectories: [String: String] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case version, bookmarks, autoTmux, appearance, fontSize, sidebarWidth, sidebarVisible, sidebarMode
        case showHiddenFiles, useMetalRenderer, tabs, selectedTabIndex, lastDirectories
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PersistedState()
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? d.version
        bookmarks = (try? c.decodeIfPresent([Bookmark].self, forKey: .bookmarks)) ?? d.bookmarks
        autoTmux = (try? c.decodeIfPresent([String: Bool].self, forKey: .autoTmux)) ?? d.autoTmux
        appearance = (try? c.decodeIfPresent(Appearance.self, forKey: .appearance)) ?? d.appearance
        fontSize = (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? d.fontSize
        sidebarWidth = (try? c.decodeIfPresent(Double.self, forKey: .sidebarWidth)) ?? d.sidebarWidth
        sidebarVisible = (try? c.decodeIfPresent(Bool.self, forKey: .sidebarVisible)) ?? d.sidebarVisible
        sidebarMode = (try? c.decodeIfPresent(String.self, forKey: .sidebarMode)) ?? d.sidebarMode
        showHiddenFiles = (try? c.decodeIfPresent(Bool.self, forKey: .showHiddenFiles)) ?? d.showHiddenFiles
        useMetalRenderer = (try? c.decodeIfPresent(Bool.self, forKey: .useMetalRenderer)) ?? d.useMetalRenderer
        tabs = (try? c.decodeIfPresent([TabSnapshot].self, forKey: .tabs)) ?? d.tabs
        selectedTabIndex = try? c.decodeIfPresent(Int.self, forKey: .selectedTabIndex)
        lastDirectories = (try? c.decodeIfPresent([String: String].self, forKey: .lastDirectories)) ?? d.lastDirectories
    }

    /// Remote hosts attach tmux by default, the local Mac does not.
    public func autoTmuxEnabled(for hostID: String) -> Bool {
        if let v = autoTmux[hostID] { return v }
        return hostID != HostEntry.localID
    }
}

/// Reads and writes `~/.config/litemux/state.json` atomically with 0600 permissions.
public struct StateStore: Sendable {
    public var url: URL

    public init(home: String = NSHomeDirectory()) {
        url = URL(fileURLWithPath: home).appendingPathComponent(".config/litemux/state.json")
    }

    public init(url: URL) { self.url = url }

    public func load() -> PersistedState {
        guard let data = try? Data(contentsOf: url) else { return PersistedState() }
        return (try? JSONDecoder.litemux.decode(PersistedState.self, from: data)) ?? PersistedState()
    }

    public func save(_ state: PersistedState) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder.litemux.encode(state)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension JSONEncoder {
    static var litemux: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var litemux: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
