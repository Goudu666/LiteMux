import Foundation

/// One thing a coding agent did on a server, from whichever source saw it.
public struct AgentAction: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable {
        /// An `ssh` seen in the local process list.
        case process
        /// The agent's own session log (Claude Code, Codex).
        case transcript
        /// A LiteMux Bridge tool call.
        case bridge
    }

    public enum State: Hashable, Sendable {
        case running
        case done(exitCode: Int?)
        case failed(exitCode: Int?)
        case denied
    }

    public var id: String
    public var agent: AgentKind?
    /// Display name: the agent's title, or the MCP client name.
    public var agentName: String
    public var source: Source
    public var start: Date
    public var end: Date?
    /// Destination as the agent wrote it, or the Bridge host's title.
    public var destination: String
    public var endpoint: SSHEndpoint?
    /// `ssh`, `scp`, `rsync`, or a Bridge tool name.
    public var tool: String
    public var command: String
    public var insight: RemoteCommandInsight
    /// The agent's own description of the call.
    public var note: String?
    /// The tail of what it printed.
    public var output: String?
    public var state: State
    /// The agent's project folder on this Mac (last path component).
    public var project: String?

    public var isRunning: Bool { state == .running }
}

/// Merges transcript calls, observed ssh processes and Bridge activity into
/// one history, without showing the same command twice.
public struct AgentTimeline: Sendable {
    public private(set) var actions: [String: AgentAction] = [:]
    /// Transcript call id → the action ids it produced (one per ssh/scp in the line).
    private var calls: [String: [String]] = [:]
    public var limit = 240

    public init() {}

    // MARK: Transcripts

    public mutating func ingest(_ events: [TranscriptEvent], agent: AgentKind, session: String, now: Date = Date()) {
        for event in events {
            let key = "\(session)|\(event.id)"
            switch event.kind {
            case .call(let command, let note):
                guard calls[key] == nil else { continue }
                let touches = RemoteTouch.find(in: command)
                guard !touches.isEmpty else { continue }
                var ids: [String] = []
                for (n, touch) in touches.enumerated() {
                    let id = "t:\(key):\(n)"
                    ids.append(id)
                    actions[id] = AgentAction(
                        id: id, agent: agent, agentName: agent.title, source: .transcript,
                        start: event.time ?? now, end: nil, destination: touch.destination, endpoint: touch.endpoint,
                        tool: touch.tool, command: touch.command, insight: touch.insight, note: note?.nilIfBlank,
                        output: nil, state: .running, project: event.cwd.map { ($0 as NSString).lastPathComponent })
                }
                calls[key] = ids
            case .result(let output, let isError, let code):
                guard let ids = calls[key] else { continue }
                for id in ids {
                    guard var a = actions[id] else { continue }
                    a.end = event.time ?? now
                    a.output = Self.tail(output)
                    a.state = isError || (code ?? 0) != 0 ? .failed(exitCode: code) : .done(exitCode: code)
                    actions[id] = a
                }
            }
        }
        trim()
    }

    /// Calls still marked running long after they started lost their result
    /// (the agent was interrupted); stop showing a spinner for them.
    public mutating func expireStaleCalls(now: Date = Date(), after: TimeInterval = 6 * 3600) {
        for (id, a) in actions where a.source == .transcript && a.state == .running && now.timeIntervalSince(a.start) > after {
            var b = a
            b.state = .done(exitCode: nil)
            actions[id] = b
        }
    }

    // MARK: Processes

    /// The transcript call behind a live ssh, if the agent logged one.
    public func transcriptAction(for ssh: ObservedSSH, firstSeen: Date) -> AgentAction? {
        let started = firstSeen.addingTimeInterval(-ssh.elapsed)
        let wanted = Self.normalize(ssh.argv.remoteCommand)
        return actions.values
            .filter { $0.source == .transcript && $0.tool == "ssh" && $0.agent == ssh.agent }
            .filter { Self.normalize($0.command) == wanted && $0.destination == ssh.argv.destination }
            .filter { abs($0.start.timeIntervalSince(started)) < 45 }
            .min { abs($0.start.timeIntervalSince(started)) < abs($1.start.timeIntervalSince(started)) }
    }

    /// An agent's ssh left the process list. Recorded only when no session
    /// log already covers it.
    public mutating func processEnded(_ ssh: ObservedSSH, firstSeen: Date, now: Date = Date()) {
        guard let agent = ssh.agent else { return }
        if transcriptAction(for: ssh, firstSeen: firstSeen) != nil { return }
        let start = firstSeen.addingTimeInterval(-ssh.elapsed)
        let id = "p:\(ssh.pid):\(Int(start.timeIntervalSince1970))"
        let command = ssh.argv.noCommand ? "端口转发 " + ssh.argv.forwards.joined(separator: " ") : ssh.argv.remoteCommand
        actions[id] = AgentAction(
            id: id, agent: agent, agentName: agent.title, source: .process, start: start, end: now,
            destination: ssh.argv.destination, endpoint: ssh.argv.endpoint, tool: "ssh", command: command,
            insight: RemoteCommandInsight.analyze(command), note: nil, output: nil, state: .done(exitCode: nil), project: nil)
        trim()
    }

    // MARK: Bridge

    /// Replaces the Bridge part of the history with the latest log lines.
    public mutating func setBridge(_ activity: [BridgeActivity]) {
        for (id, a) in actions where a.source == .bridge { actions[id] = nil }
        for b in activity {
            let id = "b:\(b.id.uuidString)"
            let state: AgentAction.State
            switch b.outcome {
            case .ok: state = .done(exitCode: nil)
            case .failed: state = .failed(exitCode: nil)
            case .denied: state = .denied
            }
            actions[id] = AgentAction(
                id: id, agent: AgentKind.fromClientName(b.client), agentName: AgentKind.fromClientName(b.client)?.title ?? b.client,
                source: .bridge, start: b.time, end: b.time, destination: b.host ?? "本机", endpoint: nil, tool: b.tool,
                command: b.summary, insight: RemoteCommandInsight(headline: b.summary), note: nil, output: nil,
                state: state, project: nil)
        }
        trim()
    }

    // MARK: Reading

    /// Newest first.
    public func recent(_ count: Int = 120) -> [AgentAction] {
        Array(actions.values.sorted { $0.start > $1.start }.prefix(count))
    }

    private mutating func trim() {
        guard actions.count > limit else { return }
        let keep = Set(recent(limit).map(\.id))
        actions = actions.filter { keep.contains($0.key) }
        calls = calls.mapValues { $0.filter(keep.contains) }.filter { !$0.value.isEmpty }
    }

    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    }

    /// The last lines of an output, at most 40 lines / 4 KB.
    static func tail(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var lines = trimmed.components(separatedBy: "\n")
        if lines.count > 40 { lines = Array(lines.suffix(40)) }
        var out = lines.joined(separator: "\n")
        if out.utf8.count > 4096 { out = String(out.suffix(4000)) }
        return out
    }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
