import Foundation
import Observation
import LiteMuxCore

/// A remote (or local) text file opened in an editor tab.
@MainActor @Observable
final class EditorDocument {
    let hostID: String
    let path: String
    var text: String
    private(set) var savedText: String
    var isSaving = false
    var lastError: String?
    /// Bumped when the text is replaced from outside the text view (load/revert).
    private(set) var revision = 0

    init(hostID: String, path: String, text: String) {
        self.hostID = hostID
        self.path = path
        self.text = text
        self.savedText = text
    }

    var fileName: String { RemotePath.lastComponent(path) }
    var isDirty: Bool { text != savedText }
    var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }

    func markSaved() { savedText = text }

    func replaceText(_ newText: String) {
        text = newText
        savedText = newText
        revision += 1
    }
}

/// One tab in the workspace: either a split tree of terminals or an editor.
@MainActor @Observable
final class WorkspaceTab: Identifiable {
    let id: UUID
    var root: SplitNode?
    var editor: EditorDocument?
    /// The pane that had focus last in this tab.
    var focusedPaneID: UUID?

    init(id: UUID = UUID(), root: SplitNode) {
        self.id = id
        self.root = root
        self.focusedPaneID = root.leaves.first?.id
    }

    init(id: UUID = UUID(), editor: EditorDocument) {
        self.id = id
        self.editor = editor
    }

    var isTerminal: Bool { root != nil }

    var focusedPane: PaneSpec? {
        guard let root else { return nil }
        if let id = focusedPaneID, let p = root.pane(id) { return p }
        return root.leaves.first
    }

    /// The host this tab is "about".
    var hostID: String? {
        if let editor { return editor.hostID }
        return focusedPane?.hostID
    }

    var snapshot: TabSnapshot? {
        guard let root else { return nil }
        return TabSnapshot(id: id, kind: .terminal(root))
    }
}
