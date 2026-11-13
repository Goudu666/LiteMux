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
        let path = env["PATH"] ?? ""
        if !path.contains("/opt/homebrew/bin") {
            env["PATH"] = ([path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
                .filter { !$0.isEmpty }.joined(separator: ":")
        }
        for (k, v) in extra { env[k] = v }
        return env
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
