import Foundation
import Observation
import LiteMuxCore

/// Watches what local coding agents do on servers: the `ssh` processes they
/// start (from `ps`), the shell calls in their own session logs, and LiteMux
/// Bridge calls. Nothing runs on the servers; everything is read on this Mac.
@MainActor @Observable
final class AgentWatch {
    struct Live: Identifiable, Equatable {
        var ssh: ObservedSSH
        var firstSeen: Date
        /// The LiteMux host it goes to, if one matches.
        var hostID: String?
        /// The agent's own ControlMaster socket, when one is up: LiteMux can ride it.
        var socket: String?
        /// The agent's description of the call, from its session log.
        var note: String?
        var id: Int32 { ssh.pid }
        var insight: RemoteCommandInsight { ssh.insight }
    }

    struct Tunnel: Identifiable, Equatable {
        var master: ObservedMaster
        var hostID: String?
        /// From a `%r@%h:%p` socket name when no host matches.
        var endpoint: SSHEndpoint?
        var id: Int32 { master.pid }
    }

    private(set) var live: [Live] = []
    private(set) var others: [Live] = []
    private(set) var tunnels: [Tunnel] = []
    private(set) var recent: [AgentAction] = []
    private(set) var scanned = false

    var readsTranscripts: Bool {
        didSet { UserDefaults.standard.set(readsTranscripts, forKey: Self.transcriptsKey) }
    }

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var timeline = AgentTimeline()
    @ObservationIgnored private var seen: [Int32: (ssh: ObservedSSH, firstSeen: Date)] = [:]
    @ObservationIgnored private var resolved: [String: (target: ResolvedSSHTarget?, at: Date)] = [:]
    @ObservationIgnored private var resolving: Set<String> = []
    /// Control socket path → host id, from `ssh -G` of every known host.
    @ObservationIgnored private var hostSockets: [String: String] = [:]
    @ObservationIgnored private var hostSocketsAt = Date.distantPast
    @ObservationIgnored private let reader = TranscriptReader()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var ticks = 0

    private static let transcriptsKey = "LiteMuxReadAgentTranscripts"

    init() {
        readsTranscripts = UserDefaults.standard.object(forKey: Self.transcriptsKey) as? Bool ?? true
    }

