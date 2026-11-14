import AppKit
import Observation
import SwiftTerm
import LiteMuxCore

/// The terminal NSView. Adds LiteMux theming, focus reporting, Metal, and
/// "press Return to reconnect" once the process has ended.
final class LiteTerminalView: LocalProcessTerminalView {
    var onFocus: (() -> Void)?
    var onReturnWhileEnded: (() -> Void)?
    var isEnded = false
    var wantsMetal = true
    private var triedMetal = false

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFocus?()
        super.rightMouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        applyLiteMuxTheme()
        if wantsMetal && !triedMetal {
            triedMetal = true
            try? setUseMetal(true)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLiteMuxTheme()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if isEnded {
            if data.contains(13) || data.contains(10) { onReturnWhileEnded?() }
            return
        }
        super.send(source: source, data: data)
    }
}

/// Runtime state of one pane: the PTY child (`ssh` or the login shell) and its view.
@MainActor @Observable
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    enum Phase: Equatable {
        case idle
        case running
        case ended(code: Int32?)
    }

    let pane: PaneSpec
    let host: HostEntry
    let usesTmux: Bool
    let view: LiteTerminalView
    /// Training Pulse: curves recognised in what this pane shows.
    let training = PaneTraining()
    @ObservationIgnored weak var hub: ConnectionHub?
    @ObservationIgnored var onFocus: ((UUID) -> Void)?
    @ObservationIgnored var onEnded: ((TerminalSession) -> Void)?

    private(set) var phase: Phase = .idle
    private(set) var terminalTitle = ""
    private(set) var startedAt: Date?
    /// Why ssh failed, when it printed something LiteMux recognises.
    private(set) var diagnosis: SSHDiagnosis?
    @ObservationIgnored private var acceptNewHostKeyOnce = false

    init(pane: PaneSpec, host: HostEntry, usesTmux: Bool, fontSize: CGFloat, useMetal: Bool, hub: ConnectionHub) {
        self.pane = pane
        self.host = host
        self.usesTmux = usesTmux
        self.hub = hub
        let v = LiteTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        v.font = Theme.monoFont(fontSize)
        v.wantsMetal = useMetal
        v.optionAsMetaKey = true
        v.allowMouseReporting = true
        self.view = v
        super.init()
        v.processDelegate = self
        v.onFocus = { [weak self] in
            guard let self else { return }
            self.onFocus?(self.pane.id)
        }
        v.onReturnWhileEnded = { [weak self] in self?.restart() }
        training.attach(to: v)
    }

    var displayTitle: String {
        var t = host.title
        if usesTmux, let name = pane.tmuxSession { t += " · " + name }
        return t
    }

    func startIfNeeded() {
        guard phase == .idle else { return }
        start()
    }

    func start() {
        view.isEnded = false
        diagnosis = nil
        phase = .running
        startedAt = Date()
        if let endpoint = host.endpoint {
            guard let hub else { return }
            try? hub.invocation.ensureControlDirectory()
            var args = hub.invocation.terminalArguments(endpoint: endpoint,
                                                        slot: usesTmux ? pane.slot : nil,
                                                        directory: pane.directory,
                                                        usesAskpass: host.hasSavedPassword,
                                                        session: pane.session,
                                                        readOnly: pane.readOnly == true)
            if acceptNewHostKeyOnce {
                // The user just chose to forget the stale key: take the new one without a second prompt.
                args.insert(contentsOf: ["-o", "StrictHostKeyChecking=accept-new"], at: 1)
                acceptNewHostKeyOnce = false
            }
            let env = hub.environment(for: host)
            view.startProcess(executable: SSHInvocation.sshPath, args: args,
                              environment: ProcessRunner.environmentArray(env), execName: "ssh")
            hub.watchForMaster(host)
        } else {
            let shell = ProcessRunner.loginShell
            let name = "-" + (shell as NSString).lastPathComponent
            let env = ProcessRunner.baseEnvironment()
            var args: [String] = []
            if let named = pane.session {
                let s = ShellWords.quote(named)
                let ro = pane.readOnly == true ? "-r " : ""
                args = ["-l", "-c", "command -v tmux >/dev/null 2>&1 && tmux has-session -t =\(s) 2>/dev/null && exec tmux attach-session \(ro)-t =\(s); exec \"$SHELL\" -l"]
            } else if usesTmux, let slot = pane.slot {
                let s = SSHInvocation.sessionName(slot: slot)
                args = ["-l", "-c", "command -v tmux >/dev/null 2>&1 && exec tmux new-session -A -s \(s); exec \"$SHELL\" -l"]
            }
            let dir = pane.directory.map { ShellWords.expandTilde($0) } ?? NSHomeDirectory()
            view.startProcess(executable: shell, args: args, environment: ProcessRunner.environmentArray(env),
                              execName: args.isEmpty ? name : nil, currentDirectory: dir)
        }
    }

    func restart() {
        guard case .ended = phase else { return }
        view.feed(text: "\u{1b}[2J\u{1b}[H")
        start()
    }

    /// With ControlMaster on, ssh hides the ProxyCommand's stderr, so a broken tunnel only says
    /// "Connection closed by UNKNOWN port 65535". Resolve the ProxyCommand, check its program,
    /// and run it once by hand to see what it says (or whether sshd's banner comes back).
    private func refineProxyDiagnosis(_ endpoint: SSHEndpoint) {
        guard let hub else { return }
        let resolveArgs = ["-G"] + endpoint.arguments(home: hub.invocation.home)
        let env = hub.environment(for: host)
        Task { @MainActor [weak self] in
            let r = await ProcessRunner.run(SSHInvocation.sshPath, resolveArgs, environment: env, timeout: 4)
            guard let target = SSHFailureDiagnosis.proxyTarget(fromResolved: r.stdout),
                  let program = target.program else { return }
            let found = Self.isExecutable(program, path: env["PATH"] ?? "")
            var probe: String?
            if found {
                let p = await ProcessRunner.run("/bin/sh", ["-c", "exec " + target.expanded], environment: env, timeout: 6)
                probe = p.stderr + "\n" + p.stdout
            }
            guard let self, case .ended = self.phase else { return }
            self.diagnosis = SSHFailureDiagnosis.diagnoseProxy(program: program, found: found, probeOutput: probe)
            Self.smokeLog("smoke: diagnosis \(self.diagnosis?.kind.rawValue ?? "none") (refined) \(self.diagnosis?.title ?? "")")
        }
    }

    private static func isExecutable(_ program: String, path: String) -> Bool {
        let fm = FileManager.default
        if program.contains("/") {
            return fm.isExecutableFile(atPath: ShellWords.expandTilde(program))
        }
        return path.split(separator: ":").contains { fm.isExecutableFile(atPath: "\($0)/\(program)") }
    }

    private static func smokeLog(_ line: String) {
        guard ProcessInfo.processInfo.environment["LITEMUX_SMOKE_DIAGNOSE"] == "1" else { return }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// After "REMOTE HOST IDENTIFICATION HAS CHANGED": forget the stale key, then connect again.
    func forgetHostKeyAndReconnect() {
        guard let args = diagnosis?.forgetHostKeyArguments else { return }
        Task { @MainActor in
            let r = await ProcessRunner.run("/usr/bin/ssh-keygen", args, environment: ProcessRunner.baseEnvironment(), timeout: 5)
            if r.status != 0 {
                let dim = "\u{1b}[2m", reset = "\u{1b}[0m"
                view.feed(text: "\(dim)ssh-keygen \(args.joined(separator: " ")) 失败：\(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))\(reset)\r\n")
                return
            }
            acceptNewHostKeyOnce = true
            restart()
        }
    }

    func terminate() {
        if phase == .running { view.terminate() }
        phase = .ended(code: nil)
    }

    func applyFontSize(_ size: CGFloat) {
        view.font = Theme.monoFont(size)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        terminalTitle = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard phase == .running else { return }
        phase = .ended(code: exitCode)
        view.isEnded = true
        let ranFor = Date().timeIntervalSince(startedAt ?? Date())
        let message: String
        if host.endpoint != nil, exitCode == 255 {
            if ranFor < 30 {
                let rows = view.terminalStateSnapshot().visibleRows.suffix(60).map { (text: $0.text, isWrapped: $0.isWrapped) }
                let screen = SSHFailureDiagnosis.joinRows(rows)
                diagnosis = SSHFailureDiagnosis.diagnose(screen, endpoint: host.endpoint)
                Self.smokeLog("smoke: diagnosis \(diagnosis?.kind.rawValue ?? "none") \(diagnosis?.knownHostsName ?? "")")
                if let endpoint = host.endpoint, diagnosis == nil || diagnosis?.kind == .tunnelGone {
                    refineProxyDiagnosis(endpoint)
                }
            }
            message = diagnosis?.title ?? (ranFor < 8 ? "无法连接或认证失败" : "连接已断开")
            hub?.markOffline(host.id)
        } else {
            message = "会话已结束"
        }
        let dim = "\u{1b}[2m", reset = "\u{1b}[0m"
        view.feed(text: "\r\n\(dim)── \(message) · 按 ⏎ 重新连接 · ⌘W 关闭窗格 ──\(reset)\r\n")
        onEnded?(self)
    }
}
