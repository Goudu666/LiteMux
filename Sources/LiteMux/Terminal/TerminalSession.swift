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
    @ObservationIgnored weak var hub: ConnectionHub?
    @ObservationIgnored var onFocus: ((UUID) -> Void)?
    @ObservationIgnored var onEnded: ((TerminalSession) -> Void)?

    private(set) var phase: Phase = .idle
    private(set) var terminalTitle = ""
    private(set) var startedAt: Date?

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
    }

    var displayTitle: String {
        var t = host.title
        if usesTmux, let slot = pane.slot { t += " · " + SSHInvocation.sessionName(slot: slot) }
        return t
    }

    func startIfNeeded() {
        guard phase == .idle else { return }
        start()
    }

    func start() {
        view.isEnded = false
        phase = .running
        startedAt = Date()
        if let endpoint = host.endpoint {
            guard let hub else { return }
            try? hub.invocation.ensureControlDirectory()
            let args = hub.invocation.terminalArguments(endpoint: endpoint,
                                                        slot: usesTmux ? pane.slot : nil,
                                                        directory: pane.directory,
                                                        usesAskpass: host.hasSavedPassword)
            let env = hub.environment(for: host)
            view.startProcess(executable: SSHInvocation.sshPath, args: args,
                              environment: ProcessRunner.environmentArray(env), execName: "ssh")
            hub.watchForMaster(host)
        } else {
            let shell = ProcessRunner.loginShell
            let name = "-" + (shell as NSString).lastPathComponent
            let env = ProcessRunner.baseEnvironment()
            var args: [String] = []
            if usesTmux, let slot = pane.slot {
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
            message = ranFor < 8 ? "无法连接或认证失败" : "连接已断开"
            hub?.markOffline(host.id)
        } else {
            message = "会话已结束"
        }
        let dim = "\u{1b}[2m", reset = "\u{1b}[0m"
        view.feed(text: "\r\n\(dim)── \(message) · 按 ⏎ 重新连接 · ⌘W 关闭窗格 ──\(reset)\r\n")
        onEnded?(self)
    }
}