    /// Whether the Agent sidebar is on screen; it polls faster then.
    private var visible: Bool {
        guard let app else { return false }
        return app.sidebarVisible && app.sidebarMode == .agents
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.step()
                let fast = self.visible
                try? await Task.sleep(nanoseconds: fast ? 1_200_000_000 : 4_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Rescans right away (the panel just appeared).
    func poke() {
        Task { await step() }
    }

    func clearHistory() {
        timeline = AgentTimeline()
        recent = []
        reader.skipToEnd()
    }

    // MARK: - Scanning

    private func step() async {
        guard let app else { return }
        ticks += 1
        let controlDir = app.hub.invocation.controlDirectory
        let out = await ProcessRunner.run(ProcessTable.psPath, ProcessTable.psArguments, timeout: 4)
        let table = ProcessTable.parse(out.stdout)
        let scan = LocalSSHScan.scan(table, selfPID: getpid(), controlDirectory: controlDir)
        let now = Date()

        // Agent ssh processes that ended go to the history.
        let current = Set(scan.connections.map(\.pid))
        for (pid, entry) in seen where !current.contains(pid) {
            timeline.processEnded(entry.ssh, firstSeen: entry.firstSeen, now: now)
            seen[pid] = nil
        }
        for c in scan.connections where seen[c.pid] == nil { seen[c.pid] = (c, now) }

        if readsTranscripts, visible || ticks % 2 == 0 {
            let reader = self.reader
            let batches = await Task.detached(priority: .utility) { reader.poll() }.value
            for b in batches { timeline.ingest(b.events, agent: b.agent, session: b.session, now: now) }
            timeline.expireStaleCalls(now: now)
        }
        if ticks % 3 == 1 { timeline.setBridge(BridgeActivityLog().recent(40)) }
        if now.timeIntervalSince(hostSocketsAt) > 300 { refreshHostSockets() }

        let masterSockets = Set(scan.masters.map(\.socketPath))
        func row(_ c: ObservedSSH) -> Live {
            let target = resolve(c.argv.resolveArguments)
            let hostID = HostMatcher.match(alias: c.argv.destination, endpoint: c.argv.endpoint, resolved: target,
                                           bookmarks: app.state.bookmarks, config: app.configHostsForMatching)
            var socket: String?
            let path = (c.argv.controlPath.flatMap { $0.contains("%") ? nil : ShellWords.expandTilde($0) }) ?? target?.controlPath
            if let path, !path.hasPrefix(controlDir), masterSockets.contains(path) || Self.isSocket(path) { socket = path }
            let note = timeline.transcriptAction(for: c, firstSeen: seen[c.pid]?.firstSeen ?? now)?.note
            return Live(ssh: c, firstSeen: seen[c.pid]?.firstSeen ?? now, hostID: hostID, socket: socket, note: note)
        }
        let rows = scan.connections.map(row)
        let agentRows = rows.filter { $0.ssh.agent != nil }
        let otherRows = rows.filter { $0.ssh.agent == nil }
        if agentRows != live { live = agentRows }
        if otherRows != others { others = otherRows }

        let newTunnels = scan.masters.map { m -> Tunnel in
            let fromName = SSHArgv.endpoint(fromSocketName: m.socketPath)
            var hostID = hostSockets[m.socketPath]
                ?? rows.first(where: { $0.socket == m.socketPath })?.hostID
            if hostID == nil, let ep = fromName {
                hostID = HostMatcher.match(alias: ep.destination, endpoint: ep, resolved: nil,
                                           bookmarks: app.state.bookmarks, config: app.configHostsForMatching)
            }
            return Tunnel(master: m, hostID: hostID, endpoint: fromName)
        }
        if newTunnels != tunnels { tunnels = newTunnels }

        // Calls that a live row already shows stay out of the history.
        let shown = Set(agentRows.compactMap { r in timeline.transcriptAction(for: r.ssh, firstSeen: r.firstSeen)?.id })
        let history = timeline.recent(120).filter { !shown.contains($0.id) }
        if history != recent { recent = history }
        scanned = true
        app.agentScanDidUpdate(masters: masterSockets)
    }

    /// `ssh -G …`, cached for two minutes.
    private func resolve(_ args: [String]) -> ResolvedSSHTarget? {
        let key = args.joined(separator: "\u{1F}")
        if let hit = resolved[key], Date().timeIntervalSince(hit.at) < 120 { return hit.target }
        if !resolving.contains(key) {
            resolving.insert(key)
            Task {
                let r = await ProcessRunner.run(SSHInvocation.sshPath, args, environment: ProcessRunner.baseEnvironment(), timeout: 4)
                self.resolved[key] = (r.status == 0 ? ResolvedSSHTarget.parse(r.stdout) : nil, Date())
                self.resolving.remove(key)
            }
        }
        return resolved[key]?.target
    }

    /// Learns which control socket each known host would use, so a tunnel an
    /// agent left behind is recognised even after its command finished.
    private func refreshHostSockets() {
        guard let app else { return }
        hostSocketsAt = Date()
        let hosts = app.bookmarkHosts + app.sshConfigHosts
        Task {
            var map: [String: String] = [:]
            for h in hosts {
                guard let ep = h.endpoint else { continue }
                let r = await ProcessRunner.run(SSHInvocation.sshPath, ["-G"] + ep.arguments(),
                                                environment: ProcessRunner.baseEnvironment(), timeout: 4)
                if let path = ResolvedSSHTarget.parse(r.stdout)?.controlPath { map[path] = h.id }
            }
            self.hostSockets = map
        }
    }

    static func isSocket(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSocket
    }

    // MARK: - Lookups for history rows

    /// The LiteMux host a history row went to.
    func hostID(for action: AgentAction) -> String? {
        guard let app else { return nil }
        if action.source == .bridge {
            return app.allHosts.first { $0.title == action.destination }?.id
        }
        guard let ep = action.endpoint else { return nil }
        let target = resolve(["-G"] + ep.arguments())
        return HostMatcher.match(alias: action.destination, endpoint: ep, resolved: target,
                                 bookmarks: app.state.bookmarks, config: app.configHostsForMatching)
    }

    /// A live tunnel (the agent's ControlMaster) to the same host.
    func socket(forHost hostID: String) -> String? {
        if let t = tunnels.first(where: { $0.hostID == hostID }) { return t.master.socketPath }
        return live.first { $0.hostID == hostID && $0.socket != nil }?.socket
    }

    // MARK: - CI

    var smokeSummary: String {
        let l = live.map { "\($0.ssh.agent?.title ?? "?")→\($0.ssh.argv.destination) host=\($0.hostID ?? "-") socket=\($0.socket ?? "-") tmux=\($0.insight.tmuxSessions) cmd=\($0.insight.headline)" }
        let t = tunnels.map { "\($0.master.socketPath) host=\($0.hostID ?? "-")" }
        let r = recent.prefix(8).map { "\($0.agentName) \($0.source.rawValue) \($0.destination) \($0.command.prefix(60))" }
        return "live=\(live.count) others=\(others.count) tunnels=\(tunnels.count) recent=\(recent.count)\n  live: \(l)\n  tunnels: \(t)\n  recent: \(r)"
    }
}

/// Tails the newest Claude Code and Codex session logs.
final class TranscriptReader: @unchecked Sendable {
    struct Batch: Sendable {
        var agent: AgentKind
        var session: String
        var events: [TranscriptEvent]
    }

    private struct Tail {
        var tail: JSONLinesTail
        var agent: AgentKind
        var session: String
        var cwd: String?
    }

    private let lock = NSLock()
    private var tails: [String: Tail] = [:]
    private var discoveredAt = Date.distantPast
    private let home = NSHomeDirectory()
    /// Session logs untouched for this long are not followed.
    private let freshness: TimeInterval = 3 * 3600

    func skipToEnd() {
        lock.lock(); defer { lock.unlock() }
        for (path, var t) in tails {
            t.tail = JSONLinesTail(path: path, backlog: 0)
            tails[path] = t
        }
    }

    func poll() -> [Batch] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(discoveredAt) > 10 {
            discoveredAt = now
            discover(now: now)
        }
        var out: [Batch] = []
        for (path, var t) in tails {
            let lines = t.tail.read()
            guard !lines.isEmpty else { continue }
            var events: [TranscriptEvent] = []
            for line in lines {
                switch t.agent {
                case .codex:
                    if let cwd = AgentTranscript.codexSessionCwd(line: line) { t.cwd = cwd }
                    events += AgentTranscript.parseCodex(line: line).map { e in
                        var e = e
                        if e.cwd == nil { e.cwd = t.cwd }
                        return e
                    }
                default:
                    events += AgentTranscript.parseClaude(line: line)
                }
            }
            tails[path] = t
            if !events.isEmpty { out.append(Batch(agent: t.agent, session: t.session, events: events)) }
        }
        return out
    }

    private func discover(now: Date) {
        let fm = FileManager.default
        var found: [(String, AgentKind, Date)] = []
        func consider(_ path: String, _ agent: AgentKind) {
            guard path.hasSuffix(".jsonl"),
                  let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(m) < freshness else { return }
            found.append((path, agent, m))
        }

        let env = ProcessInfo.processInfo.environment
        let claude = (env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.claude") + "/projects"
        for project in (try? fm.contentsOfDirectory(atPath: claude)) ?? [] {
            let dir = claude + "/" + project
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] { consider(dir + "/" + name, .claudeCode) }
        }

        let codex = (env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.codex") + "/sessions"
        let cal = Calendar.current
        for dayOffset in [0, -1] {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = String(format: "%@/%04d/%02d/%02d", codex, c.year ?? 0, c.month ?? 0, c.day ?? 0)
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] { consider(dir + "/" + name, .codex) }
        }

        // Follow the 16 most recently written sessions.
        let keep = found.sorted { $0.2 > $1.2 }.prefix(16)
        let keepPaths = Set(keep.map(\.0))
        for path in tails.keys where !keepPaths.contains(path) { tails[path] = nil }
        for (path, agent, _) in keep where tails[path] == nil {
            let session = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            tails[path] = Tail(tail: JSONLinesTail(path: path, backlog: 384 * 1024), agent: agent, session: session)
        }
    }
}
