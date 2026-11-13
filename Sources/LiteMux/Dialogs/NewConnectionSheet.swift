import AppKit
import SwiftUI
import LiteMuxCore

/// "New / paste SSH connection". The paste field is focused first: dropping in
/// a command from a cloud console fills every field instantly.
struct NewConnectionSheet: View {
    let model: AppModel
    @State var draft: ConnectionDraft
    @FocusState private var pasteFocused: Bool
    @State private var parseFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.isEditing ? "编辑书签" : "新建连接")
                    .font(.system(size: 15, weight: .semibold))
                Text("粘贴云平台给出的整行 SSH 命令，会自动拆出主机、端口、用户和密钥。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 14)

            TextField("ssh -p 38192 root@connect.westb.seetacloud.com", text: $draft.pasted, axis: .vertical)
                .lineLimit(1...3)
                .font(.system(size: 12.5, design: .monospaced))
                .textFieldStyle(.plain)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(parseFailed ? Color(nsColor: .systemOrange).opacity(0.7)
                                  : (pasteFocused ? Theme.accentColor.opacity(0.6) : Theme.hairlineColor)))
                .focused($pasteFocused)
                .onChange(of: draft.pasted) { _, text in
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { parseFailed = false; return }
                    parseFailed = !draft.applyPaste()
                }
                .padding(.bottom, 16)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("名称")
                    TextField("", text: $draft.name,
                              prompt: Text(draft.suggestedName.isEmpty ? "autodl-westb-38192" : draft.suggestedName))
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    label("主机")
                    HStack(spacing: 8) {
                        TextField("", text: $draft.host, prompt: Text("hostname 或 IP"))
                            .textFieldStyle(.roundedBorder)
                        Text("端口").font(.system(size: 12)).foregroundStyle(.secondary)
                        TextField("", text: $draft.port, prompt: Text("22"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                }
                GridRow {
                    label("用户")
                    TextField("", text: $draft.user, prompt: Text("root")).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    label("密钥")
                    HStack(spacing: 8) {
                        TextField("", text: $draft.identityFile, prompt: Text("可选，例如 ~/.ssh/id_ed25519"))
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { chooseKey() }.controlSize(.small)
                    }
                }
                GridRow {
                    label("密码")
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField("", text: $draft.password,
                                    prompt: Text(draft.hasSavedPassword ? "已保存在钥匙串（留空保持不变）" : "可选，保存到 macOS 钥匙串"))
                            .textFieldStyle(.roundedBorder)
                        if draft.hasSavedPassword {
                            Toggle("清除已保存的密码", isOn: $draft.clearPassword)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11.5))
                        }
                    }
                }
                GridRow {
                    label("")
                    Toggle("自动挂载远端 tmux（每个窗格独立 lm_<槽位> 会话，断线不中断任务）", isOn: $draft.autoTmux)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }
            }

            if let ep = draft.endpoint {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.system(size: 10.5))
                    Text(ep.commandLine).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 14)
            }

            HStack {
                Text("密码只写入钥匙串，不会出现在任何配置文件或命令行参数中。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { model.connectionSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { model.commit(draft, connect: false) }
                    .disabled(!draft.isValid)
                Button("保存并连接") { model.commit(draft, connect: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
            .padding(.top, 20)
        }
        .padding(22)
        .frame(width: 540)
        .onAppear { if !draft.isEditing { pasteFocused = true } }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "选择密钥"
        if panel.runModal() == .OK, let url = panel.url {
            draft.identityFile = ShellWords.abbreviateHome(url.path)
        }
    }
}
