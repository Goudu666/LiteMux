import Foundation

/// colab-cli prints an update notice on every run unless `enable_update_check` is false in
/// `~/.config/colab-cli/settings.json` (its own suggestion). LiteMux can set that for the user.
public enum ColabCLISettings {
    public enum EditError: Error, Equatable {
        /// The file exists but is not a JSON object: leave it alone.
        case notAnObject
    }

    public static func path(home: String = NSHomeDirectory()) -> String {
        home + "/.config/colab-cli/settings.json"
    }

    /// The settings with the update check off, keeping every other key as it was.
    public static func disablingUpdateCheck(_ existing: Data?) throws -> Data {
        var object: [String: Any] = [:]
        if let existing, !existing.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw EditError.notAnObject
            }
            object = parsed
        }
        object["enable_update_check"] = false
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        return data
    }

    /// Writes the change in place (creating the folder when needed). Returns the file path.
    @discardableResult
    public static func disableUpdateCheck(home: String = NSHomeDirectory()) throws -> String {
        let file = path(home: home)
        let fm = FileManager.default
        let existing = fm.contents(atPath: file)
        let data = try disablingUpdateCheck(existing)
        try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: file), options: .atomic)
        return file
    }
}
