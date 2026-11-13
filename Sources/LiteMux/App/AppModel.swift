import AppKit
import Observation
import LiteMuxCore

enum SidebarMode: String { case hosts, files }

struct Toast: Identifiable, Equatable {
    enum Style { case info, success, error }
    let id = UUID()
    var text: String
    var style: Style
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// Application state and every command the menus, shortcuts and views call.
@MainActor @Observable
final class AppModel {
    // Persisted preferences and bookmarks.
    var state: PersistedState

    // Hosts.
    private(set) var configHosts: [SSHConfigHost] = []
    var selectedHostID: String = HostEntry.localID

    // Workspace.
    var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?

    // Sidebar & sheets.
    var sidebarMode: SidebarMode
    var sidebarVisible: Bool
    var sidebarWidth: Double
    var connectionSheet: ConnectionDraft?
    var toastItem: Toast?
    var showPulsePanel = false
    var showAgentBridge = false
    var showHostTools = false

    // Services.
    let hub = ConnectionHub()
    let files: FileBrowserModel
    let monitor: StatusMonitor
    let transfers = TransferCenter()
    let hostTools = HostTools()
    let gpuWatch = GPUIdleWatch()

    @ObservationIgnored private var sessions: [UUID: TerminalSession] = [:]
    @ObservationIgnored private let store = StateStore()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored weak var window: NSWindow?

