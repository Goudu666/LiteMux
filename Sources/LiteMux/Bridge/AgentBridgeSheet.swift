import AppKit
import SwiftUI
import LiteMuxCore

/// "接入 Coding Agent": permission mode, copy-paste setup for each agent,
/// the tools on offer and what agents did recently.
struct AgentBridgeSheet: View {
    let model: AppModel
    @State private var mode = BridgeConfig.load().mode
    @State private var agent: AgentKind = .claudeCode
    @State private var copied = false
    @State private var activity: [BridgeActivity] = []

    enum AgentKind: String, CaseIterable, Hashable {
        case claudeCode, codex, antigravity

        var title: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            case .antigravity: return "Antigravity"
            }
        }

        var hint: String {
            switch self {
            case .claudeCode: return "在终端运行一次，之后每个项目里的 Claude Code 都能用："
            case .codex: return "加到 ~/.codex/config.toml（Codex CLI 和 IDE 插件共用）："
            case .antigravity: return "Agent 面板 ··· → MCP Servers → Manage → View raw config，加入："
            }
        }

        func snippet(executable: String) -> String {
            switch self {
            case .claudeCode:
                return "claude mcp add --scope user litemux -- \(ShellWords.quote(executable)) --mcp"
            case .codex:
                return "[mcp_servers.litemux]\ncommand = \"\(executable)\"\nargs = [\"--mcp\"]"
            case .antigravity:
                return "{\n  \"mcpServers\": {\n    \"litemux\": {\n      \"command\": \"\(executable)\",\n      \"args\": [\"--mcp\"]\n    }\n  }\n}"
            }
        }
    }

    static var executable: String {
        Bundle.main.executablePath ?? "/Applications/LiteMux.app/Contents/MacOS/LiteMux"
    }

    private static let tools: [BridgeTool] =
        BridgeToolbox(shell: ProcessBridgeShell(), directory: { BridgeHostDirectory(hosts: []) }).tools

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 18)
            section("权限") { permission }
            section("接入") { setup }
            section("Agent 能用的工具") { toolGrid }
            section("最近活动") { activityList }
            HStack {
                Text("LiteMux 不内置模型、不联网；Agent 由你自己选择和登录。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("完成") { model.showAgentBridge = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 580)
        .background(Theme.canvasColor)
        .task {
            while !Task.isCancelled {
                activity = BridgeActivityLog().recent(30)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accentColor.opacity(0.12))
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.accentColor)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text("接入 Coding Agent")
                    .font(.system(size: 15, weight: .semibold))
                Text("让本机的 Claude Code、Codex、Antigravity 通过 MCP 使用 LiteMux：读终端、看训练进度和 GPU，经你同意后执行命令。它们复用 LiteMux 已经打开的 SSH 连接。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .padding(.bottom, 18)
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 7) {
            SegmentedSwitch(options: BridgeMode.allCases.map { ($0, $0.title) }, selection: $mode)
                .frame(width: 330)
                .onChange(of: mode) { _, newValue in
                    try? BridgeConfig(mode: newValue).save()
                }
            Text(mode.explanation)
                .font(.system(size: 11.5))
                .foregroundStyle(mode == .trusted ? Color(nsColor: Theme.warning) : .secondary)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            SegmentedSwitch(options: AgentKind.allCases.map { ($0, $0.title) }, selection: $agent)
                .frame(width: 330)
            Text(agent.hint)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            let snippet = agent.snippet(executable: Self.executable)
            ZStack(alignment: .topTrailing) {
                Text(snippet)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .padding(.trailing, 60)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairlineColor))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .padding(7)
            }
            .onChange(of: agent) { _, _ in copied = false }
        }
    }

    private var toolGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(Self.tools, id: \.name) { tool in
                let gated = tool.access != .read
                let off = gated && mode == .readOnly
                HStack(spacing: 6) {
                    Image(systemName: icon(tool.name))
                        .font(.system(size: 11))
                        .frame(width: 14)
                        .foregroundStyle(gated ? Color(nsColor: Theme.warning) : Theme.accentColor)
                    Text(tool.title).font(.system(size: 11.5))
                    Spacer(minLength: 0)
                    if gated, mode == .confirm {
                        Image(systemName: "hand.raised").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                            .help("执行前会弹窗确认")
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.04)))
                .opacity(off ? 0.38 : 1)
                .help(tool.name)
            }
        }
    }

    private func icon(_ name: String) -> String {
        switch name {
        case "list_hosts": return "server.rack"
        case "read_terminal": return "terminal"
        case "training_status": return "chart.line.downtrend.xyaxis"
        case "gpu_status": return "cpu"
        case "list_directory": return "folder"
        case "read_file": return "doc.text"
        case "run_command": return "play"
        case "send_to_terminal": return "keyboard"
        case "write_file": return "square.and.pencil"
        default: return "wrench"
        }
    }

    @ViewBuilder
    private var activityList: some View {
        if activity.isEmpty {
            Text("还没有 Agent 调用过。接入后，在 Agent 里问一句「看看我服务器上的训练跑得怎么样」试试。")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(activity) { a in
                        ActivityRow(activity: a, title: Self.tools.first { $0.name == a.tool }?.title ?? a.tool)
                        if a.id != activity.last?.id { Divider().opacity(0.5) }
                    }
                }
            }
            .frame(height: min(168, CGFloat(activity.count) * 28 + 4))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.03)))
        }
    }
}

private struct ActivityRow: View {
    let activity: BridgeActivity
    let title: String

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 12)
            Text(Self.time.string(from: activity.time))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(activity.client)
                .font(.system(size: 11.5, weight: .medium))
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if let host = activity.host {
                Text(host).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Text(activity.summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private var symbol: String {
        switch activity.outcome {
        case .ok: return "checkmark"
        case .failed: return "exclamationmark"
        case .denied: return "hand.raised.fill"
        }
    }

    private var tint: Color {
        switch activity.outcome {
        case .ok: return Color(nsColor: Theme.online)
        case .failed: return Color(nsColor: Theme.warning)
        case .denied: return .secondary
        }
    }
}
