import AppKit
import SwiftUI
import LiteMuxCore

struct SidebarView: View {
    let model: AppModel
    let titlebarHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                BarButton(systemName: "sidebar.left", help: "收起侧边栏 ⌘B") { model.toggleSidebar() }
            }
            .padding(.horizontal, 8)
            .frame(height: titlebarHeight)
            .background(WindowDragArea())

            SegmentedSwitch(options: [(SidebarMode.hosts, "主机"), (SidebarMode.files, "文件")],
                            selection: Binding(get: { model.sidebarMode }, set: { model.setSidebarMode($0) }))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            switch model.sidebarMode {
            case .hosts: HostsList(model: model)
            case .files: FileTreeView(model: model, browser: model.files)
            }
        }
        .background(ZStack { VisualEffectBackground(material: .sidebar); Theme.sidebarTintColor })
    }
}

// MARK: - Hosts

struct HostsList: View {
    let model: AppModel

    var body: some View {
        List(selection: Binding(get: { Optional(model.selectedHostID) }, set: { id in
            if let id { model.activate(hostID: id) }
        })) {
            Section("本机") {
                HostRow(host: .local, model: model).tag(HostEntry.localID)
            }
            Section {
                ForEach(model.bookmarkHosts) { h in
                    HostRow(host: h, model: model).tag(h.id)
                }
                Button {
                    model.presentNewConnection()
                } label: {
                    Label("粘贴 SSH 命令…", systemImage: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            } header: {
                Text("临时算力书签")
            }
            Section {
                if model.sshConfigHosts.isEmpty {
                    Text("~/.ssh/config 中没有具体主机")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                ForEach(model.sshConfigHosts) { h in
                    HostRow(host: h, model: model).tag(h.id)
                }
            } header: {
                HStack {
                    Text("~/.ssh/config")
                    Spacer()
                    Button {
                        model.reloadSSHConfig()
                        model.toast("已重新读取 ~/.ssh/config", style: .info)
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("重新读取")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

struct HostRow: View {
    let host: HostEntry
    let model: AppModel

    var body: some View {
        let online = model.isOnline(host.id)
        let panes = model.openPaneCount(for: host.id)
        HStack(spacing: 9) {
            StatusDot(online: online || (host.isLocal))
            VStack(alignment: .leading, spacing: 1) {
                Text(host.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if !host.subtitle.isEmpty {
                    Text(host.subtitle)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if panes > 0 {
                Text("\(panes)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if host.hasSavedPassword {
                Image(systemName: "key").font(.system(size: 9.5)).foregroundStyle(.tertiary).help("密码已保存在钥匙串")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu { HostMenu(host: host, model: model) }
    }
}

struct HostMenu: View {
    let host: HostEntry
    let model: AppModel

    var body: some View {
        Button("新终端标签页") { model.openTerminalTab(host: host) }
        Button("浏览文件") { model.browseFiles(host) }
        Divider()
        Toggle("自动挂载远端 tmux", isOn: Binding(get: { model.autoTmux(for: host.id) },
                                            set: { model.setAutoTmux($0, for: host.id) }))
        if host.endpoint != nil {
            Button("复制 SSH 命令") { model.copySSHCommand(host) }
        }
        if host.kind == .bookmark, let id = UUID(uuidString: String(host.id.dropFirst("bookmark:".count))) {
            Divider()
            Button("编辑书签…") { model.presentEdit(bookmarkID: id) }
            Button("删除书签…", role: .destructive) { model.deleteBookmark(id) }
        }
    }
}

// MARK: - Files

struct FileTreeView: View {
    let model: AppModel
    @Bindable var browser: FileBrowserModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairlineColor).frame(height: 1)
            content
            TransfersFooter(center: model.transfers)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                StatusDot(online: model.isOnline(browser.host?.id ?? ""))
                Text(browser.host?.title ?? "未选择主机")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                SmallIcon("arrow.up", "上级目录") { browser.goUp() }
                SmallIcon("house", "主目录") { browser.goHome() }
                SmallIcon("arrow.clockwise", "刷新") { browser.refresh() }
                SmallIcon(browser.showHidden ? "eye" : "eye.slash", browser.showHidden ? "隐藏点文件" : "显示点文件") {
                    browser.showHidden.toggle()
                }
                Menu {
                    Button("新建文件…") { browser.newFile(in: browser.rootPath) }
                    Button("新建文件夹…") { browser.newFolder(in: browser.rootPath) }
                    Divider()
                    Button("上传文件…") { browser.chooseAndUpload(to: browser.rootPath) }
                    Button("在此目录打开终端") { browser.openTerminal(at: browser.rootPath) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 11.5))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            TextField("路径", text: $browser.pathField)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.05)))
                .onSubmit { browser.submitPathField() }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        switch browser.status {
        case .waitingForAuth:
            Placeholder(icon: "lock", title: "等待终端完成认证",
                        detail: "这台主机需要在终端里输入密码或验证码。登录成功后文件树会自动接上同一条连接。") {
                if let h = browser.host {
                    Button("打开终端登录") { model.activate(hostID: h.id) }
                }
            }
        case .failed(let message):
            Placeholder(icon: "exclamationmark.triangle", title: "无法读取目录", detail: message) {
                Button("重试") { browser.refresh() }
            }
        case .idle where browser.host == nil:
            Placeholder(icon: "folder", title: "选择一台主机", detail: "文件树跟随当前激活的终端。") { EmptyView() }
        default:
            if browser.status == .loading && browser.rows.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var list: some View {
        List(selection: $browser.selection) {
            ForEach(browser.rows) { row in
                FileRow(row: row, browser: browser)
                    .tag(row.entry.path)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { paths in
            let entry = browser.rows.first { $0.entry.path == paths.first }?.entry
            FileMenu(entry: entry, browser: browser)
        } primaryAction: { paths in
            if let p = paths.first, let row = browser.rows.first(where: { $0.entry.path == p }) {
                browser.activate(row.entry)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            browser.upload(urls.filter(\.isFileURL), to: browser.rootPath)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct SmallIcon: View {
    let name: String
    let help: String
    let action: () -> Void
    init(_ name: String, _ help: String, action: @escaping () -> Void) {
        self.name = name
        self.help = help
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11)).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct FileRow: View {
    let row: FileBrowserModel.Row
    let browser: FileBrowserModel
    @State private var targeted = false

    var body: some View {
        let e = row.entry
        let isDir = e.behavesAsDirectory
        let open = browser.expanded.contains(e.path)
        HStack(spacing: 5) {
            Group {
                if isDir {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .onTapGesture { browser.toggle(e) }
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
            Image(systemName: FileIcon.symbol(for: e))
                .font(.system(size: 11.5))
                .foregroundStyle(isDir ? Theme.accentColor.opacity(0.85) : Color.secondary)
                .frame(width: 16)
            Text(e.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(e.isHidden ? 0.6 : 1)
            if e.kind == .symlink {
                Image(systemName: "arrow.turn.up.right").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if browser.loadingDirs.contains(e.path) {
                ProgressView().controlSize(.mini)
            } else if !isDir {
                Text(e.size.compactByteString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 4).fill(targeted ? Theme.accentColor.opacity(0.18) : .clear))
        .help(e.path)
        .modifier(DirectoryDrop(enabled: isDir, targeted: $targeted) { urls in
            browser.upload(urls, to: e.path)
        })
    }
}

private struct DirectoryDrop: ViewModifier {
    let enabled: Bool
    @Binding var targeted: Bool
    let onDrop: ([URL]) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: URL.self) { urls, _ in
                onDrop(urls.filter(\.isFileURL))
                return true
            } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}

struct FileMenu: View {
    let entry: FileEntry?
    let browser: FileBrowserModel

    var body: some View {
        let dir = browser.targetDirectory(for: entry)
        if let entry, !entry.behavesAsDirectory {
            Button("打开") { browser.activate(entry) }
            Button("下载到“下载”文件夹") { browser.download(entry) }
            Divider()
        }
        if let entry, entry.behavesAsDirectory {
            Button("进入此目录") { browser.enter(entry) }
        }
        Button("在此目录打开新终端") { browser.openTerminal(at: dir) }
        Divider()
        Button("新建文件…") { browser.newFile(in: dir) }
        Button("新建文件夹…") { browser.newFolder(in: dir) }
        Button("上传到此处…") { browser.chooseAndUpload(to: dir) }
        if let entry {
            Divider()
            Button("重命名…") { browser.rename(entry) }
            Button("复制路径") { browser.copyPath(entry) }
            Button("删除…", role: .destructive) { browser.delete(entry) }
        }
    }
}

private struct Placeholder<Actions: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions().controlSize(.small).padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum FileIcon {
    static func symbol(for e: FileEntry) -> String {
        if e.behavesAsDirectory { return "folder" }
        switch e.fileExtension {
        case "py", "sh", "bash", "zsh", "js", "ts", "swift", "c", "h", "cpp", "cu", "go", "rs", "java", "rb", "lua":
            return "chevron.left.forwardslash.chevron.right"
        case "yaml", "yml", "json", "toml", "ini", "cfg", "conf", "env": return "gearshape"
        case "md", "txt", "rst": return "doc.plaintext"
        case "log", "out", "err": return "text.alignleft"
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg": return "photo"
        case "pt", "pth", "ckpt", "safetensors", "onnx", "bin", "h5", "npy", "npz", "pkl": return "cube"
        case "zip", "gz", "tgz", "tar", "xz", "7z", "bz2": return "archivebox"
        case "csv", "tsv", "parquet": return "tablecells"
        case "pdf": return "doc.richtext"
        case "ipynb": return "book.closed"
        default: return "doc"
        }
    }
}

struct TransfersFooter: View {
    let center: TransferCenter

    var body: some View {
        let active = center.active
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(active.prefix(3)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Image(systemName: item.direction == .upload ? "arrow.up" : "arrow.down")
                                .font(.system(size: 9, weight: .bold))
                            Text(item.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(Int(item.fraction * 100))%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: item.fraction).progressViewStyle(.linear).controlSize(.mini)
                    }
                }
                if active.count > 3 {
                    Text("还有 \(active.count - 3) 项…").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .hairline(.top)
        }
    }
}
