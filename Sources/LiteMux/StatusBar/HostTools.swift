import AppKit
import SwiftUI
import Observation
import Darwin
import LiteMuxCore

/// Port tunnels and tmux sessions of the foreground host, behind the host name
/// in the status bar. Everything rides on the terminal's ControlMaster: a
/// tunnel is `ssh -O forward -L …`, so it needs no new login and ends with it.
@MainActor @Observable
final class HostTools {
    struct Forward: Identifiable, Hashable {
        let hostID: String
        let remotePort: Int
        let localPort: Int
        var label: String
        /// Where the service listens on the remote side (IPv4 unless it is IPv6-only).
        var remoteAddress = "127.0.0.1"
        var id: String { "\(hostID):\(localPort)" }
        var url: URL { URL(string: "http://localhost:\(localPort)")! }
        var spec: String { "127.0.0.1:\(localPort):\(remoteAddress):\(remotePort)" }
    }

    struct Session: Identifiable, Hashable {
        let name: String
        let command: String
        let path: String
        let attached: Bool
        var id: String { name }
        var isLiteMux: Bool { name.hasPrefix("lm_") && Int(name.dropFirst(3)) != nil }
    }

    private(set) var hostID: String?
    private(set) var sessions: [Session] = []
    private(set) var ports: [ListeningPort] = []
    private(set) var forwards: [Forward] = []
    private(set) var loading = false
    private(set) var hasTmux = true
    private(set) var error: String?

    @ObservationIgnored weak var app: AppModel?

    func forwards(for hostID: String) -> [Forward] { forwards.filter { $0.hostID == hostID } }

    private func shell(for host: HostEntry) -> ProcessBridgeShell? {
        guard let hub = app?.hub else { return nil }
        let env = hub.environment(for: host)
        return ProcessBridgeShell(invocation: hub.invocation) { _ in env }
    }

    func refresh(_ host: HostEntry) async {
        guard let shell = shell(for: host) else { return }
        if hostID != host.id {
            sessions = []
            ports = []
        }
        hostID = host.id
        loading = true
        defer { loading = false }
        let script = "(\n" + BridgeScripts.sessions + "\n)\necho '## ports'\n" + BridgeScripts.listeningPorts + "\n"
        let r = await shell.run(script, on: host, stdin: nil, timeout: 8, outputLimit: 200_000)
        guard hostID == host.id else { return }
        guard r.status == 0 else {
            let reason = r.err.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
            error = r.timedOut ? "没有响应" : (reason ?? "读取失败")
            return
        }
        error = nil
        let parts = r.out.components(separatedBy: "## ports\n")
        let sessionText = parts.first ?? ""
        hasTmux = !sessionText.hasPrefix(BridgeScripts.noTmux)
        sessions = sessionText.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 5 else { return nil }
            return Session(name: f[0], command: f[3], path: f[4], attached: f[2] != "0")
        }
        .sorted { ($0.isLiteMux ? 1 : 0, $0.name) < ($1.isLiteMux ? 1 : 0, $1.name) }
        ports = ListeningPort.parse(parts.count > 1 ? parts[1] : "")
    }

    /// Opens a tunnel from a free local port (the same number when possible).
    @discardableResult
    func forward(_ remotePort: Int, label: String? = nil, on host: HostEntry, open: Bool = true) async -> Forward? {
        guard let app, let endpoint = host.endpoint else { return nil }
        if let existing = forwards.first(where: { $0.hostID == host.id && $0.remotePort == remotePort }) {
            if open { _ = NSWorkspace.shared.open(existing.url) }
            return existing
        }
        let taken = Set(forwards.map(\.localPort))
        guard let local = Self.freeLocalPort(startingAt: remotePort, excluding: taken) else {
            app.toast("本机找不到空闲端口", style: .error)
            return nil
        }
        let name = label ?? ports.first(where: { $0.port == remotePort })?.label ?? "端口 \(remotePort)"
        var f = Forward(hostID: host.id, remotePort: remotePort, localPort: local, label: name)
        if let addrs = ports.first(where: { $0.port == remotePort })?.addresses,
           !addrs.isEmpty, addrs.allSatisfy({ $0.contains(":") }) {
            f.remoteAddress = "[::1]"
        }
        let args = ["-o", "ControlPath=\(app.hub.invocation.controlPath)", "-O", "forward", "-L", f.spec]
            + endpoint.arguments(home: app.hub.invocation.home)
        let r = await ProcessRunner.run(SSHInvocation.sshPath, args, environment: app.hub.environment(for: host), timeout: 6)
        if ProcessInfo.processInfo.environment["LITEMUX_SMOKE_HOSTTOOLS"] == "1" {
            FileHandle.standardError.write(Data("smoke: ssh \(args.joined(separator: " ")) → \(r.status) \(r.stderr)\n".utf8))
        }
        guard r.status == 0 else {
            let reason = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let noMaster = reason.contains("No such file") || reason.contains("Control socket") || reason.contains("No ControlPath")
            app.toast(noMaster ? "先在 LiteMux 里打开 \(host.title) 的终端，端口转发复用那条连接" : "端口转发失败：\(reason)", style: .error)
            return nil
        }
        forwards.append(f)
        let action: (String, () -> Void)? = open ? nil : ("打开", { _ = NSWorkspace.shared.open(f.url) })
        app.toast("已转发 \(name)：localhost:\(local) → \(host.title):\(remotePort)", style: .success, action: action)
        if open {
            // The tunnel is up at once; the service on the other side may take a beat.
            try? await Task.sleep(nanoseconds: 250_000_000)
            _ = NSWorkspace.shared.open(f.url)
        }
        return f
    }

    func cancel(_ f: Forward, on host: HostEntry) async {
        guard let app, let endpoint = host.endpoint else { return }
        let args = ["-o", "ControlPath=\(app.hub.invocation.controlPath)", "-O", "cancel", "-L", f.spec]
            + endpoint.arguments(home: app.hub.invocation.home)
        _ = await ProcessRunner.run(SSHInvocation.sshPath, args, environment: app.hub.environment(for: host), timeout: 6)
        forwards.removeAll { $0.id == f.id }
    }

    static func freeLocalPort(startingAt port: Int, excluding taken: Set<Int>) -> Int? {
        let first = (1024...65535).contains(port) ? port : 10000 + port % 1000
        for p in first..<min(65535, first + 200) where !taken.contains(p) && isFree(p) { return p }
        return nil
    }

    static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return ok == 0
    }
}

