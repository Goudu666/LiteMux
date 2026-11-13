import Foundation

/// What came back from a command run for an agent.
public struct ShellResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var truncated: Bool
    public var duration: TimeInterval

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data(),
                timedOut: Bool = false, truncated: Bool = false, duration: TimeInterval = 0) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.truncated = truncated
        self.duration = duration
    }

    public var out: String { String(decoding: stdout, as: UTF8.self) }
    public var err: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs POSIX sh scripts on a host. The app uses `ProcessBridgeShell`; tests use fakes.
public protocol BridgeShell: Sendable {
    func run(_ script: String, on host: HostEntry, stdin: Data?, timeout: TimeInterval, outputLimit: Int) async -> ShellResult
    /// Whether LiteMux already holds a multiplexed tunnel to the host.
    func isConnected(_ host: HostEntry) async -> Bool
}

/// Keeps the first `head` and the last `tail` bytes of a stream.
public struct CappedBuffer: Sendable {
    public let head: Int
    public let tail: Int
    public private(set) var start = Data()
    public private(set) var end = Data()
    public private(set) var total = 0

    public init(limit: Int) {
        head = max(0, limit / 4)
        tail = max(0, limit - limit / 4)
    }

    public var truncated: Bool { total > head + tail }

    public mutating func append(_ data: Data) {
        total += data.count
        var rest = data[...]
        if start.count < head {
            let n = min(head - start.count, rest.count)
            start.append(rest.prefix(n))
            rest = rest.dropFirst(n)
        }
        guard !rest.isEmpty else { return }
        end.append(contentsOf: rest)
        if end.count > tail * 2 || end.count > tail + 65_536 { end = end.suffix(tail) }
    }

    /// The kept bytes, with a marker where the middle was dropped.
    public var data: Data {
        let kept = end.suffix(tail)
        guard truncated else { return start + kept }
        let dropped = total - start.count - kept.count
        return start + Data("\n…（中间省略 \(dropped) 字节）…\n".utf8) + kept
    }
}

/// Runs scripts locally with `/bin/sh` or remotely through `/usr/bin/ssh`.
///
/// Remote calls ride on the ControlMaster tunnel the terminal opened when there
/// is one (`ControlMaster=no` still uses an existing socket) and otherwise make
/// a plain non-interactive connection, so the bridge never leaves a background
/// master holding our pipes open.
public struct ProcessBridgeShell: BridgeShell {
    public var invocation: SSHInvocation
    public var environment: @Sendable (HostEntry) -> [String: String]

    public init(invocation: SSHInvocation = SSHInvocation(),
                environment: @escaping @Sendable (HostEntry) -> [String: String] = { _ in ProcessInfo.processInfo.environment }) {
        self.invocation = invocation
        self.environment = environment
    }

    public func sshArguments(for endpoint: SSHEndpoint, usesAskpass: Bool, script: String) -> [String] {
        var args = ["-T",
                    "-o", "ControlMaster=no",
                    "-o", "ControlPath=\(invocation.controlPath)",
                    "-o", "ConnectTimeout=6",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3"]
        args += usesAskpass ? SSHInvocation.askpassOptions : ["-o", "BatchMode=yes"]
        args += endpoint.arguments(home: invocation.home)
        args.append("sh -c " + ShellWords.quote(script))
        return args
    }

    public func run(_ script: String, on host: HostEntry, stdin: Data?, timeout: TimeInterval, outputLimit: Int) async -> ShellResult {
        let env = environment(host)
        if let endpoint = host.endpoint {
            let args = sshArguments(for: endpoint, usesAskpass: host.hasSavedPassword, script: script)
            return await Self.execute(SSHInvocation.sshPath, args, environment: env, directory: nil,
                                      stdin: stdin, timeout: timeout, outputLimit: outputLimit)
        }
        return await Self.execute("/bin/sh", ["-c", script], environment: env, directory: invocation.home,
                                  stdin: stdin, timeout: timeout, outputLimit: outputLimit)
    }

    public func isConnected(_ host: HostEntry) async -> Bool {
        guard let endpoint = host.endpoint else { return true }
        let r = await Self.execute(SSHInvocation.sshPath, invocation.controlArguments(endpoint: endpoint, command: "check"),
                                   environment: environment(host), directory: nil, stdin: nil, timeout: 3, outputLimit: 4096)
        return r.status == 0
    }

    /// Runs a process with capped output and a hard timeout.
    public static func execute(_ executable: String, _ arguments: [String], environment: [String: String]?,
                               directory: String?, stdin: Data?, timeout: TimeInterval, outputLimit: Int) async -> ShellResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ShellResult, Never>) in
            let started = Date()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            if let environment { p.environment = environment }
            if let directory { p.currentDirectoryURL = URL(fileURLWithPath: directory) }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let input = stdin.map { _ in Pipe() }
            p.standardInput = input ?? FileHandle.nullDevice

            let state = ExecutionState(limit: outputLimit)
            let finish: @Sendable (Int32?) -> Void = { status in
                guard let result = state.finish(status: status ?? -1, started: started) else { return }
                cont.resume(returning: result)
            }
            do {
                try p.run()
            } catch {
                state.appendErr(Data(error.localizedDescription.utf8))
                finish(127)
                return
            }
            if let input, let stdin {
                DispatchQueue.global().async {
                    try? input.fileHandleForWriting.write(contentsOf: stdin)
                    try? input.fileHandleForWriting.close()
                }
            }
            let group = DispatchGroup()
            for (pipe, isOut) in [(out, true), (err, false)] {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let h = pipe.fileHandleForReading
                    while true {
                        let chunk = h.availableData
                        if chunk.isEmpty { break }
                        if isOut { state.appendOut(chunk) } else { state.appendErr(chunk) }
                    }
                    group.leave()
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                guard p.isRunning else { return }
                state.markTimedOut()
                p.terminate()
                // A child that left a grandchild holding the pipe must not hang the agent.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    finish(nil)
                }
            }
            timer.resume()
            DispatchQueue.global().async {
                group.wait()
                p.waitUntilExit()
                timer.cancel()
                finish(p.terminationStatus)
            }
        }
    }
}

/// Shared between the reader threads, the timer and the finisher.
private final class ExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var out: CappedBuffer
    private var err: CappedBuffer
    private var timedOut = false
    private var done = false

    init(limit: Int) {
        out = CappedBuffer(limit: limit)
        err = CappedBuffer(limit: max(4096, limit / 4))
    }

    func appendOut(_ d: Data) { lock.lock(); out.append(d); lock.unlock() }
    func appendErr(_ d: Data) { lock.lock(); err.append(d); lock.unlock() }
    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }

    /// The result the first time it is called, nil afterwards.
    func finish(status: Int32, started: Date) -> ShellResult? {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return nil }
        done = true
        return ShellResult(status: status, stdout: out.data, stderr: err.data, timedOut: timedOut,
                           truncated: out.truncated || err.truncated, duration: Date().timeIntervalSince(started))
    }
}
