import Foundation
import LiteMuxCore

/// Runs a ProxyCommand once the way ssh would (`/bin/sh -c "exec …"`, stdin left open) and
/// watches what comes back: sshd's `SSH-2.0-…` banner, text around it, stderr, or nothing.
enum ProxyProber {
    /// - Parameters:
    ///   - timeout: how long to wait for the banner.
    ///   - afterBanner: how long to keep listening after it; a well-behaved server now waits
    ///     for our ident, so anything that arrives is the tunnel's own output in the stream.
    static func run(command: String, environment: [String: String],
                    timeout: TimeInterval = 10, afterBanner: TimeInterval = 1.2) async -> SSHFailureDiagnosis.ProxyProbe {
        await withCheckedContinuation { (cont: CheckedContinuation<SSHFailureDiagnosis.ProxyProbe, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runBlocking(command: command, environment: environment,
                                                   timeout: timeout, afterBanner: afterBanner))
            }
        }
    }

    private static func runBlocking(command: String, environment: [String: String],
                                    timeout: TimeInterval, afterBanner: TimeInterval) -> SSHFailureDiagnosis.ProxyProbe {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exec " + command]
        p.environment = environment
        let input = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = err

        let buffers = Buffers()
        out.fileHandleForReading.readabilityHandler = { h in buffers.appendOut(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in buffers.appendErr(h.availableData) }
        do {
            try p.run()
        } catch {
            return SSHFailureDiagnosis.ProxyProbe(stderr: error.localizedDescription, exitCode: -1)
        }

        let start = Date()
        var bannerAt: Date?
        var timedOut = false
        while true {
            Thread.sleep(forTimeInterval: 0.05)
            if bannerAt == nil, buffers.stdoutHasBanner() { bannerAt = Date() }
            if let b = bannerAt, Date().timeIntervalSince(b) >= afterBanner { break }
            if !p.isRunning { break }
            if bannerAt == nil, Date().timeIntervalSince(start) >= timeout { timedOut = true; break }
        }
        let exited = !p.isRunning
        if p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
        try? input.fileHandleForWriting.close()
        // Let the last bytes land.
        Thread.sleep(forTimeInterval: 0.1)
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let (o, e) = buffers.snapshot()
        return SSHFailureDiagnosis.ProxyProbe.from(stdout: o, stderr: e, timedOut: timedOut,
                                                   exitCode: exited ? p.terminationStatus : nil)
    }

    private final class Buffers: @unchecked Sendable {
        private let lock = NSLock()
        private var out: [UInt8] = []
        private var err: [UInt8] = []

        func appendOut(_ d: Data) { lock.lock(); if out.count < 65_536 { out += d }; lock.unlock() }
        func appendErr(_ d: Data) { lock.lock(); if err.count < 65_536 { err += d }; lock.unlock() }

        func stdoutHasBanner() -> Bool {
            lock.lock(); defer { lock.unlock() }
            // "SSH-" at the start of a line, and the line is complete.
            var lineStart = 0
            for i in 0..<out.count where out[i] == 0x0A {
                if i - lineStart >= 4, out[lineStart] == 0x53, out[lineStart + 1] == 0x53,
                   out[lineStart + 2] == 0x48, out[lineStart + 3] == 0x2D {
                    return true
                }
                lineStart = i + 1
            }
            return false
        }

        func snapshot() -> ([UInt8], [UInt8]) {
            lock.lock(); defer { lock.unlock() }
            return (out, err)
        }
    }
}
