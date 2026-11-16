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
        /// The tunnel program wrote text into the SSH stream after sshd's banner.
        case proxyNoise
        /// The tunnel program kept running but sshd never answered (often: waiting for a login).
        case tunnelWaiting
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
    /// colab-cli printed its update notice: offer to turn the check off.
    public var offersColabUpdateFix = false

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

    // MARK: - ProxyCommand (Colab / Kaggle behind cloudflared or ngrok)

    /// With ControlMaster on, OpenSSH sends the ProxyCommand's stderr to /dev/null, so a
    /// failing tunnel only shows "Connection closed by UNKNOWN port 65535". These helpers let
    /// the app resolve the ProxyCommand (`ssh -G`), check its program and run it once itself.
    public struct ProxyTarget: Equatable, Sendable {
        public var command: String
        public var host: String
        public var port: Int
        public var user: String

        /// `%h %p %r %n %%` expanded the way ssh does for ProxyCommand.
        public var expanded: String {
            var out = ""
            var it = command.makeIterator()
            while let c = it.next() {
                guard c == "%" else { out.append(c); continue }
                switch it.next() {
                case "h"?: out += host
                case "n"?: out += host
                case "p"?: out += String(port)
                case "r"?: out += user
                case "%"?: out += "%"
                case let other?: out += "%" + String(other)
                case nil: out += "%"
                }
            }
            return out
        }

        /// The program the ProxyCommand starts (skipping `exec`, `env` and assignments).
        public var program: String? { Self.program(of: command) }

        static func program(of command: String, depth: Int = 0) -> String? {
            var words = ShellWords.split(command)
            while let w = words.first, w == "exec" || w == "env" || ShellScan.isAssignment(w) {
                words.removeFirst()
            }
            guard let first = words.first else { return nil }
            let shells: Set<String> = ["sh", "bash", "zsh", "dash"]
            let base = first.split(separator: "/").last.map(String.init) ?? first
            if shells.contains(base), depth < 3, let c = words.firstIndex(where: { $0 == "-c" || $0 == "-lc" || $0 == "-ec" }),
               c + 1 < words.count, let inner = program(of: words[c + 1], depth: depth + 1) {
                return inner
            }
            return first
        }

        /// The ProxyCommand with its stderr sent to `log`, so LiteMux can show what the tunnel
        /// said (ssh sends it to /dev/null under ControlPersist). ssh prefixes `exec `.
        public func loggingStderr(to log: String) -> String {
            "sh -c " + ShellWords.quote(command) + " 2>" + ShellWords.quote(log)
        }
    }

    /// Reads `ssh -G` output. Nil when the host has no ProxyCommand.
    public static func proxyTarget(fromResolved output: String) -> ProxyTarget? {
        var command: String?
        var host = "", user = "", port = 22
        for raw in output.components(separatedBy: .newlines) {
            guard let space = raw.firstIndex(of: " ") else { continue }
            let key = raw[..<space].lowercased()
            let value = String(raw[raw.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "proxycommand": command = value
            case "hostname": host = value
            case "user": user = value
            case "port": port = Int(value) ?? 22
            default: break
            }
        }
        guard let command, !command.isEmpty, command.lowercased() != "none" else { return nil }
        return ProxyTarget(command: command, host: host, port: port, user: user)
    }

    /// What running the tunnel by hand showed, with stdin kept open like ssh does.
    public struct ProxyProbe: Equatable, Sendable {
        /// stdout lines before sshd's `SSH-2.0-…` line (allowed by RFC 4253, ssh skips them).
        public var beforeBanner: String
        /// Text that arrived after the banner although the server should wait for our ident:
        /// it ends up inside the SSH packet stream.
        public var noise: String
        public var stderr: String
        public var sawBanner: Bool
        public var timedOut: Bool
        public var exitCode: Int32?

        public init(beforeBanner: String = "", noise: String = "", stderr: String = "",
                    sawBanner: Bool = false, timedOut: Bool = false, exitCode: Int32? = nil) {
            self.beforeBanner = beforeBanner
            self.noise = noise
            self.stderr = stderr
            self.sawBanner = sawBanner
            self.timedOut = timedOut
            self.exitCode = exitCode
        }

        /// Splits raw stdout around the banner. A binary packet after the banner (some servers
        /// send KEXINIT at once) starts with a 0x00 length byte and is not noise.
        public static func from(stdout: [UInt8], stderr: [UInt8], timedOut: Bool, exitCode: Int32?) -> ProxyProbe {
            var probe = ProxyProbe(stderr: String(decoding: stderr, as: UTF8.self), timedOut: timedOut, exitCode: exitCode)
            var lineStart = 0
            var before: [String] = []
            var i = 0
            while i < stdout.count {
                if stdout[i] == 0x0A {
                    let line = String(decoding: stdout[lineStart..<i], as: UTF8.self)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                    if line.hasPrefix("SSH-") {
                        probe.sawBanner = true
                        let rest = Array(stdout[(i + 1)...])
                        if let first = rest.first, first != 0 {
                            let printable = rest.prefix { $0 == 0x0A || $0 == 0x0D || $0 == 0x09 || $0 >= 0x20 }
                            probe.noise = String(decoding: printable, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        break
                    }
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty { before.append(line) }
                    lineStart = i + 1
                }
                i += 1
            }
            if !probe.sawBanner, lineStart < stdout.count {
                let tail = String(decoding: stdout[lineStart...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { before.append(tail) }
            }
            probe.beforeBanner = before.joined(separator: "\n")
            return probe
        }
    }

    /// colab-cli's own update notice ("Run 'colab update' to update", "enable_update_check").
    public static func isColabUpdateNotice(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.contains("colab update") || l.contains("enable_update_check")
    }

    /// Combines the stderr LiteMux recorded during the real connection (`connectLog`) with
    /// running the tunnel once by hand (`probe`).
    public static func diagnoseProxy(program: String, found: Bool, probe: ProxyProbe?, connectLog: String? = nil) -> SSHDiagnosis {
        let name = program.split(separator: "/").last.map(String.init) ?? program
        if !found {
            return SSHDiagnosis(
                kind: .proxyMissing,
                title: "找不到隧道程序 \(name)",
                detail: "ProxyCommand 要用到它。LiteMux 会在登录 Shell 的 PATH、/opt/homebrew/bin、/usr/local/bin、~/.local/bin 里找；装在别处的话，把 ProxyCommand 里的 \(name) 换成完整路径。")
        }
        let probe = probe ?? ProxyProbe()
        let everything = [connectLog ?? "", probe.beforeBanner, probe.noise, probe.stderr].joined(separator: "\n")
        let colab = everything.components(separatedBy: .newlines).contains(where: isColabUpdateNotice)

        var d: SSHDiagnosis
        if probe.sawBanner && !probe.noise.isEmpty {
            let colabNoise = probe.noise.components(separatedBy: .newlines).contains(where: isColabUpdateNotice)
            d = SSHDiagnosis(
                kind: .proxyNoise,
                title: colabNoise ? "colab-cli 的更新提示混进了 SSH 数据" : "隧道程序往 SSH 数据里混了文字",
                detail: (colabNoise
                    ? "colab-cli 检查更新后把提示打到了标准输出，而 ProxyCommand 的标准输出就是 SSH 的数据通道，连接因此断开。关掉更新检查（或在终端里跑 colab update）后重连。"
                    : "sshd 的应答后面跟了一段文字，SSH 会把它当成协议数据而断开。让 \(name) 把提示打到 stderr，或关掉这些提示。")
                    + "\n混进来的内容：" + clip(probe.noise))
        } else if probe.sawBanner {
            d = SSHDiagnosis(
                kind: .tunnelGone,
                title: "隧道是通的，但 SSH 握手失败",
                detail: "手动跑了一次 \(name)，对面的 sshd 有应答。可能是隧道刚恢复，先点「重新连接」；还不行的话检查用户名，以及 sshd 是否允许这种登录方式。")
        } else if probe.timedOut {
            d = SSHDiagnosis(
                kind: .tunnelWaiting,
                title: "隧道一直没有接通",
                detail: "\(name) 还在运行，但对面的 sshd 一直没有应答：可能在等你登录授权（先在系统终端里 ssh 一次完成授权），或者 Colab 运行时还在启动、已经断开。")
        } else {
            var detail = "SSH 收不到对面 sshd 的应答。Colab / Kaggle 的运行时断开或重启后隧道会失效：重新运行 notebook 里的隧道单元，确认 sshd 在跑，再用新地址连。"
            if let code = probe.exitCode, code != 0 { detail += "（\(name) 退出码 \(code)）" }
            d = SSHDiagnosis(kind: .tunnelGone, title: "隧道另一头没有响应", detail: detail)
        }

        if let said = tail(connectLog) {
            d.detail += "\n连接时 \(name) 说：" + said
        } else if let said = tail([probe.stderr, probe.beforeBanner].joined(separator: "\n")), d.kind != .proxyNoise {
            d.detail += "\n\(name) 说：" + said
        }
        if colab {
            d.offersColabUpdateFix = true
            if d.kind != .proxyNoise {
                d.detail += "\ncolab-cli 每次都会打印更新提示，可以一键关掉，免得它混进连接。"
            }
        }
        return d
    }

    /// The last two meaningful lines, without colab-cli's update notice.
    static func tail(_ text: String?) -> String? {
        guard let text else { return nil }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isColabUpdateNotice($0) }
            .suffix(2)
            .map(clip)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func clip(_ s: String) -> String {
        s.count > 160 ? String(s.prefix(160)) + "…" : s
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
