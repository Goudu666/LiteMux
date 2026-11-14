import AppKit
import SwiftUI
import LiteMuxCore

/// Sidebar "Agent": what local coding agents are doing on servers right now,
/// what they did recently, and the tunnels they left open. A click watches
/// the same tmux session (read-only) or opens a terminal where they work.
struct AgentPanel: View {
    let model: AppModel
    @Bindable var watch: AgentWatch
    @State private var expanded: Set<String> = []
    @State private var showOthers = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairlineColor).frame(height: 1)
            if !watch.scanned {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if watch.live.isEmpty && watch.recent.isEmpty && watch.tunnels.isEmpty && watch.others.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !watch.live.isEmpty {
                            SectionTitle("正在运行", trailing: "\(watch.live.count)")
                            ForEach(watch.live) { row in LiveRow(row: row, model: model) }
                        }
                        if !watch.tunnels.isEmpty {
                            SectionTitle("留着的隧道", trailing: nil)
                            ForEach(watch.tunnels) { t in TunnelRow(tunnel: t, model: model) }
                        }
                        if !watch.recent.isEmpty {
                            SectionTitle("最近", trailing: nil)
                            ForEach(watch.recent) { a in
                                HistoryRow(action: a, model: model, expanded: expanded.contains(a.id)) {
                                    if expanded.contains(a.id) { expanded.remove(a.id) } else { expanded.insert(a.id) }
                                }
                            }
                        }
                        if !watch.others.isEmpty {
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) { showOthers.toggle() }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8, weight: .bold))
                                        .rotationEffect(.degrees(showOthers ? 90 : 0))
                                    Text("其他终端里的 ssh")
                                    Spacer()
                                    Text("\(watch.others.count)").monospacedDigit()
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if showOthers {
                                ForEach(watch.others) { row in LiveRow(row: row, model: model) }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .onAppear { watch.poke() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accentColor)
            Text("Agent 同屏")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Menu {
                Toggle("读取 Agent 会话记录（命令与输出）", isOn: $watch.readsTranscripts)
                Button("清空最近记录") { watch.clearHistory() }
                Divider()
                Button("接入 Coding Agent…") { model.showAgentBridge = true }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 11.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
            Text("还没看到 Agent 连服务器").font(.system(size: 12.5, weight: .semibold))
            Text("本机的 Claude Code、Codex 用 ssh 连服务器时，会出现在这里：在哪台机器、跑什么、哪个 tmux 会话。点一下就能旁观，或者接上它已经登录好的连接。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("接入 Coding Agent…") { model.showAgentBridge = true }
                .controlSize(.small)
                .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pieces

private struct SectionTitle: View {
    let title: String
    let trailing: String?
    init(_ title: String, trailing: String?) {
        self.title = title
        self.trailing = trailing
    }
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing { Text(trailing).monospacedDigit() }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

/// `CC` in a small rounded tile, tinted with the accent.
struct AgentBadge: View {
    let agent: AgentKind?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(agent == nil ? Color.primary.opacity(0.07) : Theme.accentColor.opacity(0.14))
            if let agent {
                Text(agent.monogram)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accentColor)
            } else {
                Image(systemName: "terminal").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 15)
        .help(agent?.title ?? "终端")
    }
}

private struct Chip: View {
    let icon: String
    let text: String
    var accent = false
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8.5, weight: .semibold))
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 10))
        .foregroundStyle(accent ? AnyShapeStyle(Theme.accentColor) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(accent ? Theme.accentColor.opacity(0.11) : Color.primary.opacity(0.05)))
    }
}

/// A row that highlights on hover like a sidebar list row.
private struct RowShell<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var hovering = false
    var body: some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.055 : 0)))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

