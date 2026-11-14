import Foundation

/// The hosts an agent can name, read fresh from LiteMux's own files on every call.
public struct BridgeHostDirectory: Sendable {
    public var hosts: [HostEntry]
    /// hostID → tmux slots of panes open in LiteMux's saved tabs.
    public var openSlots: [String: [Int]]
    /// The host of the tab that was selected when LiteMux last saved.
    public var focusedHostID: String?

    public init(hosts: [HostEntry], openSlots: [String: [Int]] = [:], focusedHostID: String? = nil) {
        self.hosts = hosts
        self.openSlots = openSlots
        self.focusedHostID = focusedHostID
    }

    public static func load(home: String = NSHomeDirectory()) -> BridgeHostDirectory {
        let state = StateStore(home: home).load()
        let config = SSHConfigParser(home: home).parseUserConfig()
        return make(state: state, config: config)
    }

    public static func make(state: PersistedState, config: [SSHConfigHost]) -> BridgeHostDirectory {
        var hosts = state.bookmarks.map { HostEntry.from($0) }
        hosts += config.map { HostEntry.from($0) }
        hosts.append(.local)

        var slots: [String: [Int]] = [:]
        var focused: String?
        for (index, tab) in state.tabs.enumerated() {
            guard case .terminal(let tree) = tab.kind else { continue }
            for pane in tree.leaves {
                if let slot = pane.slot, !(slots[pane.hostID] ?? []).contains(slot) { slots[pane.hostID, default: []].append(slot) }
            }
            if index == state.selectedTabIndex { focused = tree.leaves.first?.hostID }
        }
        return BridgeHostDirectory(hosts: hosts, openSlots: slots.mapValues { $0.sorted() }, focusedHostID: focused)
    }

    public enum LookupError: Error, Equatable, CustomStringConvertible {
        case unknown(String, known: [String])
        case ambiguous(String, matches: [String])

        public var description: String {
            switch self {
            case .unknown(let q, let known):
                return "没有叫「\(q)」的主机。可用的主机：\(known.joined(separator: "、"))。先调用 list_hosts 看看。"
            case .ambiguous(let q, let matches):
                return "「\(q)」能对上多台主机：\(matches.joined(separator: "、"))。请用 list_hosts 里的 id。"
            }
        }
    }

    /// Finds a host by id, name, alias or hostname. An empty query means the
    /// host of the focused tab, then the only remote host with open panes.
    public func resolve(_ query: String?) throws -> HostEntry {
        let q = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            if let id = focusedHostID, let h = hosts.first(where: { $0.id == id }) { return h }
            let withPanes = hosts.filter { !$0.isLocal && openSlots[$0.id]?.isEmpty == false }
            if withPanes.count == 1 { return withPanes[0] }
            return .local
        }
        if let h = hosts.first(where: { $0.id == q }) { return h }
        let lower = q.lowercased()
        if ["local", "localhost", "本机", "local mac", "mac"].contains(lower) { return .local }
        let byTitle = hosts.filter { $0.title.lowercased() == lower }
        if byTitle.count == 1 { return byTitle[0] }
        let byHost = hosts.filter { h in
            guard let e = h.endpoint else { return false }
            return e.host.lowercased() == lower || e.destination.lowercased() == lower || e.summary.lowercased() == lower
        }
        if byHost.count == 1 { return byHost[0] }
        let candidates = byTitle.isEmpty ? byHost : byTitle
        if candidates.count > 1 { throw LookupError.ambiguous(q, matches: candidates.map(\.id)) }
        let fuzzy = hosts.filter { $0.title.lowercased().contains(lower) || $0.subtitle.lowercased().contains(lower) }
        if fuzzy.count == 1 { return fuzzy[0] }
        if fuzzy.count > 1 { throw LookupError.ambiguous(q, matches: fuzzy.map(\.title)) }
        throw LookupError.unknown(q, known: hosts.map(\.title))
    }
}