    init() {
        let loaded = store.load()
        state = loaded
        sidebarMode = SidebarMode(rawValue: loaded.sidebarMode) ?? .hosts
        sidebarVisible = loaded.sidebarVisible
        sidebarWidth = min(420, max(180, loaded.sidebarWidth))
        files = FileBrowserModel(showHidden: loaded.showHiddenFiles)
        monitor = StatusMonitor(hub: hub)
        files.app = self
        transfers.app = self
        hostTools.app = self
        monitor.onSample = { [weak self] host, sample in self?.gpuWatch.observe(sample, host: host) }
        observeBridge()
        files.onPreferenceChange = { [weak self] in
            guard let self else { return }
            self.state.showHiddenFiles = self.files.showHidden
            self.scheduleSave()
        }
        hub.onHostOnline = { [weak self] hostID in
            self?.files.retryIfWaiting(hostID)
            self?.monitor.retryIfWaiting(hostID)
        }
        reloadSSHConfig()
        restoreTabs()
        ThemeStore.shared.current = state.colorTheme
        if ProcessInfo.processInfo.environment["LITEMUX_SMOKE_PULSE"] == "1" {
            // CI screenshot of the Training Pulse panel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in self?.showPulsePanel = true }
        }
        if ProcessInfo.processInfo.environment["LITEMUX_SMOKE_HOSTTOOLS"] == "1" {
            // CI screenshot of the tunnels / tmux sessions popover.
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in self?.showHostTools = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, let h = self.activeHost, !h.isLocal else { return }
                Task {
                    let f = await self.hostTools.forward(6006, on: h, open: false)
                    FileHandle.standardError.write(Data("smoke: forward \(f?.localPort ?? -1)\n".utf8))
                }
            }
        }
        if ProcessInfo.processInfo.environment["LITEMUX_SMOKE_AGENTS"] == "1" {
            // CI screenshot of the "接入 Coding Agent" sheet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.showAgentBridge = true }
        }
        if let spec = ProcessInfo.processInfo.environment["LITEMUX_SMOKE_PREVIEW"] {
            // CI screenshot of the mask preview: "<hostID>|<path>".
            let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, parts.count == 2, let h = self.host(parts[0]) else { return }
                self.previewImage(host: h, path: parts[1], size: 0)
            }
        }
        applyAppearance()
        activeHostChanged()
    }

    // MARK: - Hosts

    var bookmarkHosts: [HostEntry] { state.bookmarks.map { HostEntry.from($0) } }
    var sshConfigHosts: [HostEntry] { configHosts.map { HostEntry.from($0) } }

    func host(_ id: String) -> HostEntry? {
        if id == HostEntry.localID { return .local }
        if let b = state.bookmarks.first(where: { $0.hostID == id }) { return HostEntry.from(b) }
        if id.hasPrefix("config:") {
            let alias = String(id.dropFirst("config:".count))
            if let h = configHosts.first(where: { $0.alias == alias }) { return HostEntry.from(h) }
        }
        return nil
    }

    func reloadSSHConfig() {
        configHosts = SSHConfigParser().parseUserConfig()
    }

    func isOnline(_ hostID: String) -> Bool { hub.onlineHosts.contains(hostID) }

    func openPaneCount(for hostID: String) -> Int {
        var count = 0
        for tab in tabs {
            for pane in tab.root?.leaves ?? [] where pane.hostID == hostID { count += 1 }
        }
        return count
    }

    func autoTmux(for hostID: String) -> Bool { state.autoTmuxEnabled(for: hostID) }

    func setAutoTmux(_ on: Bool, for hostID: String) {
        state.autoTmux[hostID] = on
        scheduleSave()
    }

    /// Sidebar click: focus an existing terminal on that host, else open one.
    func activate(hostID: String) {
        selectedHostID = hostID
        let existing = tabs.first { tab in
            (tab.root?.leaves ?? []).contains { pane in pane.hostID == hostID }
        }
        if let tab = existing {
            selectTab(tab.id)
            if let pane = tab.root?.leaves.first(where: { $0.hostID == hostID }) { focus(pane: pane.id, in: tab) }
        } else if let host = host(hostID) {
            openTerminalTab(host: host)
        }
    }

    // MARK: - Active host (drives the file tree and status bar)

    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }

    var activeHostID: String { selectedTab?.hostID ?? selectedHostID }

    var activeHost: HostEntry? { host(activeHostID) ?? .local }

    private func activeHostChanged() {
        let h = activeHost
        if let h { selectedHostID = h.id }
        files.follow(h)
        monitor.follow(h)
    }

    // MARK: - Tabs & panes

    func session(for pane: PaneSpec) -> TerminalSession? {
        if let s = sessions[pane.id] { return s }
        guard let host = host(pane.hostID) else { return nil }
        let s = TerminalSession(pane: pane, host: host, usesTmux: pane.session != nil || (autoTmux(for: host.id) && pane.slot != nil),
                                fontSize: CGFloat(state.fontSize), useMetal: state.useMetalRenderer, hub: hub)
        s.onFocus = { [weak self] id in self?.paneDidFocus(id) }
        s.training.onEvent = { [weak self, weak s] event, run in
            guard let self, let s else { return }
            self.trainingEvent(event, run: run, in: s)
        }
        sessions[pane.id] = s
        return s
    }

    // MARK: - Training Pulse

    /// Curves for the focused terminal pane, shown in the status bar.
    var focusedTraining: PaneTraining? {
        guard let tab = selectedTab, tab.editor == nil, let pane = tab.focusedPane else { return nil }
        return session(for: pane)?.training
    }

    private func trainingEvent(_ event: TrainingEvent, run: TrainingRun, in session: TerminalSession) {
        let visible = selectedTab?.root?.contains(pane: session.pane.id) == true
        TrainingNotifier.post(event, run: run, where: session.displayTitle, paneVisible: visible) { [weak self] text, style in
            self?.toast(text, style: style)
        }
    }

    private func usedSlots(for hostID: String) -> Set<Int> {
        Set(tabs.flatMap { $0.root?.leaves ?? [] }.filter { $0.hostID == hostID }.compactMap(\.slot))
    }

    private func newPane(host: HostEntry, directory: String? = nil) -> PaneSpec {
        PaneSpec(hostID: host.id, slot: SlotAllocator.nextSlot(used: usedSlots(for: host.id)), directory: directory)
    }

    // MARK: - tmux sessions

    private func pane(showing session: String, hostID: String) -> (WorkspaceTab, PaneSpec)? {
        for tab in tabs {
            if let p = tab.root?.leaves.first(where: { $0.hostID == hostID && $0.tmuxSession == session }) { return (tab, p) }
        }
        return nil
    }

    func isTmuxSessionOpen(_ session: String, hostID: String) -> Bool { pane(showing: session, hostID: hostID) != nil }

    /// Shows a tmux session in a tab of its own: `lm_<n>` as a LiteMux pane,
    /// anything else (`train`, `bot`) attached directly, never nested.
    func openTmuxSession(_ session: String, host: HostEntry, select: Bool) {
        if let (tab, p) = pane(showing: session, hostID: host.id) {
            if select {
                selectTab(tab.id)
                tab.focusedPaneID = p.id
                focusSoon(p.id)
            }
            return
        }
        let pane: PaneSpec
        if session.hasPrefix("lm_"), let n = Int(session.dropFirst(3)), !usedSlots(for: host.id).contains(n) {
            pane = PaneSpec(hostID: host.id, slot: n)
        } else {
            pane = PaneSpec(hostID: host.id, slot: nil, session: session)
        }
        let tab = WorkspaceTab(root: .leaf(pane))
        if let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: idx + 1)
        } else {
            tabs.append(tab)
        }
        if select {
            selectTab(tab.id)
            focusSoon(pane.id)
        }
        scheduleSave()
    }

    /// `send_to_terminal` with session "new" opened a pane on the server: show it.
    private func observeBridge() {
        DistributedNotificationCenter.default().addObserver(forName: BridgeNotice.newSession, object: nil, queue: .main) { [weak self] note in
            let hostID = note.userInfo?["host"] as? String
            let session = note.userInfo?["session"] as? String
            MainActor.assumeIsolated {
                guard let model = self, let hostID, let session, let host = model.host(hostID) else { return }
                model.openTmuxSession(session, host: host, select: false)
                model.toast("Coding Agent 在 \(host.title) 开了新窗格 \(session)", style: .info, action: ("查看", { [weak model] in
                    model?.openTmuxSession(session, host: host, select: true)
                }))
            }
        }
    }

    func openTerminalTab(host: HostEntry, directory: String? = nil) {
        let pane = newPane(host: host, directory: directory)
        let tab = WorkspaceTab(root: .leaf(pane))
        if let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: idx + 1)
        } else {
            tabs.append(tab)
        }
        selectTab(tab.id)
        focusSoon(pane.id)
        scheduleSave()
    }

    func newTerminalTab() {
        openTerminalTab(host: activeHost ?? .local)
    }

    func selectTab(_ id: UUID) {
        guard selectedTabID != id else { return }
        selectedTabID = id
        activeHostChanged()
        if let tab = selectedTab, let pane = tab.focusedPane { focusSoon(pane.id) }
        scheduleSave()
    }

    func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let idx = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        let next = (idx + offset + tabs.count) % tabs.count
        selectTab(tabs[next].id)
    }

    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let idx = number >= 9 ? tabs.count - 1 : min(number - 1, tabs.count - 1)
        selectTab(tabs[idx].id)
    }

    func split(_ axis: SplitAxis) {
        guard let tab = selectedTab, let root = tab.root, let focused = tab.focusedPane,
              let host = host(focused.hostID) else {
            newTerminalTab()
            return
        }
        let pane = newPane(host: host)
        tab.root = root.splitting(pane: focused.id, axis: axis, with: pane)
        tab.focusedPaneID = pane.id
        focusSoon(pane.id)
        scheduleSave()
    }

    func equalizeSplits() {
        guard let tab = selectedTab, let root = tab.root else { return }
        tab.root = root.equalized
        scheduleSave()
    }

    func setRatio(_ ratio: Double, split: UUID, in tab: WorkspaceTab) {
        tab.root = tab.root?.settingRatio(ratio, forSplit: split)
        scheduleSave()
    }

    /// Cmd+W: closes the focused split, or the editor tab. Never the window.
    func closeFocused() {
        guard let tab = selectedTab else { return }
        if tab.editor != nil {
            closeTab(tab.id)
            return
        }
        guard let pane = tab.focusedPane else { closeTab(tab.id); return }
        closePane(pane.id, in: tab)
    }

    func closePane(_ id: UUID, in tab: WorkspaceTab) {
        sessions.removeValue(forKey: id)?.terminate()
        guard let remaining = tab.root?.removing(pane: id) else {
            removeTab(tab)
            return
        }
        tab.root = remaining
        if tab.focusedPaneID == id || remaining.pane(tab.focusedPaneID ?? UUID()) == nil {
            tab.focusedPaneID = remaining.leaves.last?.id
        }
        if let next = tab.focusedPaneID { focusSoon(next) }
        activeHostChanged()
        scheduleSave()
    }

    func closeTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if let doc = tab.editor, doc.isDirty {
            selectTab(id)
            switch Prompt.unsavedChanges(fileName: doc.fileName) {
            case .cancel: return
            case .discard: break
            case .save:
                Task {
                    if await self.save(doc) { self.removeTab(tab) }
                }
                return
            }
        }
        for pane in tab.root?.leaves ?? [] { sessions.removeValue(forKey: pane.id)?.terminate() }
        removeTab(tab)
    }

    private func removeTab(_ tab: WorkspaceTab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: idx)
        if selectedTabID == tab.id {
            selectedTabID = tabs.isEmpty ? nil : tabs[max(0, idx - 1)].id
            if let t = selectedTab, let p = t.focusedPane { focusSoon(p.id) }
        }
        activeHostChanged()
        scheduleSave()
    }

    private func paneDidFocus(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.root?.contains(pane: id) == true }) else { return }
        let changed = tab.focusedPaneID != id || selectedTabID != tab.id
        tab.focusedPaneID = id
        if selectedTabID != tab.id { selectedTabID = tab.id }
        if changed { activeHostChanged() }
    }

    func focus(pane id: UUID, in tab: WorkspaceTab) {
        tab.focusedPaneID = id
        focusSoon(id)
        activeHostChanged()
    }

    /// Gives keyboard focus to a pane once SwiftUI has placed its view.
    func focusSoon(_ id: UUID) {
        Task { @MainActor in
            for _ in 0..<10 {
                if let v = self.sessions[id]?.view, let w = v.window {
                    w.makeFirstResponder(v)
                    return
                }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    func tabTitle(_ tab: WorkspaceTab) -> String {
        if let doc = tab.editor { return doc.fileName }
        guard let pane = tab.focusedPane else { return "终端" }
        guard let h = host(pane.hostID) else { return "终端" }
        if let named = pane.session { return "\(h.title) · \(named)" }
        if !h.isLocal, autoTmux(for: h.id), let slot = pane.slot {
            return "\(h.title) · \(SSHInvocation.sessionName(slot: slot))"
        }
        return h.title
    }

    // MARK: - Editor

    func openEditor(host: HostEntry, path: String, size: UInt64) {
        if let existing = tabs.first(where: { $0.editor?.hostID == host.id && $0.editor?.path == path }) {
            selectTab(existing.id)
            return
        }
        let name = RemotePath.lastComponent(path)
        let ext = (name as NSString).pathExtension.lowercased()
        Task {
            do {
                let fs = try await hub.fileSystem(for: host)
                let realSize = (try? await fs.size(of: path)) ?? size
                if case .tooLarge(let s)? = TextFileGate.check(size: realSize) {
                    offerDownload(host: host, path: path, size: s,
                                  title: "「\(name)」太大，无法在编辑器中打开",
                                  message: "文件大小 \(s.compactByteString)，超过 5 MB 的编辑上限。可以下载后用本地工具查看。")
                    return
                }
                let head = try await fs.readHead(path, length: TextFileGate.sniffLength)
                if TextFileGate.check(head: head) == .binary || TextFileGate.knownBinaryExtensions.contains(ext) {
                    offerDownload(host: host, path: path, size: realSize,
                                  title: "「\(name)」看起来是二进制文件",
                                  message: "它包含空字节（如模型权重、压缩包或图片），不适合用文本编辑器打开。")
                    return
                }
                let data = try await fs.readFile(path)
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                    toast("无法以文本方式解码「\(name)」", style: .error)
                    return
                }
                let doc = EditorDocument(hostID: host.id, path: path, text: text)
                doc.stamp = try? await fs.stamp(of: path)
                let tab = WorkspaceTab(editor: doc)
                if let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) {
                    tabs.insert(tab, at: idx + 1)
                } else {
                    tabs.append(tab)
                }
                selectTab(tab.id)
            } catch {
                toast("打开失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    /// Images (and segmentation masks) open in a Quick Look style window.
    func previewImage(host: HostEntry, path: String, size: UInt64) {
        let name = RemotePath.lastComponent(path)
        Task {
            do {
                let fs = try await hub.fileSystem(for: host)
                let realSize = (try? await fs.size(of: path)) ?? size
                if case .tooLarge(let s)? = TextFileGate.check(size: realSize) {
                    offerDownload(host: host, path: path, size: s, title: "「\(name)」太大，无法直接预览",
                                  message: "文件大小 \(s.compactByteString)，超过 5 MB 的预览上限。可以下载后用本地工具查看。")
                    return
                }
                let data = try await fs.readFile(path)
                let place = host.isLocal ? path : "\(host.title):\(path)"
                let image = await Task.detached(priority: .userInitiated) {
                    PreviewImage.decode(data, name: name, place: place)
                }.value
                guard let image else {
                    toast("无法解码图片「\(name)」", style: .error)
                    return
                }
                ImagePreviewWindows.show(image)
            } catch {
                toast("预览失败：\(error.localizedDescription)", style: .error)
            }
        }
    }

    private func offerDownload(host: HostEntry, path: String, size: UInt64, title: String, message: String) {
        guard Prompt.offerDownload(title: title, message: message) else { return }
        let entry = FileEntry(name: RemotePath.lastComponent(path), path: path, kind: .file, size: size)
        transfers.download(entry, from: host)
    }

    var activeEditor: EditorDocument? { selectedTab?.editor }

    func saveActiveEditor() {
        guard let doc = activeEditor else { return }
        Task { _ = await save(doc) }
    }

    @discardableResult
    func save(_ doc: EditorDocument) async -> Bool {
        guard let host = host(doc.hostID), !doc.isSaving else { return false }
        doc.isSaving = true
        defer { doc.isSaving = false }
        let snapshot = doc.text
        do {
            let fs = try await hub.fileSystem(for: host)
            if let known = doc.stamp, let current = try? await fs.stamp(of: doc.path), current != known {
                var detail = ""
                if let m = current.modified {
                    let f = DateFormatter()
                    f.dateFormat = Calendar.current.isDateInToday(m) ? "HH:mm:ss" : "M月d日 HH:mm"
                    detail = "（\(f.string(from: m))"
                    if let a = known.size, let b = current.size, a != b { detail += "，\(a.compactByteString) → \(b.compactByteString)" }
                    detail += "）"
                }
                switch Prompt.saveConflict(fileName: doc.fileName, detail: detail) {
                case .cancel:
                    return false
                case .reload:
                    let data = try await fs.readFile(doc.path)
                    doc.replaceText(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
                    doc.stamp = current
                    doc.lastError = nil
                    toast("已重新加载 \(doc.fileName)", style: .info)
                    return false
                case .overwrite:
                    break
                }
            }
            try await fs.writeFile(doc.path, data: Data(snapshot.utf8))
            doc.stamp = try? await fs.stamp(of: doc.path)
            if doc.text == snapshot { doc.markSaved() }
            doc.lastError = nil
            toast("已保存 \(doc.fileName)", style: .success)
            return true
        } catch {
            doc.lastError = error.localizedDescription
            toast("保存失败：\(error.localizedDescription)", style: .error)
            return false
        }
    }

    // MARK: - Bookmarks

    func presentNewConnection() {
        connectionSheet = ConnectionDraft()
    }

    func presentEdit(bookmarkID: UUID) {
        guard let b = state.bookmarks.first(where: { $0.id == bookmarkID }) else { return }
        connectionSheet = ConnectionDraft(editing: b, autoTmux: autoTmux(for: b.hostID))
    }

    func commit(_ draft: ConnectionDraft, connect: Bool) {
        guard let endpoint = draft.endpoint else { return }
        var bookmark = state.bookmarks.first { $0.id == draft.editingID } ?? Bookmark(name: draft.displayName, endpoint: endpoint)
        bookmark.name = draft.displayName
        bookmark.endpoint = endpoint
        if !draft.password.isEmpty {
            do {
                try Keychain.setPassword(draft.password, account: bookmark.hostID)
                bookmark.hasSavedPassword = true
            } catch {
                toast(error.localizedDescription, style: .error)
            }
        } else if draft.clearPassword {
            Keychain.deletePassword(account: bookmark.hostID)
            bookmark.hasSavedPassword = false
        }
        if let idx = state.bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            state.bookmarks[idx] = bookmark
            hub.evict(bookmark.hostID)
        } else {
            state.bookmarks.append(bookmark)
        }
        state.autoTmux[bookmark.hostID] = draft.autoTmux
        connectionSheet = nil
        scheduleSave()
        if connect { openTerminalTab(host: HostEntry.from(bookmark)) }
    }

    func deleteBookmark(_ id: UUID) {
        guard let b = state.bookmarks.first(where: { $0.id == id }) else { return }
        guard Prompt.confirm(title: "删除书签「\(b.name)」？",
                             message: "会同时清除钥匙串中保存的密码。远端服务器不受影响。",
                             confirm: "删除", destructive: true) else { return }
        Keychain.deletePassword(account: b.hostID)
        for tab in tabs {
            for pane in tab.root?.leaves ?? [] where pane.hostID == b.hostID { closePane(pane.id, in: tab) }
            if tab.editor?.hostID == b.hostID { closeTab(tab.id) }
        }
        hub.evict(b.hostID)
        state.bookmarks.removeAll { $0.id == id }
        state.autoTmux.removeValue(forKey: b.hostID)
        if selectedHostID == b.hostID { selectedHostID = HostEntry.localID; activeHostChanged() }
        scheduleSave()
    }

    func copySSHCommand(_ host: HostEntry) {
        guard let ep = host.endpoint else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ep.commandLine, forType: .string)
        toast("已复制 \(ep.commandLine)", style: .info)
    }

    func browseFiles(_ host: HostEntry) {
        selectedHostID = host.id
        sidebarMode = .files
        sidebarVisible = true
        files.follow(host)
        monitor.follow(host)
    }

    func rememberDirectory(_ path: String, for hostID: String) {
        state.lastDirectories[hostID] = path
        scheduleSave()
    }

    // MARK: - Appearance & layout

    func setColorTheme(_ t: PersistedState.ColorTheme) {
        guard t != state.colorTheme else { return }
        state.colorTheme = t
        ThemeStore.shared.current = t
        // SwiftUI follows the store; AppKit surfaces need a nudge.
        window?.backgroundColor = Theme.canvas
        for s in sessions.values { s.view.applyLiteMuxTheme(); s.view.needsDisplay = true }
        if let root = window?.contentView { Self.redraw(root) }
        scheduleSave()
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        for sub in view.subviews { redraw(sub) }
    }

    func setAppearance(_ a: PersistedState.Appearance) {
        state.appearance = a
        applyAppearance()
        scheduleSave()
    }

    func applyAppearance() {
        switch state.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func adjustFontSize(_ delta: Double) {
        state.fontSize = delta == 0 ? 13 : min(28, max(9, state.fontSize + delta))
        for s in sessions.values { s.applyFontSize(CGFloat(state.fontSize)) }
        scheduleSave()
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
        scheduleSave()
    }

    func setSidebarWidth(_ w: Double) {
        sidebarWidth = min(420, max(180, w))
        scheduleSave()
    }

    func setSidebarMode(_ mode: SidebarMode) {
        sidebarMode = mode
        if !sidebarVisible { sidebarVisible = true }
        scheduleSave()
    }

    // MARK: - Toasts

    func toast(_ text: String, style: Toast.Style, action: (String, () -> Void)? = nil) {
        toastItem = Toast(text: text, style: style, actionTitle: action?.0, action: action?.1)
        toastTask?.cancel()
        let seconds: UInt64 = action == nil ? (style == .error ? 5 : 2) : 6
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if !Task.isCancelled { self?.toastItem = nil }
        }
    }

    // MARK: - Persistence

    private func restoreTabs() {
        for snap in state.tabs {
            guard case .terminal(let root) = snap.kind else { continue }
            // Drop panes whose host has disappeared (deleted bookmark, edited config).
            var tree: SplitNode? = root
            for pane in root.leaves where host(pane.hostID) == nil { tree = tree?.removing(pane: pane.id) }
            if let tree { tabs.append(WorkspaceTab(id: snap.id, root: tree)) }
        }
        if let i = state.selectedTabIndex, tabs.indices.contains(i) {
            selectedTabID = tabs[i].id
        } else {
            selectedTabID = tabs.first?.id
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        state.sidebarMode = sidebarMode.rawValue
        state.sidebarVisible = sidebarVisible
        state.sidebarWidth = sidebarWidth
        state.tabs = tabs.compactMap(\.snapshot)
        let terminalTabs = tabs.filter(\.isTerminal)
        state.selectedTabIndex = terminalTabs.firstIndex { $0.id == selectedTabID }
        try? store.save(state)
    }

    /// Cmd+Q: ask about unsaved editors, then clean up local processes.
    func prepareToQuit() -> Bool {
        for tab in tabs {
            guard let doc = tab.editor, doc.isDirty else { continue }
            selectTab(tab.id)
            switch Prompt.unsavedChanges(fileName: doc.fileName) {
            case .cancel: return false
            case .discard: continue
            case .save:
                // Saving is async; keep the app open and let the user quit again.
                Task { await self.save(doc) }
                return false
            }
        }
        saveNow()
        monitor.stop()
        for s in sessions.values { s.terminate() }
        sessions.removeAll()
        hub.shutdown()
        return true
    }
}
