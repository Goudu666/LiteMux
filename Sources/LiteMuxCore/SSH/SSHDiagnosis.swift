import Foundation

/// Why an `ssh` pane ended right after it started, read from what ssh printed.
///
/// Ephemeral GPU instances (Colab / Kaggle behind cloudflared or ngrok, AutoDL,
/// rented containers) fail in a handful of recognisable ways: the tunnel program
/// is not on the GUI app's PATH, the tunnel on the other side is gone, the
/// instance was recreated on the same host:port so its host key changed, and so on.
public struct SSHDiagnosis: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case hostKeyChanged
        case proxyMissing
        case tunnelGone
        case unresolved
        case refused
        case timeout
        case tooManyKeys
        case authFailed
    }

    public var kind: Kind
    /// One short line for the banner.
    public var title: String
    /// What to do about it.
    public var detail: String
    /// `hostKeyChanged`: the known_hosts name to forget (`host` or `[host]:port`).
    public var knownHostsName: String?
    /// `hostKeyChanged`: the known_hosts file ssh complained about, when it said.
    public var knownHostsFile: String?

    /// `ssh-keygen` arguments that forget the stale key (ssh-keygen keeps a `.old` backup).
    public var forgetHostKeyArguments: [String]? {
        guard kind == .hostKeyChanged, let name = knownHostsName else { return nil }
        var args = ["-R", name]
        if let file = knownHostsFile { args += ["-f", file] }
        return args
    }
}

public enum SSHFailureDiagnosis {