enum AgentFormat {
    static func elapsed(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h\(s % 3600 / 60)m"
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    static func clock(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? time.string(from: d) : dayTime.string(from: d)
    }

    /// Host title, or a suggested name for a server LiteMux does not know yet.
    static func hostLabel(_ hostID: String?, endpoint: SSHEndpoint?, destination: String, model: AppModel) -> (String, Bool) {
        if let hostID, let h = model.host(hostID) { return (h.title, true) }
        if let endpoint { return (SSHCommandParser.suggestName(for: endpoint), false) }
        return (destination, false)
    }

    static func shortDir(_ d: String) -> String {
        d.count > 26 ? "…" + d.suffix(25) : d
    }
}

// MARK: - Live

private struct LiveRow: View {
    let row: AgentWatch.Live
    let model: AppModel

    var body: some View {
        let insight = row.insight
        let (host, known) = AgentFormat.hostLabel(row.hostID, endpoint: row.ssh.argv.endpoint,
                                                  destination: row.ssh.argv.destination, model: model)
        RowShell {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    AgentBadge(agent: row.ssh.agent)
                    Text(host).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if !known { Chip(icon: "plus", text: "未保存") }
                    Spacer(minLength: 2)
                    PulseDot()
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(AgentFormat.elapsed(row.ssh.elapsed + ctx.date.timeIntervalSince(row.firstSeen)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(row.ssh.argv.noCommand ? "端口转发 " + row.ssh.argv.forwards.joined(separator: " ") : insight.headline)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.leading, 26)
                if let note = row.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 26)
                }
                let chips = chipsFor(insight)
                if !chips.isEmpty || row.socket != nil || row.ssh.app != nil {
                    HStack(spacing: 4) {
                        if let app = row.ssh.app { Chip(icon: "macwindow", text: app) }
                        if let s = insight.tmuxSessions.last { Chip(icon: "eye", text: s, accent: true) }
                        if row.socket != nil { Chip(icon: "link", text: "可复用连接", accent: true) }
                        if let d = insight.directory { Chip(icon: "folder", text: AgentFormat.shortDir(d)) }
                    }
                    .padding(.leading, 26)
                }
            }
        }
        .onTapGesture { model.watchAgent(row) }
        .help(clickHelp(insight))
        .contextMenu { menu(insight) }
    }

    private func chipsFor(_ i: RemoteCommandInsight) -> [String] {
        [i.tmuxSessions.last, i.directory].compactMap { $0 }
    }

    private func clickHelp(_ i: RemoteCommandInsight) -> String {
        var s = row.ssh.argv.remoteCommand.isEmpty ? "ssh \(row.ssh.argv.destination)" : row.ssh.argv.remoteCommand
        if let t = i.tmuxSessions.last { s += "\n\n点击：只读旁观 tmux 会话 \(t)" }
        else if let l = i.logFiles.first { s += "\n\n点击：打开日志 \(l)" }
        else { s += "\n\n点击：在这台机器上打开终端" }
        return s
    }

    @ViewBuilder private func menu(_ i: RemoteCommandInsight) -> some View {
        let ep = row.ssh.argv.endpoint
        if let t = i.tmuxSessions.last {
            Button("只读旁观 tmux「\(t)」") { model.watchAgent(row) }
            Button("接管 tmux「\(t)」（可以输入）") { model.watchAgent(row, takeOver: true) }
            Divider()
        }
        if let l = i.logFiles.first {
            Button("打开日志 \(l)") {
                let h = model.hostForAgent(hostID: row.hostID, endpoint: ep)
                model.openRemoteFile(AppModel.path(l, in: i.directory), on: h)
            }
        }
        Button(i.directory.map { "在 \($0) 打开终端" } ?? "打开终端") {
            model.openAgentTerminal(endpoint: ep, hostID: row.hostID, directory: i.directory)
        }
        Button("浏览文件") { model.browseAgentFiles(endpoint: ep, hostID: row.hostID, directory: i.directory) }
        Divider()
        if row.hostID == nil {
            Button("导入为书签") { _ = model.hostForAgent(hostID: nil, endpoint: ep) }
        }
        Button("复制命令") {
            model.copyText(row.ssh.argv.remoteCommand.isEmpty ? ep.commandLine : row.ssh.argv.remoteCommand, note: "已复制命令")
        }
    }
}

