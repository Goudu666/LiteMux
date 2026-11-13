import AppKit
import LiteMuxCore

/// `LiteMux --mcp`: the same executable as a Model Context Protocol server.
///
/// A local coding agent (Claude Code, Codex, Antigravity …) starts it and talks
/// JSON-RPC over stdin/stdout. It reads LiteMux's hosts and rides on the SSH
/// tunnels the app already opened. It ships no model and makes no network
/// calls of its own: the agent brings the AI, LiteMux only opens the door, and
/// commands or writes wait for the user's yes in a LiteMux dialog.
enum BridgeMain {
    static let flag = "--mcp"

    static var requested: Bool { CommandLine.arguments.dropFirst().contains(flag) }

    @MainActor
    static func run() -> Never {
        let app = NSApplication.shared
        // No Dock icon, no menu bar; we only surface for confirmation dialogs.
        app.setActivationPolicy(.accessory)

        let invocation = SSHInvocation()
        let shell = ProcessBridgeShell(invocation: invocation) { host in
            var extra: [String: String] = [:]
            if host.hasSavedPassword { extra = Askpass.environment(account: host.id) }
            return ProcessRunner.baseEnvironment(extra: extra)
        }
        let toolbox = BridgeToolbox(shell: shell, directory: { BridgeHostDirectory.load() }) { host, session in
            // A running LiteMux shows the agent's new pane as a tab (see AppModel).
            BridgeNotice.postNewSession(hostID: host.id, session: session)
        }
        let server = MCPServer(tools: toolbox.tools,
                               mode: { BridgeConfig.load().mode },
                               confirm: { request in await BridgeConfirmDialog.ask(request) },
                               log: BridgeActivityLog())
        let writer = LineWriter()

        let reader = Thread {
            let inFlight = DispatchGroup()
            while let line = readLine(strippingNewline: true) {
                inFlight.enter()
                Task.detached {
                    if let response = await server.handle(line) { writer.write(response) }
                    inFlight.leave()
                }
            }
            // The agent closed stdin: give running calls a moment, then leave.
            _ = inFlight.wait(timeout: .now() + 5)
            exit(0)
        }
        reader.stackSize = 1 << 20
        reader.start()

        app.run()
        exit(0)
    }
}

/// stdout belongs to the protocol: one JSON message per line, never interleaved.
private final class LineWriter: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ line: String) {
        var data = Data(line.utf8)
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardOutput.write(data)
    }
}

/// The dialog in front of every command or write in "执行前确认" mode.
@MainActor
enum BridgeConfirmDialog {
    /// Unanswered requests are refused after this long.
    static let timeout: TimeInterval = 180

    nonisolated static func ask(_ request: BridgeConfirmation) async -> BridgeDecision {
        await MainActor.run { present(request) }
    }

    static func present(_ request: BridgeConfirmation) -> BridgeDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(request.client) 想在「\(request.hostTitle)」上\(request.action)"
        alert.informativeText = "请求来自本机的 Coding Agent，经由 LiteMux Bridge。看一下内容再决定。"
        let allow = alert.addButton(withTitle: "允许")
        let deny = alert.addButton(withTitle: "拒绝")
        alert.addButton(withTitle: "本次会话都允许")
        // Return must never approve: the dialog can pop up while the user is typing.
        allow.keyEquivalent = ""
        deny.keyEquivalent = "\u{1b}"
        alert.accessoryView = detailView(request.detail, diff: request.isDiff)
        alert.window.level = .floating
        alert.window.collectionBehavior.insert(.canJoinAllSpaces)

        NSApp.activate(ignoringOtherApps: true)
        let timer = Timer(timeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }

        if ProcessInfo.processInfo.environment["LITEMUX_SMOKE_BRIDGE"] == "1" {
            FileHandle.standardError.write(Data("bridge: confirmation shown: \(alert.messageText)\n".utf8))
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .allowOnce
        case .alertThirdButtonReturn: return .allowForSession
        default: return .deny
        }
    }

    private static func detailView(_ text: String, diff: Bool) -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let width: CGFloat = diff ? 560 : 440
        let lines = max(1, min(diff ? 22 : 12, text.components(separatedBy: "\n").count))
        let height = min(diff ? 340 : 190, CGFloat(lines) * 16 + 14)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.backgroundColor = NSColor.textColor.withAlphaComponent(0.06).cgColor

        let view = NSTextView(frame: scroll.bounds)
        if diff {
            view.textStorage?.setAttributedString(diffText(text, font: font))
        } else {
            view.string = text
            view.font = font
        }
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }

    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    /// "- " lines on red, "+ " lines on green, hunk headers dimmed.
    static func diffText(_ text: String, font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if line.hasPrefix("+ ") {
                attrs[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.18)
                attrs[.foregroundColor] = adaptive(light: NSColor(calibratedRed: 0.05, green: 0.38, blue: 0.12, alpha: 1), dark: NSColor(calibratedRed: 0.6, green: 0.92, blue: 0.62, alpha: 1))
            } else if line.hasPrefix("- ") {
                attrs[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.16)
                attrs[.foregroundColor] = adaptive(light: NSColor(calibratedRed: 0.55, green: 0.08, blue: 0.08, alpha: 1), dark: NSColor(calibratedRed: 1, green: 0.66, blue: 0.64, alpha: 1))
            } else if line.hasPrefix("@@") || line.hasPrefix("────") {
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
            }
            out.append(NSAttributedString(string: line + (i < lines.count - 1 ? "\n" : ""), attributes: attrs))
        }
        return out
    }
}

/// Bridge → app messages over the distributed notification center (same user only).
enum BridgeNotice {
    static let newSession = Notification.Name("app.litemux.bridge.newSession")

    static func postNewSession(hostID: String, session: String) {
        DistributedNotificationCenter.default().postNotificationName(
            newSession, object: nil, userInfo: ["host": hostID, "session": session], deliverImmediately: true)
    }
}