    /// Screen rows back to lines: a row that continues the previous one (soft wrap) is joined to it.
    public static func joinRows(_ rows: [(text: String, isWrapped: Bool)]) -> String {
        var lines: [String] = []
        for row in rows {
            // A full row that wraps has no padding, so only the end of a logical line is trimmed.
            if row.isWrapped, !lines.isEmpty {
                lines[lines.count - 1] += row.text
            } else {
                lines.append(row.text)
            }
        }
        return lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    /// Reads the tail of a failed ssh pane. Returns nil when nothing familiar is there.
    public static func diagnose(_ text: String, endpoint: SSHEndpoint?) -> SSHDiagnosis? {
        let lower = text.lowercased()
        let usesProxy = endpoint?.options.contains { $0.lowercased().hasPrefix("proxycommand") } ?? false
            || lower.contains("proxycommand")

        if lower.contains("remote host identification has changed")
            || (lower.contains("host key verification failed") && lower.contains("offending")) {
            let (name, file) = hostKeyDetails(text, endpoint: endpoint)
            return SSHDiagnosis(
                kind: .hostKeyChanged,
                title: "这台机器的主机密钥变了",
                detail: "实例重建、或者别人的新实例分到了同一个地址和端口时很常见。确认是你自己的实例后，可以忘掉旧密钥再连（旧记录会备份到 known_hosts.old）。",
                knownHostsName: name, knownHostsFile: file)
        }

        if let program = missingProgram(text, lower: lower), usesProxy || isTunnelProgram(program) {
            return SSHDiagnosis(
                kind: .proxyMissing,
                title: "找不到隧道程序 \(program)",
                detail: "ProxyCommand 要用到它。LiteMux 会在登录 Shell 的 PATH、/opt/homebrew/bin、/usr/local/bin、~/.local/bin 里找；装在别处的话，把 ProxyCommand 里的 \(program) 换成完整路径。")
        }

        if lower.contains("could not resolve hostname") || lower.contains("nodename nor servname") {
            return SSHDiagnosis(
                kind: .unresolved,
                title: "地址解析不了",
                detail: "trycloudflare、ngrok 这类隧道地址每次启动都会变；Colab / Kaggle 重启后请在 notebook 里拿新的地址更新书签。也可能是网络或代理问题。")
        }

        if lower.contains("too many authentication failures") {
            return SSHDiagnosis(
                kind: .tooManyKeys,
                title: "认证次数用完了",
                detail: "密钥代理里的密钥太多，服务器在问密码之前就断开了。可以在 ~/.ssh/config 里给这台机器加 IdentitiesOnly yes，或用 ssh-add -D 清掉代理里的密钥。")
        }

        if lower.contains("permission denied (") || lower.contains("permission denied, please try again") {
            return SSHDiagnosis(
                kind: .authFailed,
                title: "认证失败",
                detail: "密码或密钥不对。保存过密码的书签只会试一次（避免被 fail2ban 封），请在书签里更新密码；Colab 隧道脚本每次启动可能会换密码。")
        }

        if lower.contains("kex_exchange_identification") || lower.contains("ssh_exchange_identification")
            || lower.contains("bad handshake") || lower.contains("websocket")
            || lower.contains("connection closed by unknown port")
            || (usesProxy && lower.contains("connection closed by")) {
            return SSHDiagnosis(
                kind: .tunnelGone,
                title: "隧道另一头没有响应",
                detail: "连上了入口，但后面没有 SSH 服务在应答。Colab / Kaggle 的运行时断开或重启后隧道会失效：重新运行 notebook 里的隧道单元，确认 sshd 在跑，再用新地址连。")
        }

        if lower.contains("connection refused") {
            return SSHDiagnosis(
                kind: .refused,
                title: "端口拒绝连接",
                detail: "实例可能已经关机，或者 SSH 服务没起来。容器里的 sshd 常常要手动启动（service ssh start）。也请核对端口号。")
        }

        if lower.contains("operation timed out") || lower.contains("connection timed out") {
            return SSHDiagnosis(
                kind: .timeout,
                title: "连接超时",
                detail: "这个地址没有回应：实例已关机、端口不对，或者需要先连 VPN / 代理。")
        }

        return nil
    }

    // MARK: - Details

    /// `Host key for [0.tcp.ngrok.io]:12345 has changed…` and
    /// `Offending ECDSA key in /Users/me/.ssh/known_hosts:7`.
    static func hostKeyDetails(_ text: String, endpoint: SSHEndpoint?) -> (String?, String?) {
        var name: String?
        if let r = text.range(of: "Host key for "),
           let end = text.range(of: " has changed", range: r.upperBound..<text.endIndex) {
            name = String(text[r.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if name == nil || name?.isEmpty == true, let endpoint {
            if let port = endpoint.port, port != 22 {
                name = "[\(endpoint.host)]:\(port)"
            } else {
                name = endpoint.host
            }
        }
        var file: String?
        for raw in text.components(separatedBy: .newlines) where raw.contains("Offending") {
            guard let r = raw.range(of: " key in ") else { continue }
            var path = String(raw[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let colon = path.lastIndex(of: ":"), Int(path[path.index(after: colon)...]) != nil {
                path = String(path[..<colon])
            }
            if path.hasPrefix("/") { file = path }
            break
        }
        return (name, file)
    }

    /// `sh: cloudflared: command not found`, `zsh:1: command not found: ngrok`,
    /// `/bin/sh: /path/to/cloudflared: No such file or directory`.
    static func missingProgram(_ text: String, lower: String) -> String? {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let l = line.lowercased()
            if let r = l.range(of: "command not found: ") {
                let name = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return lastPathComponent(name) }
            }
            if l.hasSuffix(": command not found") || l.hasSuffix(": no such file or directory") || l.hasSuffix(": not found") {
                let parts = line.components(separatedBy: ": ")
                if parts.count >= 3 {
                    let name = parts[parts.count - 2].trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, !name.contains(" ") { return lastPathComponent(name) }
                }
            }
        }
        return nil
    }

    static func isTunnelProgram(_ name: String) -> Bool {
        ["cloudflared", "ngrok", "websocat", "nc", "ncat", "socat", "corkscrew", "connect", "gcloud", "aws", "boundary", "tailscale"]
            .contains(name.lowercased())
    }

    private static func lastPathComponent(_ s: String) -> String {
        s.split(separator: "/").last.map(String.init) ?? s
    }
}
