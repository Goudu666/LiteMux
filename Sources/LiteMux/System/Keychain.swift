import Foundation
import Security

/// Bookmark passwords, stored as generic passwords in the login Keychain.
/// Nothing secret is ever written to LiteMux's own files or to process argv.
enum Keychain {
    static let service = "LiteMux SSH Password"

    static func setPassword(_ password: String, account: String) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "LiteMux · \(account)"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法写入钥匙串（\(status)）"])
        }
    }

    static func password(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// OpenSSH `SSH_ASKPASS` bridge.
///
/// ssh is started with `SSH_ASKPASS=<this executable>` and
/// `SSH_ASKPASS_REQUIRE=force`; it then runs us with the prompt as argv[1].
/// We print the saved password for password prompts only and refuse anything
/// else (host-key questions, OTP codes), so a wrong password fails once
/// (`NumberOfPasswordPrompts=1`) instead of tripping fail2ban.
enum Askpass {
    static let modeVariable = "LITEMUX_ASKPASS"
    static let accountVariable = "LITEMUX_KEYCHAIN_ACCOUNT"

    static func environment(account: String) -> [String: String] {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return [
            "SSH_ASKPASS": exe,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ProcessInfo.processInfo.environment["DISPLAY"] ?? ":0",
            modeVariable: "1",
            accountVariable: account,
        ]
    }

    static func runHelper() -> Int32 {
        let env = ProcessInfo.processInfo.environment
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ").lowercased()
        guard let account = env[accountVariable], !account.isEmpty else { return 1 }
        let isPasswordPrompt = prompt.contains("password") || prompt.contains("密码")
        guard isPasswordPrompt, !prompt.contains("passphrase"), let password = Keychain.password(account: account) else {
            return 1
        }
        FileHandle.standardOutput.write(Data((password + "\n").utf8))
        return 0
    }
}
