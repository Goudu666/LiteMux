import AppKit
import Observation
import LiteMuxCore

/// The file tree for the active host: a root directory plus lazily loaded,
/// expandable children. Errors never block the UI; a host that has not yet
/// authenticated just shows a hint until its terminal finishes logging in.
@MainActor @Observable
final class FileBrowserModel {
    enum Status: Equatable {
        case idle
        case loading
        case ready
        case waitingForAuth
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        var entry: FileEntry
        var depth: Int
        var id: String { entry.path }
    }

    private(set) var host: HostEntry?
    private(set) var rootPath: String = ""
    private(set) var status: Status = .idle
    var pathField: String = ""
    var showHidden: Bool {
        didSet { onPreferenceChange?() }
    }
    private(set) var children: [String: [FileEntry]] = [:]
    private(set) var expanded: Set<String> = []
    private(set) var loadingDirs: Set<String> = []
    var selection: String?

    @ObservationIgnored var homePath: String?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored var onPreferenceChange: (() -> Void)?
    @ObservationIgnored private var generation = 0

    init(showHidden: Bool) {
        self.showHidden = showHidden
    }

    /// Flattened visible rows for the outline.
    var rows: [Row] {
        var out: [Row] = []
        func walk(_ dir: String, depth: Int) {
            for e in children[dir] ?? [] where showHidden || !e.isHidden {
                out.append(Row(entry: e, depth: depth))
                if e.behavesAsDirectory && expanded.contains(e.path) { walk(e.path, depth: depth + 1) }
            }
        }
        walk(rootPath, depth: 0)
        return out
    }

    func follow(_ newHost: HostEntry?) {
        guard newHost?.id != host?.id else { return }
        host = newHost
        children = [:]
        expanded = []
        homePath = nil
        selection = nil
        rootPath = ""
        pathField = ""
        status = .idle
        guard let newHost else { return }
        let last = app?.state.lastDirectories[newHost.id]
        Task { await self.open(last ?? "~") }
    }

    func retryIfWaiting(_ hostID: String) {
        guard hostID == host?.id else { return }
        switch status {
        case .waitingForAuth, .failed, .idle:
            Task { await self.open(rootPath.isEmpty ? (app?.state.lastDirectories[hostID] ?? "~") : rootPath) }
        default: break
        }
    }

    private func fileSystem() async throws -> FileSystemProvider {
        guard let host, let app else { throw CocoaError(.featureUnsupported) }
        return try await app.hub.fileSystem(for: host)
    }

