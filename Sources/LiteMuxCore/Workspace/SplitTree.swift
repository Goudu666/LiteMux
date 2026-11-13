import Foundation

/// One terminal pane in a layout. `slot` names its private remote tmux session;
/// `session` instead attaches to a tmux session the user started themselves
/// (e.g. `train`), directly rather than nested inside `lm_<n>`.
public struct PaneSpec: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var hostID: String
    public var slot: Int?
    public var directory: String?
    public var session: String?

    public init(id: UUID = UUID(), hostID: String, slot: Int?, directory: String? = nil, session: String? = nil) {
        self.id = id
        self.hostID = hostID
        self.slot = slot
        self.directory = directory
        self.session = session
    }

    /// The tmux session this pane shows, if any.
    public var tmuxSession: String? {
        if let session, !session.isEmpty { return session }
        return slot.map(SSHInvocation.sessionName(slot:))
    }
}

public enum SplitAxis: String, Codable, Sendable {
    /// Side by side (a vertical divider), `Cmd+D`.
    case horizontal
    /// Stacked (a horizontal divider), `Cmd+Shift+D`.
    case vertical
}

/// A binary split tree: every split has exactly two children.
public indirect enum SplitNode: Codable, Hashable, Sendable {
    case leaf(PaneSpec)
    case split(id: UUID, axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)

    public var leaves: [PaneSpec] {
        switch self {
        case .leaf(let p): return [p]
        case .split(_, _, _, let a, let b): return a.leaves + b.leaves
        }
    }

    public func contains(pane id: UUID) -> Bool { leaves.contains { $0.id == id } }

    public func pane(_ id: UUID) -> PaneSpec? { leaves.first { $0.id == id } }

    /// Replaces the pane with a split holding it and `newPane`.
    public func splitting(pane id: UUID, axis: SplitAxis, with newPane: PaneSpec) -> SplitNode {
        switch self {
        case .leaf(let p):
            guard p.id == id else { return self }
            return .split(id: UUID(), axis: axis, ratio: 0.5, first: .leaf(p), second: .leaf(newPane))
        case .split(let sid, let ax, let r, let a, let b):
            return .split(id: sid, axis: ax, ratio: r,
                          first: a.splitting(pane: id, axis: axis, with: newPane),
                          second: b.splitting(pane: id, axis: axis, with: newPane))
        }
    }

    /// Removes a pane; its sibling takes the parent's place. Returns nil when
    /// the last pane is removed.
    public func removing(pane id: UUID) -> SplitNode? {
        switch self {
        case .leaf(let p):
            return p.id == id ? nil : self
        case .split(let sid, let ax, let r, let a, let b):
            let na = a.removing(pane: id)
            let nb = b.removing(pane: id)
            switch (na, nb) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?): return .split(id: sid, axis: ax, ratio: r, first: x, second: y)
            }
        }
    }

    public func settingRatio(_ ratio: Double, forSplit splitID: UUID) -> SplitNode {
        switch self {
        case .leaf: return self
        case .split(let sid, let ax, let r, let a, let b):
            if sid == splitID {
                return .split(id: sid, axis: ax, ratio: min(0.92, max(0.08, ratio)), first: a, second: b)
            }
            return .split(id: sid, axis: ax, ratio: r,
                          first: a.settingRatio(ratio, forSplit: splitID),
                          second: b.settingRatio(ratio, forSplit: splitID))
        }
    }

    /// Makes every split in the tree even again.
    public var equalized: SplitNode {
        switch self {
        case .leaf: return self
        case .split(let sid, let ax, _, let a, let b):
            return .split(id: sid, axis: ax, ratio: 0.5, first: a.equalized, second: b.equalized)
        }
    }

    public func updatingPane(_ id: UUID, _ change: (inout PaneSpec) -> Void) -> SplitNode {
        switch self {
        case .leaf(var p):
            if p.id == id { change(&p) }
            return .leaf(p)
        case .split(let sid, let ax, let r, let a, let b):
            return .split(id: sid, axis: ax, ratio: r,
                          first: a.updatingPane(id, change), second: b.updatingPane(id, change))
        }
    }
}

/// Hands out tmux slot numbers so no two open panes of one host share a session
/// (which would mirror them).
public enum SlotAllocator {
    public static func nextSlot(used: Set<Int>) -> Int {
        var n = 1
        while used.contains(n) { n += 1 }
        return n
    }
}

/// What a workspace tab shows.
public enum TabKind: Codable, Hashable, Sendable {
    case terminal(SplitNode)
    case editor(hostID: String, path: String)
}

/// Persisted tab.
public struct TabSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: TabKind

    public init(id: UUID = UUID(), kind: TabKind) {
        self.id = id
        self.kind = kind
    }
}
