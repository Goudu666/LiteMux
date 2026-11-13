import Foundation
import LiteMuxCore

/// Form state for the "new / paste SSH connection" sheet.
struct ConnectionDraft: Identifiable, Equatable {
    let id = UUID()
    var editingID: UUID?
    var pasted: String = ""
    var name: String = ""
    var host: String = ""
    var port: String = ""
    var user: String = ""
    var identityFile: String = ""
    var proxyJump: String = ""
    var options: [String] = []
    var password: String = ""
    var hasSavedPassword = false
    var clearPassword = false
    var autoTmux = true
    /// The name we generated; replaced again on the next paste unless the user typed their own.
    var suggestedName: String = ""

    init() {}

    init(editing b: Bookmark, autoTmux: Bool) {
        editingID = b.id
        name = b.name
        suggestedName = b.name
        host = b.endpoint.host
        port = b.endpoint.port.map(String.init) ?? ""
        user = b.endpoint.user ?? ""
        identityFile = b.endpoint.identityFile ?? ""
        proxyJump = b.endpoint.proxyJump ?? ""
        options = b.endpoint.options
        hasSavedPassword = b.hasSavedPassword
        self.autoTmux = autoTmux
    }

    var isEditing: Bool { editingID != nil }

    /// Fills the fields from a pasted command; returns false if nothing parsed.
    @discardableResult
    mutating func applyPaste() -> Bool {
        guard let r = SSHCommandParser.parse(pasted) else { return false }
        host = r.endpoint.host
        port = r.endpoint.port.map(String.init) ?? ""
        user = r.endpoint.user ?? ""
        identityFile = r.endpoint.identityFile ?? ""
        proxyJump = r.endpoint.proxyJump ?? ""
        options = r.endpoint.options
        if name.isEmpty || name == suggestedName { name = r.suggestedName }
        suggestedName = r.suggestedName
        if let pw = r.detectedPassword, password.isEmpty { password = pw }
        return true
    }

    var endpoint: SSHEndpoint? {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        let p = Int(port.trimmingCharacters(in: .whitespaces))
        func opt(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        return SSHEndpoint(host: h, user: opt(user), port: p, identityFile: opt(identityFile),
                           proxyJump: opt(proxyJump), options: options)
    }

    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        return endpoint.map { SSHCommandParser.suggestName(for: $0) } ?? "未命名"
    }

    var isValid: Bool {
        guard endpoint != nil else { return false }
        if !port.isEmpty, Int(port).map({ $0 > 0 && $0 < 65536 }) != true { return false }
        return true
    }
}
