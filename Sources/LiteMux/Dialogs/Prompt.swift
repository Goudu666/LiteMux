import AppKit

/// Small native modal prompts. Kept as plain NSAlert so they look exactly
/// like the rest of macOS.
@MainActor
enum Prompt {
    static func text(title: String, message: String, placeholder: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if !initial.isEmpty {
            // Select the stem so typing replaces the name but keeps the extension.
            Task { @MainActor in
                let stem = (initial as NSString).deletingPathExtension
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
            }
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/") else { return nil }
        return value
    }

    static func confirm(title: String, message: String, confirm: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .critical : .warning
        let button = alert.addButton(withTitle: confirm)
        if destructive { button.hasDestructiveAction = true }
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    enum SaveChoice { case save, discard, cancel }

    static func unsavedChanges(fileName: String) -> SaveChoice {
        let alert = NSAlert()
        alert.messageText = "要保存对「\(fileName)」的更改吗？"
        alert.informativeText = "如果不保存，你的更改会丢失。"
        alert.addButton(withTitle: "保存")
        let discard = alert.addButton(withTitle: "不保存")
        discard.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Shown when a file is too large or binary for the editor.
    static func offerDownload(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "下载到“下载”文件夹")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
