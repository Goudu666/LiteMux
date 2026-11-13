import Foundation

/// The tools LiteMux Bridge offers to a coding agent.
public struct BridgeToolbox: Sendable {
    public var shell: BridgeShell
    public var directory: @Sendable () -> BridgeHostDirectory

    public init(shell: BridgeShell, directory: @escaping @Sendable () -> BridgeHostDirectory) {
        self.shell = shell
        self.directory = directory
    }

    public var tools: [BridgeTool] {
        [listHosts, readTerminal, trainingStatus, gpuStatus, listDirectory, readFile,
         runCommand, sendToTerminal, writeFile]
    }

    // MARK: - Schema helpers

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties),
         "required": .array(required.map { .string($0) }), "additionalProperties": false]
    }

    static func string(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
    static func integer(_ description: String, min: Int, max: Int) -> JSONValue {
        ["type": "integer", "description": .string(description), "minimum": .number(Double(min)), "maximum": .number(Double(max))]
    }
    static func number(_ description: String) -> JSONValue { ["type": "number", "description": .string(description)] }
    static func boolean(_ description: String) -> JSONValue { ["type": "boolean", "description": .string(description)] }

    static let hostProperty = string("Host id or name from list_hosts. Omit for the host of the tab the user has focused in LiteMux.")
    static let sessionProperty = string("tmux session, e.g. \"lm_1\" (or just \"1\"). Omit for the LiteMux pane with the most recent activity.")

    // MARK: - Shared plumbing

    func resolveHost(_ call: BridgeCall) throws -> HostEntry {
        do {
            let host = try directory().resolve(call.string("host"))
            call.host = host
            return host
        } catch let e as BridgeHostDirectory.LookupError {
            throw BridgeToolError(e.description)
        }
    }

    /// Runs a script and turns a failed SSH connection into a readable error.
    func run(_ script: String, on host: HostEntry, stdin: Data? = nil, timeout: TimeInterval = 20,
             limit: Int = 400_000, failOnTimeout: Bool = true) async throws -> ShellResult {
        let r = await shell.run(script, on: host, stdin: stdin, timeout: timeout, outputLimit: limit)
        if host.endpoint != nil, r.status == 255, Self.looksLikeSSHFailure(r.err) {
            let reason = r.err.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? ""
            throw BridgeToolError("连不上 \(host.title)：\(reason)\n如果这台机器需要密码或验证码，请先在 LiteMux 里打开它的终端，之后的调用会复用那条连接。")
        }
        if r.timedOut, failOnTimeout {
            throw BridgeToolError("\(host.title) 在 \(Int(timeout)) 秒内没有响应。")
        }
        return r
    }

    static func looksLikeSSHFailure(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return ["ssh:", "permission denied (", "host key verification failed", "connection closed by",
                "control socket", "kex_exchange", "too many authentication failures"].contains { s.contains($0) }
    }

    /// Splits off the `@@lm-session` line and maps tmux markers to errors.
    static func sessionOutput(_ r: ShellResult, host: HostEntry, requested: String?) throws -> (session: String, body: String) {
        var text = r.out
        let firstLine = text.prefix { $0 != "\n" }
        if firstLine.hasPrefix(BridgeScripts.noTmux) {
            throw BridgeToolError("\(host.title) 上找不到 tmux。LiteMux 的窗格开了自动 tmux（会话名 lm_1、lm_2…）才能被读取。")
        }
        if firstLine.hasPrefix(BridgeScripts.noSession) {
            if let requested {
                throw BridgeToolError("\(host.title) 上没有 tmux 会话 \(requested)。先用 list_hosts 看看有哪些会话。")
            }
            throw BridgeToolError("\(host.title) 上还没有 LiteMux 的终端窗格（tmux 会话 lm_*）。请先在 LiteMux 里打开这台主机的终端。")
        }
        guard firstLine.hasPrefix(BridgeScripts.sessionMarker) else {
            let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeToolError("读取 \(host.title) 的终端失败（退出码 \(r.status)）\(err.isEmpty ? "" : "：" + err)")
        }
        let session = String(firstLine.dropFirst(BridgeScripts.sessionMarker.count))
        text = String(text.dropFirst(firstLine.count))
        if text.hasPrefix("\n") { text.removeFirst() }
        return (session, text)
    }

    static func trimTrailingBlankLines(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: - Reading

    var listHosts: BridgeTool {
        BridgeTool(
            name: "list_hosts", title: "列出主机",
            description: "List the servers known to LiteMux (bookmarks, ~/.ssh/config hosts and the local Mac), whether each is connected, and the tmux sessions on connected ones. LiteMux terminal panes are tmux sessions named lm_<n>. Call this first.",
            access: .read, inputSchema: Self.schema([:])
        ) { call in
            let dir = directory()
            call.summary = "\(dir.hosts.count) 台主机"
            let shell = self.shell
            let rows: [(HostEntry, Bool, String?)] = await withTaskGroup(of: (Int, Bool, String?).self) { group in
                for (i, host) in dir.hosts.enumerated() {
                    group.addTask {
                        let connected = await shell.isConnected(host)
                        guard connected else { return (i, false, nil) }
                        let r = await shell.run("echo \"@@now $(date +%s)\"\n" + BridgeScripts.sessions, on: host,
                                                stdin: nil, timeout: 6, outputLimit: 64_000)
                        return (i, true, r.status == 0 ? r.out : nil)
                    }
                }
                var out = [(HostEntry, Bool, String?)](repeating: (.local, false, nil), count: dir.hosts.count)
                for await (i, c, s) in group { out[i] = (dir.hosts[i], c, s) }
                return out
            }
            var lines: [String] = []
            for (host, connected, sessions) in rows {
                let kind: String
                switch host.kind {
                case .bookmark: kind = "书签"
                case .config: kind = "ssh config"
                case .local: kind = "本机"
                }
                var line = "\(connected ? "●" : "○") \(host.title)  [id: \(host.id)]  \(kind)"
                if !host.subtitle.isEmpty, !host.isLocal { line += " · \(host.subtitle)" }
                if !connected { line += " · 未连接" + (host.hasSavedPassword ? "（需密码，请先在 LiteMux 打开终端）" : "（调用工具时用密钥直连）") }
                if host.id == dir.focusedHostID { line += " · ← LiteMux 当前标签页" }
                lines.append(line)
                if let sessions {
                    let s = Self.describeSessions(sessions, openSlots: dir.openSlots[host.id] ?? [])
                    if !s.isEmpty { lines.append(contentsOf: s.map { "    " + $0 }) }
                }
            }
            return BridgeToolResult("LiteMux 主机（● 已连接）\n" + lines.joined(separator: "\n"))
        }
    }

    /// `lm_1  python · /root/yolo · 2 分钟前 · LiteMux 窗格`
    static func describeSessions(_ output: String, openSlots: [Int]) -> [String] {
        var now: Double?
        var rows: [String] = []
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("@@now ") { now = Double(line.dropFirst(6)); continue }
            if line.hasPrefix(BridgeScripts.noTmux) { return ["tmux: 未安装"] }
            let f = line.components(separatedBy: "\t")
            guard f.count >= 5 else { continue }
            var parts = [f[0]]
            if !f[3].isEmpty { parts.append(f[3]) }
            if !f[4].isEmpty { parts.append(f[4]) }
            if let now, let t = Double(f[1]) {
                let m = Int(max(0, now - t) / 60)
                parts.append(m < 1 ? "刚刚有输出" : (m < 60 ? "\(m) 分钟前有输出" : "\(m / 60) 小时前有输出"))
            }
            if f[0].hasPrefix("lm_"), let n = Int(f[0].dropFirst(3)), openSlots.contains(n) { parts.append("LiteMux 窗格") }
            if f[2] != "0" { parts.append("已连接") }
            rows.append(parts.joined(separator: " · "))
        }
        return rows.isEmpty ? [] : ["tmux 会话："] + rows.map { "  " + $0 }
    }

    var readTerminal: BridgeTool {
        BridgeTool(
            name: "read_terminal", title: "读取终端",
            description: "Read the recent output of a LiteMux terminal pane (a tmux session on the host), with soft-wrapped lines joined. Use it to see what a training run, script or shell is printing right now.",
            access: .read,
            inputSchema: Self.schema(["host": Self.hostProperty, "session": Self.sessionProperty,
                                      "lines": Self.integer("How many lines of history to return (default 120).", min: 1, max: 3000)])
        ) { call in
            let host = try resolveHost(call)
            let session = try BridgeScripts.sessionName(call.string("session"))
            let lines = call.int("lines", default: 120, range: 1...3000)
            let r = try await run(BridgeScripts.capture(session: session, lines: lines), on: host)
            let (name, body) = try Self.sessionOutput(r, host: host, requested: session)
            call.summary = "\(name) · \(lines) 行"
            let text = Self.trimTrailingBlankLines(body)
            let shown = text.components(separatedBy: "\n").suffix(lines).joined(separator: "\n")
            return BridgeToolResult("\(host.title) · tmux \(name) · 最近 \(lines) 行\n────────\n\(shown)")
        }
    }

    var trainingStatus: BridgeTool {
        BridgeTool(
            name: "training_status", title: "训练进度",
            description: "Summarise a training run from a terminal pane's log: status (running/finished/crashed/diverged), epoch progress, latest/best values and trend of each metric (loss, val_loss, mAP, acc, lr …), a downsampled curve of the main loss, and the previous run for comparison. Understands PyTorch/Lightning/Keras/HF/Ultralytics/mmdet-style logs. Parsing happens in LiteMux; nothing is installed on the server.",
            access: .read,
            inputSchema: Self.schema(["host": Self.hostProperty, "session": Self.sessionProperty,
                                      "lines": Self.integer("How much history to scan (default 4000 lines).", min: 50, max: 20000)])
        ) { call in
            let host = try resolveHost(call)
            let session = try BridgeScripts.sessionName(call.string("session"))
            let lines = call.int("lines", default: 4000, range: 50...20000)
            let r = try await run(BridgeScripts.capture(session: session, lines: lines), on: host, limit: 4_000_000)
            let (name, body) = try Self.sessionOutput(r, host: host, requested: session)
            let tracker = TrainingTracker()
            _ = tracker.ingest(lines: body.components(separatedBy: "\n"))
            guard let run = tracker.current else {
                call.summary = "\(name) · 未识别"
                return BridgeToolResult("\(host.title) · tmux \(name)：最近 \(lines) 行里没有认出训练日志（epoch / loss / acc 之类）。可以用 read_terminal 直接看输出。")
            }
            call.summary = "\(name) · " + TrainingSummary.headline(run)
            return BridgeToolResult("\(host.title) · tmux \(name)\n" + TrainingSummary.text(run: run, previous: tracker.previous))
        }
    }

    var gpuStatus: BridgeTool {
        BridgeTool(
            name: "gpu_status", title: "GPU 与资源",
            description: "GPU utilisation, memory, temperature and power per card (nvidia-smi), the processes holding GPU memory, plus load average, RAM and free disk in $HOME. Use it to check whether a GPU is free before starting a job or why training is slow.",
            access: .read, inputSchema: Self.schema(["host": Self.hostProperty])
        ) { call in
            let host = try resolveHost(call)
            let r = try await run(BridgeScripts.gpu, on: host)
            let report = GPUReport.parse(r.out)
            call.summary = report.gpus.isEmpty ? "无 GPU" : "\(report.gpus.count) 张 GPU"
            return BridgeToolResult("\(host.title)\n" + report.text)
        }
    }

    var listDirectory: BridgeTool {
        BridgeTool(
            name: "list_directory", title: "列出目录",
            description: "List a directory on the host (ls -lA). Paths may start with ~.",
            access: .read,
            inputSchema: Self.schema(["host": Self.hostProperty, "path": Self.string("Directory path, e.g. ~/runs or /root/autodl-tmp.")],
                                     required: ["path"])
        ) { call in
            let host = try resolveHost(call)
            guard let path = call.string("path") else { throw BridgeToolError("缺少 path。") }
            call.summary = path
            let r = try await run(BridgeScripts.listDirectory(path), on: host)
            guard r.status == 0 else { throw BridgeToolError(r.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return BridgeToolResult("\(host.title):\(r.out)")
        }
    }

    var readFile: BridgeTool {
        BridgeTool(
            name: "read_file", title: "读取文件",
            description: "Read a text file on the host: configs, scripts, logs, CSV results. Use tail_lines for the end of a long log. Binary files are refused.",
            access: .read,
            inputSchema: Self.schema(["host": Self.hostProperty,
                                      "path": Self.string("File path; may start with ~."),
                                      "tail_lines": Self.integer("Return only the last N lines.", min: 1, max: 20000),
                                      "max_bytes": Self.integer("Byte limit (default 200000).", min: 1, max: 2_000_000)],
                                     required: ["path"])
        ) { call in
            let host = try resolveHost(call)
            guard let path = call.string("path") else { throw BridgeToolError("缺少 path。") }
            let maxBytes = call.int("max_bytes", default: 200_000, range: 1...2_000_000)
            let tail = call.arguments["tail_lines"]?.intValue.map { min(20000, max(1, $0)) }
            call.summary = path
            let r = try await run(BridgeScripts.readFile(path, maxBytes: maxBytes, tailLines: tail), on: host, limit: maxBytes + 4096)
            guard r.status == 0 else { throw BridgeToolError(r.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let marker = Data(("\n" + BridgeScripts.dataMarker + "\n").utf8)
            guard let range = r.stdout.range(of: marker) else { throw BridgeToolError("读取 \(path) 失败。") }
            let size = Int(String(decoding: r.stdout[..<range.lowerBound], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let content = r.stdout[range.upperBound...]
            if content.prefix(8192).contains(0) {
                throw BridgeToolError("\(path) 是二进制文件（\(size) 字节），不能当文本读取。")
            }
            var header = "\(host.title):\(path) · \(size) 字节"
            if let tail { header += " · 最后 \(tail) 行" } else if size > maxBytes { header += " · 只显示前 \(maxBytes) 字节" }
            return BridgeToolResult(header + "\n────────\n" + String(decoding: content, as: UTF8.self))
        }
    }

    // MARK: - Acting (confirmed)

    var runCommand: BridgeTool {
        BridgeTool(
            name: "run_command", title: "执行命令",
            description: "Run a short, non-interactive shell command on the host (bash -lc, so the profile's PATH applies) and return exit code, stdout and stderr. For long-running jobs such as training, use send_to_terminal instead so the job lives in a tmux pane. May require the user's approval in LiteMux.",
            access: .exec,
            inputSchema: Self.schema(["host": Self.hostProperty,
                                      "command": Self.string("The command line to run."),
                                      "cwd": Self.string("Working directory; may start with ~."),
                                      "timeout_seconds": Self.integer("Kill the command after this many seconds (default 60).", min: 1, max: 600)],
                                     required: ["command"])
        ) { call in
            let host = try resolveHost(call)
            guard let command = call.rawString("command"), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BridgeToolError("缺少 command。")
            }
            let cwd = call.string("cwd")
            let timeout = call.int("timeout_seconds", default: 60, range: 1...600)
            call.summary = command.count > 160 ? String(command.prefix(160)) + "…" : command
            try await call.authorize(action: "执行命令", detail: (cwd.map { "cd \($0)\n" } ?? "") + command)
            let r = try await run(BridgeScripts.run(command: command, directory: cwd), on: host,
                                  timeout: TimeInterval(timeout), limit: 120_000, failOnTimeout: false)
            var text = "\(host.title) · 退出码 \(r.status) · \(String(format: "%.1f", r.duration)) 秒"
            if r.timedOut { text += " · 超时（\(timeout) 秒）已终止" }
            if r.truncated { text += " · 输出过长，已省略中间部分" }
            let out = Self.trimTrailingBlankLines(r.out), err = Self.trimTrailingBlankLines(r.err)
            if !out.isEmpty { text += "\n──── stdout ────\n" + out }
            if !err.isEmpty { text += "\n──── stderr ────\n" + err }
            if out.isEmpty, err.isEmpty { text += "\n（没有输出）" }
            return BridgeToolResult(text, isError: r.status != 0)
        }
    }

    var sendToTerminal: BridgeTool {
        BridgeTool(
            name: "send_to_terminal", title: "向终端输入",
            description: "Type text into a LiteMux terminal pane (tmux send-keys) and press Enter, e.g. to start or resume a training run where the user can watch it. Set interrupt to send Ctrl-C first. Returns the pane's last lines after a short wait. May require the user's approval in LiteMux.",
            access: .exec,
            inputSchema: Self.schema(["host": Self.hostProperty, "session": Self.sessionProperty,
                                      "text": Self.string("Text to type. Leave empty to only interrupt or press Enter."),
                                      "enter": Self.boolean("Press Enter after the text (default true)."),
                                      "interrupt": Self.boolean("Send Ctrl-C before typing (default false)."),
                                      "wait_seconds": Self.number("Seconds to wait before reading the pane back (default 1.5, max 10).")])
        ) { call in
            let host = try resolveHost(call)
            let session = try BridgeScripts.sessionName(call.string("session"))
            let text = call.rawString("text") ?? ""
            let enter = call.bool("enter", default: true)
            let interrupt = call.bool("interrupt", default: false)
            guard !text.isEmpty || enter || interrupt else { throw BridgeToolError("没有要发送的内容。") }
            let wait = call.double("wait_seconds", default: 1.5, range: 0...10)
            call.summary = (interrupt ? "⌃C " : "") + (text.count > 160 ? String(text.prefix(160)) + "…" : text)
            let target = session ?? "最近活跃的 LiteMux 窗格"
            try await call.authorize(action: "向终端 \(target) 输入",
                                     detail: (interrupt ? "⌃C（先中断当前程序）\n" : "") + text + (enter ? "  ⏎" : ""))
            let r = try await run(BridgeScripts.send(session: session, text: text, enter: enter, interrupt: interrupt,
                                                     settle: wait, tail: 40), on: host, timeout: 20 + wait)
            let (name, body) = try Self.sessionOutput(r, host: host, requested: session)
            call.summary = "\(name) · " + call.summary
            let screen = body.components(separatedBy: BridgeScripts.dataMarker + "\n").last ?? body
            return BridgeToolResult("已发送到 \(host.title) · tmux \(name)。窗格最后几行：\n────────\n" + Self.trimTrailingBlankLines(screen))
        }
    }

    var writeFile: BridgeTool {
        BridgeTool(
            name: "write_file", title: "写入文件",
            description: "Create or overwrite a text file on the host (parent directories are created), or append to it. Use for configs and scripts. Requires the user's approval in LiteMux unless they trust the agent.",
            access: .write,
            inputSchema: Self.schema(["host": Self.hostProperty,
                                      "path": Self.string("File path; may start with ~."),
                                      "content": Self.string("The full text to write."),
                                      "append": Self.boolean("Append instead of overwriting (default false).")],
                                     required: ["path", "content"])
        ) { call in
            let host = try resolveHost(call)
            guard let path = call.string("path") else { throw BridgeToolError("缺少 path。") }
            let content = call.rawString("content") ?? ""
            let data = Data(content.utf8)
            guard data.count <= 5_000_000 else { throw BridgeToolError("内容超过 5 MB，请分块写入或改用 scp。") }
            let append = call.bool("append", default: false)
            call.summary = "\(path) · \(data.count) 字节"
            let preview = content.components(separatedBy: "\n").prefix(24).joined(separator: "\n")
            try await call.authorize(action: append ? "追加到文件" : "写入文件",
                                     detail: "\(path)（\(data.count) 字节）\n────────\n\(preview)")
            let r = try await run(BridgeScripts.write(path: path, append: append), on: host, stdin: data, timeout: 60)
            guard r.status == 0 else {
                throw BridgeToolError("写入失败：" + r.err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let size = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return BridgeToolResult("已\(append ? "追加" : "写入") \(host.title):\(path)（文件现在 \(size) 字节）。")
        }
    }
}

// MARK: - Formatting

/// Plain-text summary of a run for agents.
public enum TrainingSummary {
    public static func value(_ v: Double, name: String = "") -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v > 0 ? "inf" : "-inf" }
        if MetricLineParser.isLearningRate(name) || (v != 0 && abs(v) < 1e-3) { return String(format: "%.2e", v) }
        if abs(v) >= 1000 { return String(format: "%.0f", v) }
        if abs(v) >= 100 { return String(format: "%.1f", v) }
        return String(format: "%.4f", v)
    }

    public static func status(_ run: TrainingRun) -> String {
        switch run.status {
        case .running: return "训练中"
        case .finished: return "已结束"
        case .diverged(let m): return "发散（\(m) 出现 NaN/inf）"
        case .crashed(let reason): return "已崩溃：\(reason)"
        }
    }

    public static func progress(_ run: TrainingRun) -> String? {
        var parts: [String] = []
        if let e = run.epoch {
            let shown = e.rounded() == e ? String(Int(e)) : String(format: "%.2f", e)
            parts.append(run.epochTotal.map { "epoch \(shown)/\($0)" } ?? "epoch \(shown)")
        }
        if let s = run.step {
            parts.append(run.stepTotal.map { "step \(s)/\($0)" } ?? "step \(s)")
        }
        if let f = run.fraction { parts.append(String(format: "%.0f%%", f * 100)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func headline(_ run: TrainingRun) -> String {
        var s = status(run)
        if let p = progress(run) { s += " · " + p }
        if let primary = run.primary, let last = primary.last { s += " · \(primary.name) \(value(last, name: primary.name))" }
        return s
    }

    static func trendWord(_ s: MetricSeries) -> String {
        guard !s.isLearningRate else { return "" }
        switch s.trend {
        case -1: return s.lowerIsBetter ? "↓ 在变好" : "↓ 在变差"
        case 1: return s.lowerIsBetter ? "↑ 在变差" : "↑ 在变好"
        default: return "→ 基本持平"
        }
    }

    /// At most `count` points, evenly spaced, always keeping the last one.
    public static func downsample(_ points: [MetricPoint], to count: Int) -> [MetricPoint] {
        guard points.count > count, count >= 2 else { return points }
        let step = Double(points.count - 1) / Double(count - 1)
        return (0..<count).map { points[Int((Double($0) * step).rounded())] }
    }

    static func x(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%.2f", v) }

    public static func text(run: TrainingRun, previous: TrainingRun?) -> String {
        var lines = ["状态：" + status(run) + (progress(run).map { " · " + $0 } ?? "")]
        let series = run.orderedSeries
        if !series.isEmpty {
            lines.append("指标（最新 · 最佳 · 趋势）：")
            let width = min(18, series.map(\.name.count).max() ?? 4)
            for s in series {
                guard let last = s.last else { continue }
                var row = "  " + s.name.padding(toLength: max(width, s.name.count), withPad: " ", startingAt: 0)
                row += "  " + value(last, name: s.name)
                if let best = s.best { row += "  · 最佳 " + value(best, name: s.name) }
                let t = trendWord(s)
                if !t.isEmpty { row += "  · " + t }
                lines.append(row)
            }
        }
        if let primary = run.primary, primary.points.count >= 2 {
            let pts = downsample(primary.points, to: 24)
            lines.append("\(primary.name) 曲线（x: y）：" + pts.map { "\(x($0.x)): \(value($0.y, name: primary.name))" }.joined(separator: ", "))
        }
        if let previous, let p = previous.primary, let last = p.last {
            var prev = "上一次运行：" + status(previous)
            if let pr = progress(previous) { prev += " · " + pr }
            prev += " · \(p.name) 最终 \(value(last, name: p.name))"
            if let best = p.best { prev += "，最佳 \(value(best, name: p.name))" }
            lines.append(prev)
        }
        return lines.joined(separator: "\n")
    }
}

/// Parsed output of `BridgeScripts.gpu`.
public struct GPUReport: Equatable, Sendable {
    public struct GPU: Equatable, Sendable {
        public var index: Int
        public var name: String
        public var utilization: Double?
        public var memoryUsedMiB: Double?
        public var memoryTotalMiB: Double?
        public var temperature: Double?
        public var power: Double?
        public var processes: [(pid: Int, memoryMiB: Double?, name: String)] = []

        public static func == (a: GPU, b: GPU) -> Bool {
            a.index == b.index && a.name == b.name && a.utilization == b.utilization && a.memoryUsedMiB == b.memoryUsedMiB
                && a.processes.map(\.pid) == b.processes.map(\.pid)
        }
    }

    public var gpus: [GPU] = []
    public var hasNvidiaSMI = false
    public var load: String?
    public var cpus: Int?
    public var memory: String?
    public var disk: String?

    public static func parse(_ output: String) -> GPUReport {
        var report = GPUReport()
        var section = ""
        var uuidToIndex: [String: Int] = [:]
        var procs: [(uuid: String, pid: Int, mem: Double?, name: String)] = []
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") { section = String(line.dropFirst(3)); continue }
            guard !line.isEmpty else { continue }
            let f = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            switch section {
            case "gpu":
                if line == "none" { continue }
                report.hasNvidiaSMI = true
                guard f.count >= 5, let index = Int(f[0]) else { continue }
                func num(_ i: Int) -> Double? { i < f.count ? Double(f[i]) : nil }
                report.gpus.append(GPU(index: index, name: f[1], utilization: num(2), memoryUsedMiB: num(3),
                                       memoryTotalMiB: num(4), temperature: num(5), power: num(6)))
            case "procs":
                guard f.count >= 4, let pid = Int(f[1]) else { continue }
                procs.append((f[0], pid, Double(f[2]), f[3...].joined(separator: ",")))
            case "uuids":
                if f.count >= 2, let i = Int(f[0]) { uuidToIndex[f[1]] = i }
            case "load": report.load = line
            case "cpus": report.cpus = Int(line)
            case "mem": report.memory = line
            case "disk": report.disk = line
            default: break
            }
        }
        for p in procs {
            guard let i = uuidToIndex[p.uuid], let k = report.gpus.firstIndex(where: { $0.index == i }) else { continue }
            report.gpus[k].processes.append((p.pid, p.mem, p.name))
        }
        return report
    }

    public var text: String {
        var lines: [String] = []
        if gpus.isEmpty {
            lines.append(hasNvidiaSMI ? "nvidia-smi 没有返回 GPU。" : "没有 nvidia-smi（这台机器可能没有 NVIDIA GPU）。")
        }
        for g in gpus {
            var row = "GPU\(g.index) \(g.name)"
            if let u = g.utilization { row += String(format: " · 利用率 %.0f%%", u) }
            if let used = g.memoryUsedMiB, let total = g.memoryTotalMiB {
                row += String(format: " · 显存 %.1f/%.1f GiB", used / 1024, total / 1024)
                if total > 0, used / total < 0.05, (g.utilization ?? 0) < 5 { row += "（空闲）" }
            }
            if let t = g.temperature { row += String(format: " · %.0f°C", t) }
            if let p = g.power { row += String(format: " · %.0f W", p) }
            lines.append(row)
            for p in g.processes {
                lines.append("    pid \(p.pid) \(p.name)" + (p.memoryMiB.map { String(format: " · %.0f MiB", $0) } ?? ""))
            }
        }
        if let load { lines.append("负载：" + load + (cpus.map { "（\($0) 核）" } ?? "")) }
        if let memory {
            // free -m: Mem: total used free shared buff/cache available
            let f = memory.split(separator: " ").compactMap { Double($0) }
            if f.count >= 6 {
                lines.append(String(format: "内存：已用 %.1f / %.1f GiB，可用 %.1f GiB", f[1] / 1024, f[0] / 1024, f[5] / 1024))
            } else {
                lines.append("内存：" + memory)
            }
        }
        if let disk {
            let f = disk.split(separator: " ")
            lines.append(f.count >= 6 ? "磁盘（\(f[5])）：可用 \(f[3]) / \(f[1])" : "磁盘：" + disk)
        }
        return lines.joined(separator: "\n")
    }
}
