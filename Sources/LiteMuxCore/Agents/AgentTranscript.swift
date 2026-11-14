import Foundation

/// A shell call a coding agent made, read from its own session log
/// (Claude Code: `~/.claude/projects/*/*.jsonl`, Codex: `~/.codex/sessions/**/rollout-*.jsonl`).
public struct TranscriptEvent: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// The agent asked to run `command`; `note` is its own one-line description.
        case call(command: String, note: String?)
        case result(output: String, isError: Bool, exitCode: Int?)
    }

    public var id: String
    public var time: Date?
    /// The agent's working directory on this Mac.
    public var cwd: String?
    public var kind: Kind

    public init(id: String, time: Date?, cwd: String?, kind: Kind) {
        self.id = id
        self.time = time
        self.cwd = cwd
        self.kind = kind
    }
}

public enum AgentTranscript {
    // MARK: Claude Code

    /// One JSON line of a Claude Code session.
    public static func parseClaude(line: Data) -> [TranscriptEvent] {
        guard let obj = json(line) else { return [] }
        let time = date(obj["timestamp"])
        let cwd = obj["cwd"] as? String
        guard let message = obj["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return [] }
        var out: [TranscriptEvent] = []
        for item in content {
            switch item["type"] as? String {
            case "tool_use":
                guard let name = item["name"] as? String, name == "Bash", let id = item["id"] as? String,
                      let input = item["input"] as? [String: Any], let command = input["command"] as? String else { continue }
                out.append(TranscriptEvent(id: id, time: time, cwd: cwd,
                                           kind: .call(command: command, note: input["description"] as? String)))
            case "tool_result":
                guard let id = item["tool_use_id"] as? String else { continue }
                let output = text(item["content"])
                out.append(TranscriptEvent(id: id, time: time, cwd: cwd,
                                           kind: .result(output: output, isError: item["is_error"] as? Bool ?? false,
                                                         exitCode: exitCode(in: output))))
            default:
                continue
            }
        }
        return out
    }

    // MARK: Codex

    /// One JSON line of a Codex rollout. Handles the `response_item` function
    /// calls of the CLI and the `exec_command_*` events of newer builds.
    public static func parseCodex(line: Data) -> [TranscriptEvent] {
        guard let obj = json(line), let payload = obj["payload"] as? [String: Any] else { return [] }
        let time = date(obj["timestamp"])
        let cwd = payload["cwd"] as? String
        switch payload["type"] as? String {
        case "function_call":
            guard let name = payload["name"] as? String, ["shell", "container.exec", "exec_command", "local_shell", "shell_command"].contains(name),
                  let id = payload["call_id"] as? String else { return [] }
            var args: [String: Any] = [:]
            if let s = payload["arguments"] as? String, let d = s.data(using: .utf8), let a = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                args = a
            } else if let a = payload["arguments"] as? [String: Any] {
                args = a
            }
            guard let command = commandLine(args["command"] ?? args["cmd"]) else { return [] }
            return [TranscriptEvent(id: id, time: time, cwd: (args["workdir"] as? String) ?? cwd,
                                    kind: .call(command: command, note: args["justification"] as? String))]
        case "local_shell_call":
            guard let id = (payload["call_id"] as? String) ?? (payload["id"] as? String),
                  let action = payload["action"] as? [String: Any], let command = commandLine(action["command"]) else { return [] }
            return [TranscriptEvent(id: id, time: time, cwd: (action["working_directory"] as? String) ?? cwd,
                                    kind: .call(command: command, note: nil))]
        case "exec_command_begin":
            guard let id = payload["call_id"] as? String, let command = commandLine(payload["command"]) else { return [] }
            return [TranscriptEvent(id: id, time: time, cwd: cwd, kind: .call(command: command, note: nil))]
        case "function_call_output":
            guard let id = payload["call_id"] as? String else { return [] }
            var output = ""
            var code: Int?
            if let s = payload["output"] as? String {
                if let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    output = (o["output"] as? String) ?? s
                    code = (o["metadata"] as? [String: Any])?["exit_code"] as? Int
                } else {
                    output = s
                }
            } else if let o = payload["output"] as? [String: Any] {
                output = (o["content"] as? String) ?? (o["output"] as? String) ?? ""
            }
            if code == nil { code = exitCode(in: output) }
            return [TranscriptEvent(id: id, time: time, cwd: cwd,
                                    kind: .result(output: stripCodexHeader(output), isError: (code ?? 0) != 0, exitCode: code))]
        case "exec_command_end":
            guard let id = payload["call_id"] as? String else { return [] }
            let code = payload["exit_code"] as? Int
            let output = (payload["aggregated_output"] as? String) ?? (payload["formatted_output"] as? String)
                ?? [payload["stdout"] as? String, payload["stderr"] as? String].compactMap { $0 }.joined(separator: "\n")
            return [TranscriptEvent(id: id, time: time, cwd: cwd,
                                    kind: .result(output: output, isError: (code ?? 0) != 0, exitCode: code))]
        default:
            return []
        }
    }

    /// The session's working directory from a Codex `session_meta` / `turn_context` line.
    public static func codexSessionCwd(line: Data) -> String? {
        guard let obj = json(line), let type = obj["type"] as? String, type == "session_meta" || type == "turn_context",
              let payload = obj["payload"] as? [String: Any] else { return nil }
        return payload["cwd"] as? String
    }

    // MARK: Helpers

    /// `["bash", "-lc", "ssh gpu nvidia-smi"]` → `ssh gpu nvidia-smi`.
    static func commandLine(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        guard let parts = value as? [String], !parts.isEmpty else { return nil }
        let shell = (parts[0] as NSString).lastPathComponent
        if ["bash", "sh", "zsh"].contains(shell), parts.count >= 3, ["-lc", "-c", "-ic"].contains(parts[1]) { return parts[2] }
        return parts.map(ShellWords.quote).joined(separator: " ")
    }

    /// Codex prefixes output with "Exit code: 0\nWall time: 0.4 seconds\nOutput:\n".
    static func stripCodexHeader(_ s: String) -> String {
        guard s.hasPrefix("Exit code:") || s.hasPrefix("Exit Code:") else { return s }
        if let r = s.range(of: "Output:\n") { return String(s[r.upperBound...]) }
        return s
    }

    static func exitCode(in output: String) -> Int? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true).prefix(3) + output.split(separator: "\n").suffix(2) {
            let l = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["Exit code:", "Exit Code:", "exit code:", "Process exited with code"] where l.hasPrefix(prefix) {
                return Int(l.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    static func text(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let items = value as? [[String: Any]] {
            return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    static func json(_ line: Data) -> [String: Any]? {
        guard !line.isEmpty, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return obj
    }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
}

/// Reads only what was appended to a JSON-lines file since last time.
public struct JSONLinesTail: Sendable {
    public var path: String
    public private(set) var offset: UInt64
    private var partial = Data()

    /// Starts `backlog` bytes before the end (a fresh session starts at 0).
    public init(path: String, backlog: UInt64) {
        self.path = path
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        let start = size > backlog ? size - backlog : 0
        offset = start
        skipFirstLine = start > 0
    }

    private var skipFirstLine: Bool

    /// Complete new lines, oldest first.
    public mutating func read(limit: Int = 4 << 20) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end < offset { offset = 0; partial.removeAll(); skipFirstLine = false }  // truncated or replaced
        guard end > offset else { return [] }
        try? handle.seek(toOffset: offset)
        let want = Int(min(UInt64(limit), end - offset))
        guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { return [] }
        offset += UInt64(chunk.count)
        var data = partial + chunk
        if skipFirstLine {
            guard let nl = data.firstIndex(of: 0x0A) else { partial = data; return [] }
            data = data[(nl + 1)...]
            skipFirstLine = false
        }
        var lines: [Data] = []
        var start = data.startIndex
        while let nl = data[start...].firstIndex(of: 0x0A) {
            if nl > start { lines.append(Data(data[start..<nl])) }
            start = data.index(after: nl)
        }
        partial = Data(data[start...])
        return lines
    }
}
