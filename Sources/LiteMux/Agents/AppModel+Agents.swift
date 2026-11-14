import AppKit
import LiteMuxCore

/// Working alongside local coding agents: watch what they run, ride their
/// SSH connections, and tell them what the user is looking at.
extension AppModel {
    var configHostsForMatching: [SSHConfigHost] { configHosts }
    var allHosts: [HostEntry] { [.local] + bookmarkHosts + sshConfigHosts }

    // MARK: - Hosts for agent connections

    /// The host an agent's connection goes to: a matching one, or a new bookmark.
    func hostForAgent(hostID: String?, endpoint: SSHEndpoint) -> HostEntry {
        if let hostID, let h = host(hostID) { return h }
        if let id = HostMatcher.match(alias: endpoint.destination, endpoint: endpoint, resolved: nil,
                                      bookmarks: state.bookmarks, config: configHosts), let h = host(id) { return h }
        var name = SSHCommandParser.suggestName(for: endpoint)
        let taken = Set(state.bookmarks.map(\.name))
        if taken.contains(name) {
            var n = 2
            while taken.contains("\(name) \(n)") { n += 1 }
            name = "\(name) \(n)"
        }
        let bookmark = Bookmark(name: name, endpoint: endpoint)
        state.bookmarks.append(bookmark)
        scheduleSave()
        toast("已把 \(endpoint.summary) 导入为书签「\(name)」", style: .success)
        return HostEntry.from(bookmark)
    }

    /// Rides a coding agent's ControlMaster when LiteMux has no tunnel of its
    /// own to that host yet, so a password / 2FA login is not asked again.
    func rideAgentTunnel(_ socket: String?, hostID: String, agent: String) async {
        guard let socket, adoptedSockets[hostID] != socket, !isOnline(hostID),
              let h = host(hostID), let endpoint = h.endpoint else { return }
        if await hub.masterIsAlive(endpoint) { return }
        guard await hub.masterIsAlive(endpoint.riding(controlPath: socket)) else { return }
        adoptedSockets[hostID] = socket
        hub.evict(hostID)
        if files.host?.id == hostID {
            files.follow(nil)
            files.follow(host(hostID))
        }
        toast("复用了 \(agent) 的 SSH 连接，不用再登录", style: .info)
    }

    /// Drops rides whose agent tunnel has gone away; later connections use LiteMux's own.
    func agentScanDidUpdate(masters: Set<String>) {
        for (hostID, socket) in adoptedSockets where !masters.contains(socket) && !AgentWatch.isSocket(socket) {
            adoptedSockets[hostID] = nil
        }
    }

    // MARK: - Watching

    /// Click on a live row: watch its tmux session, open its log, or open a
    /// terminal where it works.
    func watchAgent(_ row: AgentWatch.Live, takeOver: Bool = false) {
        Task {
            let host = hostForAgent(hostID: row.hostID, endpoint: row.ssh.argv.endpoint)
            await rideAgentTunnel(row.socket, hostID: host.id, agent: row.ssh.agent?.title ?? row.ssh.app ?? "终端")
            follow(row.insight, on: self.host(host.id) ?? host, takeOver: takeOver)
        }
    }

    /// Click on a history row.
    func revisit(_ action: AgentAction, takeOver: Bool = false) {
        if action.source == .bridge {
            if let id = agents.hostID(for: action) { activate(hostID: id) }
            return
        }
        guard let endpoint = action.endpoint else { return }
        Task {
            let host = hostForAgent(hostID: agents.hostID(for: action), endpoint: endpoint)
            await rideAgentTunnel(agents.socket(forHost: host.id), hostID: host.id, agent: action.agentName)
            follow(action.insight, on: self.host(host.id) ?? host, takeOver: takeOver)
        }
    }

    /// Opens a terminal riding a tunnel an agent left in the background.
    func openTunnel(_ tunnel: AgentWatch.Tunnel) {
        let endpoint: SSHEndpoint
        if let id = tunnel.hostID, let h = host(id), let ep = h.endpoint {
            endpoint = ep
        } else if let ep = tunnel.endpoint {
            endpoint = ep
        } else {
            toast("不知道这条隧道通向哪台机器", style: .error)
            return
        }
        Task {
            let host = hostForAgent(hostID: tunnel.hostID, endpoint: endpoint)
            await rideAgentTunnel(tunnel.master.socketPath, hostID: host.id, agent: "Agent")
            activate(hostID: host.id)
        }
    }

    func follow(_ insight: RemoteCommandInsight, on host: HostEntry, takeOver: Bool = false) {
        if let session = insight.tmuxSessions.last {
            openTmuxSession(session, host: host, select: true, readOnly: !takeOver)
        } else if let log = insight.logFiles.first {
            openRemoteFile(Self.path(log, in: insight.directory), on: host)
        } else {
            openTerminalTab(host: host, directory: insight.directory)
        }
    }

    func openAgentTerminal(endpoint: SSHEndpoint, hostID: String?, directory: String?) {
        let host = hostForAgent(hostID: hostID, endpoint: endpoint)
        openTerminalTab(host: host, directory: directory)
    }

    func browseAgentFiles(endpoint: SSHEndpoint, hostID: String?, directory: String?) {
        let host = hostForAgent(hostID: hostID, endpoint: endpoint)
        if let directory {
            state.lastDirectories[host.id] = directory
            if files.host?.id == host.id { Task { await files.open(directory) } }
        }
        browseFiles(host)
    }