/// A slow breathing dot: this is happening now.
private struct PulseDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color(nsColor: Theme.online))
            .frame(width: 6, height: 6)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - Tunnels

private struct TunnelRow: View {
    let tunnel: AgentWatch.Tunnel
    let model: AppModel

    var body: some View {
        let (title, known) = AgentFormat.hostLabel(tunnel.hostID, endpoint: tunnel.endpoint,
                                                   destination: (tunnel.master.socketPath as NSString).lastPathComponent, model: model)
        RowShell {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accentColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if !known && tunnel.endpoint != nil { Chip(icon: "plus", text: "未保存") }
                    }
                    Text(ShellWords.abbreviateHome(tunnel.master.socketPath))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
        }
        .onTapGesture { model.openTunnel(tunnel) }
        .help("一条已经登录好的 ControlMaster 隧道。点击：借它打开终端，不用再输密码或验证码。")
        .contextMenu {
            Button("借这条隧道打开终端") { model.openTunnel(tunnel) }
            Button("复制套接字路径") { model.copyText(tunnel.master.socketPath, note: "已复制套接字路径") }
        }
    }
}

// MARK: - History

private struct HistoryRow: View {
    let action: AgentAction
    let model: AppModel
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let hostID = model.agents.hostID(for: action)
        let (host, known) = action.source == .bridge
            ? (action.destination, true)
            : AgentFormat.hostLabel(hostID, endpoint: action.endpoint, destination: action.destination, model: model)
        RowShell {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    AgentBadge(agent: action.agent)
                    Text(host).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    if !known { Chip(icon: "plus", text: "未保存") }
                    if action.source == .bridge { Chip(icon: "point.3.connected.trianglepath.dotted", text: "Bridge") }
                    Spacer(minLength: 2)
                    stateIcon
                    Text(AgentFormat.clock(action.start))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(action.source == .bridge ? "\(action.tool) · \(action.command)" : action.insight.headline)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? 6 : 1)
                    .truncationMode(.tail)
                    .padding(.leading, 26)
                if let note = action.note {
                    Text(note).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(expanded ? 4 : 1).padding(.leading, 26)
                }
                if expanded, let output = action.output {
                    ScrollView([.vertical, .horizontal]) {
                        Text(output)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.8))
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 170)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.canvasColor))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairlineColor))
                    .padding(.leading, 26)
                    .padding(.top, 3)
                }
            }
        }
        .onTapGesture(count: 2) { model.revisit(action) }
        .onTapGesture { toggle() }
        .help(action.output == nil ? "双击：去这台机器上看看" : "单击：展开输出 · 双击：去这台机器上看看")
        .contextMenu {
            if action.source != .bridge {
                if let t = action.insight.tmuxSessions.last {
                    Button("只读旁观 tmux「\(t)」") { model.revisit(action) }
                    Button("接管 tmux「\(t)」（可以输入）") { model.revisit(action, takeOver: true) }
                    Divider()
                }
                if let ep = action.endpoint {
                    Button(action.insight.directory.map { "在 \($0) 打开终端" } ?? "打开终端") {
                        model.openAgentTerminal(endpoint: ep, hostID: hostID, directory: action.insight.directory)
                    }
                    Button("浏览文件") { model.browseAgentFiles(endpoint: ep, hostID: hostID, directory: action.insight.directory) }
                    if hostID == nil {
                        Divider()
                        Button("导入为书签") { _ = model.hostForAgent(hostID: nil, endpoint: ep) }
                    }
                }
                Divider()
                Button("复制命令") { model.copyText(action.command, note: "已复制命令") }
                if let output = action.output { Button("复制输出") { model.copyText(output, note: "已复制输出") } }
            } else {
                Button("打开这台机器") { model.revisit(action) }
            }
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch action.state {
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(nsColor: Theme.online))
        case .failed(let code):
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark").font(.system(size: 9, weight: .bold))
                if let code { Text("\(code)").font(.system(size: 9.5, design: .monospaced)) }
            }
            .foregroundStyle(Color(nsColor: Theme.warning))
        case .denied:
            Image(systemName: "hand.raised.fill").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}