    /// Makes `path` the root of the tree.
    func open(_ path: String) async {
        guard let host else { return }
        generation += 1
        let gen = generation
        status = .loading
        do {
            let fs = try await fileSystem()
            if homePath == nil { homePath = try? await fs.homeDirectory() }
            let resolved = try await fs.resolve(path.isEmpty ? "~" : path)
            let entries = try await fs.list(resolved)
            guard gen == generation, host.id == self.host?.id else { return }
            rootPath = resolved
            pathField = displayPath(resolved)
            children = [resolved: entries]
            expanded = []
            status = .ready
            app?.rememberDirectory(resolved, for: host.id)
        } catch {
            guard gen == generation else { return }
            if let e = error as? SFTPError, e.needsInteractiveAuth {
                status = .waitingForAuth
            } else if rootPath.isEmpty, path != "~" {
                // A remembered directory may have vanished; fall back to home.
                await open("~")
            } else {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func displayPath(_ path: String) -> String {
        if let home = homePath { return ShellWords.abbreviateHome(path, home: home) }
        return path
    }

    func submitPathField() { Task { await open(pathField) } }
    func goUp() { Task { await open(RemotePath.parent(rootPath)) } }
    func goHome() { Task { await open("~") } }
    func refresh() {
        let dirs = [rootPath] + Array(expanded)
        Task {
            for d in dirs { await self.reload(d) }
            if self.status != .ready { await self.open(self.rootPath.isEmpty ? "~" : self.rootPath) }
        }
    }

    func toggle(_ entry: FileEntry) {
        guard entry.behavesAsDirectory else { return }
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
        } else {
            expanded.insert(entry.path)
            if children[entry.path] == nil { Task { await reload(entry.path) } }
        }
    }

    func reload(_ dir: String) async {
        guard !dir.isEmpty else { return }
        loadingDirs.insert(dir)
        defer { loadingDirs.remove(dir) }
        do {
            let fs = try await fileSystem()
            children[dir] = try await fs.list(dir)
            if dir == rootPath { status = .ready }
        } catch {
            if dir == rootPath {
                if let e = error as? SFTPError, e.needsInteractiveAuth { status = .waitingForAuth }
                else { status = .failed(error.localizedDescription) }
            } else {
                children[dir] = []
                app?.toast(error.localizedDescription, style: .error)
            }
        }
    }

    // MARK: Actions

    func activate(_ entry: FileEntry) {
        if entry.behavesAsDirectory {
            toggle(entry)
        } else if let host {
            app?.openEditor(host: host, path: entry.path, size: entry.size)
        }
    }

    func enter(_ entry: FileEntry) {
        guard entry.behavesAsDirectory else { return activate(entry) }
        Task { await open(entry.path) }
    }

    /// The directory an action on `entry` applies to.
    func targetDirectory(for entry: FileEntry?) -> String {
        guard let entry else { return rootPath }
        return entry.behavesAsDirectory ? entry.path : RemotePath.parent(entry.path)
    }

    func newFile(in dir: String) {
        guard let name = Prompt.text(title: "新建文件", message: "在 \(displayPath(dir)) 中创建", placeholder: "untitled.txt") else { return }
        run("已创建 \(name)") { fs in try await fs.createFile(RemotePath.join(dir, name)) } after: { await self.reloadAndExpand(dir) }
    }

    func newFolder(in dir: String) {
        guard let name = Prompt.text(title: "新建文件夹", message: "在 \(displayPath(dir)) 中创建", placeholder: "new-folder") else { return }
        run("已创建 \(name)/") { fs in try await fs.createDirectory(RemotePath.join(dir, name)) } after: { await self.reloadAndExpand(dir) }
    }

    func rename(_ entry: FileEntry) {
        guard let name = Prompt.text(title: "重命名", message: entry.name, placeholder: entry.name, initial: entry.name),
              name != entry.name else { return }
        let parent = RemotePath.parent(entry.path)
        run(nil) { fs in try await fs.rename(entry.path, to: RemotePath.join(parent, name)) } after: { await self.reload(parent) }
    }

    func delete(_ entry: FileEntry) {
        let isLocal = host?.isLocal ?? false
        let what = entry.behavesAsDirectory && entry.kind == .directory ? "文件夹「\(entry.name)」及其中所有内容" : "「\(entry.name)」"
        let detail = isLocal ? "项目会被移到废纸篓。" : "远程删除无法撤销。"
        guard Prompt.confirm(title: "删除\(what)？", message: "\(displayPath(entry.path))\n\(detail)",
                             confirm: isLocal ? "移到废纸篓" : "删除", destructive: true) else { return }
        let parent = RemotePath.parent(entry.path)
        run("已删除 \(entry.name)") { fs in try await fs.removeRecursively(entry.path) } after: {
            self.expanded.remove(entry.path)
            await self.reload(parent)
        }
    }

    func download(_ entry: FileEntry) {
        guard let host else { return }
        app?.transfers.download(entry, from: host)
    }

    func upload(_ urls: [URL], to dir: String) {
        guard let host, !urls.isEmpty else { return }
        app?.transfers.upload(urls, to: dir, on: host) { [weak self] in
            await self?.reloadAndExpand(dir)
        }
    }

    func chooseAndUpload(to dir: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "上传"
        panel.message = "上传到 \(displayPath(dir))"
        guard panel.runModal() == .OK else { return }
        upload(panel.urls, to: dir)
    }

    func openTerminal(at dir: String) {
        guard let host else { return }
        app?.openTerminalTab(host: host, directory: dir)
    }

    func copyPath(_ entry: FileEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.path, forType: .string)
        app?.toast("已复制路径", style: .info)
    }

    private func reloadAndExpand(_ dir: String) async {
        if dir != rootPath { expanded.insert(dir) }
        await reload(dir)
    }

    private func run(_ success: String?, _ op: @escaping (FileSystemProvider) async throws -> Void,
                     after: @escaping () async -> Void) {
        Task {
            do {
                let fs = try await fileSystem()
                try await op(fs)
                await after()
                if let success { app?.toast(success, style: .info) }
            } catch {
                app?.toast(error.localizedDescription, style: .error)
            }
        }
    }
}