    func openRemoteFile(_ path: String, on host: HostEntry) {
        Task {
            do {
                let fs = try await hub.fileSystem(for: host)
                let resolved = try await fs.resolve(path)
                openEditor(host: host, path: resolved, size: 0)
            } catch {
                toast("打不开 \(path)：\(error.localizedDescription)", style: .error)
            }
        }
    }

    /// A log path relative to the command's `cd`.
    static func path(_ file: String, in directory: String?) -> String {
        if file.hasPrefix("/") || file.hasPrefix("~") { return file }
        guard let directory, !directory.isEmpty else { return "~/" + file }
        return directory.hasSuffix("/") ? directory + file : directory + "/" + file
    }

    func copyText(_ text: String, note: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast(note, style: .info)
    }

    // MARK: - What the user is looking at

    func startFocusWriter() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.writeFocus()
            }
        }
    }

    /// Writes `~/.config/litemux/focus.json` when it changed (and once a minute).
    func writeFocus(running: Bool = true, force: Bool = false) {
        let f = currentFocus(running: running)
        if !force, let last = lastFocus, last.sameContent(as: f), Date().timeIntervalSince(last.updated) < 60 { return }
        lastFocus = f
        try? f.save()
    }

    func currentFocus(running: Bool) -> UserFocus {
        var f = UserFocus(running: running)
        if let tab = selectedTab {
            if let doc = tab.editor, let h = host(doc.hostID) {
                f.view = "editor"
                let (line, selection) = selectionInfo(doc)
                f.file = UserFocus.File(hostID: h.id, host: h.title, path: doc.path, cursorLine: line,
                                        selection: selection, unsaved: doc.isDirty)
            } else if let pane = tab.focusedPane, let h = host(pane.hostID) {
                f.view = "terminal"
                let session = pane.session ?? (!h.isLocal && autoTmux(for: h.id) ? pane.tmuxSession : nil)
                f.pane = UserFocus.Pane(hostID: h.id, host: h.title, session: session, readOnly: pane.readOnly == true)
            }
        }
        if let h = files.host, !files.rootPath.isEmpty {
            f.browser = UserFocus.Browser(hostID: h.id, host: h.title, directory: files.rootPath, selected: files.selection)
        }
        f.openFiles = tabs.compactMap { t in t.editor.map { d in "\(host(d.hostID)?.title ?? d.hostID):\(d.path)" } }
        return f
    }

    private func selectionInfo(_ doc: EditorDocument) -> (Int, UserFocus.Selection?) {
        let key = "\(ObjectIdentifier(doc).hashValue)|\(doc.selection.location)|\(doc.selection.length)|\(doc.edits)|\(doc.revision)"
        if let c = focusSelectionCache, c.key == key { return (c.line, c.selection) }
        let r = UserFocus.selection(in: doc.text, location: doc.selection.location, length: doc.selection.length)
        focusSelectionCache = (key, r.cursorLine, r.selection)
        return (r.cursorLine, r.selection)
    }

    /// "复制引用": `host:/path:12-30` and the selected code, ready to paste to an agent.
    func copyReference(_ doc: EditorDocument) {
        let h = host(doc.hostID)
        let place = (h?.isLocal ?? true) ? doc.path : "\(h?.title ?? doc.hostID):\(doc.path)"
        let r = UserFocus.selection(in: doc.text, location: doc.selection.location, length: doc.selection.length, limit: 64_000)
        var text = place
        if let s = r.selection {
            text += s.startLine == s.endLine ? ":\(s.startLine)" : ":\(s.startLine)-\(s.endLine)"
            text += "\n```\(Self.fence(doc.fileExtension))\n\(s.text)\n```"
            copyText(text, note: "已复制 \(doc.fileName) 第 \(s.startLine == s.endLine ? "\(s.startLine)" : "\(s.startLine)–\(s.endLine)") 行，可以直接粘贴给 Agent")
        } else {
            text += ":\(r.cursorLine)"
            copyText(text, note: "已复制 \(text)")
        }
    }

    static func fence(_ ext: String) -> String {
        switch ext {
        case "py", "pyi": return "python"
        case "sh", "bash", "zsh": return "bash"
        case "yml": return "yaml"
        case "md": return "markdown"
        case "h", "cc", "hpp", "cu": return "cpp"
        case "rs": return "rust"
        case "js", "mjs": return "javascript"
        case "ts": return "typescript"
        default: return ext
        }
    }

    // MARK: - CI

    func smokeAgentWatch() {
        let log = { (s: String) in FileHandle.standardError.write(Data(("smoke: " + s + "\n").utf8)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.setSidebarMode(.agents) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            guard let self else { return }
            log("agents " + self.agents.smokeSummary)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 13) { [weak self] in
            guard let self else { return }
            log("agents " + self.agents.smokeSummary)
            if let row = self.agents.live.first(where: { !$0.insight.tmuxSessions.isEmpty }) ?? self.agents.live.first {
                log("watching \(row.ssh.argv.destination) tmux=\(row.insight.tmuxSessions)")
                self.watchAgent(row)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in
            guard let self else { return }
            log("adopted \(self.adoptedSockets) tab=\(self.selectedTab.map(self.tabTitle) ?? "-")")
            log("focus " + self.currentFocus(running: true).describe())
        }
    }
}