/// The popover: tunnels first (that is what one opens it for), then sessions.
struct HostToolsView: View {
    let tools: HostTools
    let host: HostEntry
    let app: AppModel
    @State private var customPort = ""

    var body: some View {
        let forwards = tools.forwards(for: host.id)
        let offered = tools.ports.filter { p in p.looksLikeWeb && !forwards.contains { $0.remotePort == p.port } }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(host.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if tools.loading { ProgressView().controlSize(.small) }
                Button { Task { await tools.refresh(host) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("刷新")
            }

            section("端口转发") {
                ForEach(forwards) { f in
                    row {
                        Image(systemName: "arrow.left.arrow.right").foregroundStyle(Theme.accentColor).font(.system(size: 10))
                        Text("localhost:\(String(f.localPort))").font(.system(size: 12, design: .monospaced))
                            .fixedSize()
                        Text(([f.remotePort == f.localPort ? nil : "→ \(f.remotePort)",
                               f.label.hasPrefix("端口 ") ? nil : f.label] as [String?]).compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Button("打开") { _ = NSWorkspace.shared.open(f.url) }
                        Button("停止") { Task { await tools.cancel(f, on: host) } }
                    }
                }
                ForEach(offered) { p in
                    row {
                        Text(String(p.port)).font(.system(size: 12, design: .monospaced)).frame(minWidth: 42, alignment: .leading)
                        Text(p.label)
                        if let proc = p.process, proc.lowercased() != p.label.lowercased() {
                            Text(proc).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("转发并打开") { Task { await tools.forward(p.port, label: p.label, on: host) } }
                    }
                }
                if forwards.isEmpty, offered.isEmpty, !tools.loading {
                    Text(tools.error.map { "读取失败：\($0)" } ?? "没发现网页类服务在监听。TensorBoard、Jupyter 启动后会出现在这里。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    TextField("远端端口，如 6006", text: $customPort)
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                        .onSubmit(forwardCustom)
                    Button("转发", action: forwardCustom).disabled(Int(customPort) == nil)
                }
            }

            section("tmux 会话") {
                if !tools.hasTmux {
                    Text("这台主机没有安装 tmux。").foregroundStyle(.secondary)
                } else if tools.sessions.isEmpty, !tools.loading {
                    Text("还没有 tmux 会话。").foregroundStyle(.secondary)
                }
                ForEach(tools.sessions) { s in
                    row {
                        Image(systemName: s.isLiteMux ? "rectangle.split.2x1" : "terminal")
                            .foregroundStyle(.secondary).font(.system(size: 10)).frame(width: 14)
                        Text(s.name).font(.system(size: 12, design: .monospaced))
                        Text([s.command, s.path].filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer()
                        if app.isTmuxSessionOpen(s.name, hostID: host.id) {
                            Button("显示") { app.openTmuxSession(s.name, host: host, select: true) }
                        } else {
                            Button(s.isLiteMux ? "打开" : "接管") { app.openTmuxSession(s.name, host: host, select: true) }
                                .help(s.isLiteMux ? "在新标签页打开这个窗格" : "直接接入 \(s.name)，不套在 lm_ 会话里")
                        }
                    }
                }
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(14)
        .frame(width: 400)
        .task { await tools.refresh(host) }
    }

    private func forwardCustom() {
        guard let p = Int(customPort), (1...65535).contains(p) else { return }
        customPort = ""
        Task { await tools.forward(p, on: host) }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).textCase(nil)
            content()
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.vertical, 3).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

/// "GPU 已空闲" for bookmark hosts (the rented-by-the-hour kind): after a job
/// kept the cards busy, five quiet minutes earn one notification.
@MainActor
final class GPUIdleWatch {
    private var detectors: [String: GPUIdleDetector] = [:]

    func observe(_ sample: ServerSample, host: HostEntry) {
        guard host.kind == .bookmark, !sample.gpus.isEmpty else { return }
        var d = detectors[host.id] ?? GPUIdleDetector()
        let fire = d.observe(sample.gpus)
        detectors[host.id] = d
        guard fire else { return }
        let cards = sample.gpus.count == 1 ? "GPU" : "\(sample.gpus.count) 张 GPU"
        TrainingNotifier.postSystem(title: "\(host.title) · \(cards) 已空闲 5 分钟",
                                    body: "刚才的任务结束了。按时计费的机器不用的话，记得关机或释放实例。")
    }
}
