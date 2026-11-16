import Foundation

/// Runs a short-lived command without blocking the main thread.
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func run(_ executable: String, _ arguments: [String],
                    environment: [String: String]? = nil, timeout: TimeInterval = 8) async -> Output {
        await withCheckedContinuation { (cont: CheckedContinuation<Output, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                if let environment { p.environment = environment }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: Output(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let deadline = DispatchTime.now() + timeout
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: deadline)
                timer.setEventHandler { if p.isRunning { p.terminate() } }
                timer.resume()
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(returning: Output(status: p.terminationStatus,
                                              stdout: String(decoding: o, as: UTF8.self),
                                              stderr: String(decoding: e, as: UTF8.self)))
            }
        }
    }

    /// The environment every ssh child gets: inherited, UTF-8, and a sane PATH.
    static func baseEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: Askpass.modeVariable)
        env.removeValue(forKey: Askpass.accountVariable)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "LiteMux"
        if env["LANG"] == nil || env["LANG"]?.isEmpty == true { env["LANG"] = "en_US.UTF-8" }
        if env["LC_CTYPE"] == nil { env["LC_CTYPE"] = "UTF-8" }
        env["PATH"] = searchPath(inherited: env["PATH"] ?? "")
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// A GUI app inherits only `/usr/bin:/bin:/usr/sbin:/sbin`, so a `ProxyCommand` such as
    /// `cloudflared access ssh …` would not be found. Merge the login shell's PATH (read once
    /// at launch, see `loadLoginShellPath`) and the usual install places.
    static func searchPath(inherited: String) -> String {
        let home = NSHomeDirectory()
        let login: String = LoginShellPath.value ?? ""
        var candidates: [String] = inherited.components(separatedBy: ":")
        candidates.append(contentsOf: login.components(separatedBy: ":"))
        let usual: [String] = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/bin",
                               "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        candidates.append(contentsOf: usual)
        var dirs: [String] = []
        for d in candidates where !d.isEmpty && !dirs.contains(d) {
            dirs.append(d)
        }
        return dirs.joined(separator: ":")
    }

    /// Reads `$PATH` from the user's login shell once, in the background (3 s at most).
    static func loadLoginShellPath() {
        guard LoginShellPath.value == nil else { return }
        let shell = loginShell
        Task.detached(priority: .utility) {
            let marker = "__LITEMUX_PATH__"
            let r = await ProcessRunner.run(shell, ["-l", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""], timeout: 3)
            let parts = r.stdout.components(separatedBy: marker)
            if parts.count >= 3, !parts[1].isEmpty { LoginShellPath.value = parts[1] }
        }
    }

    static func environmentArray(_ env: [String: String]) -> [String] {
        env.map { "\($0.key)=\($0.value)" }
    }

    /// The user's login shell from the directory service.
    static var loginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let s = String(cString: shell)
            if !s.isEmpty { return s }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}

/// The login shell's PATH, once known.
enum LoginShellPath {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: String?
    static var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
