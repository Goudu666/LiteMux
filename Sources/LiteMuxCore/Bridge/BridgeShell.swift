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
    /// Runs a script whose stdin is read from `input` and whose stdout goes to
    /// `output` (local files), for transfers of any size and any bytes.
    func stream(_ script: String, on host: HostEntry, input: URL?, output: URL?, timeout: TimeInterval) async -> ShellResult
}

public extension BridgeShell {
    func stream(_ script: String, on host: HostEntry, input: URL?, output: URL?, timeout: TimeInterval) async -> ShellResult {
        ShellResult(status: 127, stderr: Data("这个连接不支持文件传输。".utf8))
    }
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
        connectionArguments(usesAskpass: usesAskpass) + endpoint.arguments(home: invocation.home) + ["sh -c " + ShellWords.quote(script)]
    }

    /// Rides an existing master, never starts one, never prompts.
    public func connectionArguments(usesAskpass: Bool) -> [String] {
        var args = ["-T",
                    "-o", "ControlMaster=no",
                    "-o", "ControlPath=\(invocation.controlPath)",
                    "-o", "ConnectTimeout=6",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3"]
        args += usesAskpass ? SSHInvocation.askpassOptions : ["-o", "BatchMode=yes"]
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

    public func stream(_ script: String, on host: HostEntry, input: URL?, output: URL?, timeout: TimeInterval) async -> ShellResult {
        let env = environment(host)
        if let endpoint = host.endpoint {
            let args = sshArguments(for: endpoint, usesAskpass: host.hasSavedPassword, script: script)
            return await Self.execute(SSHInvocation.sshPath, args, environment: env, directory: nil, stdin: nil,
                                      timeout: timeout, outputLimit: 64_000, stdinFile: input?.path, stdoutFile: output?.path)
        }
        return await Self.execute("/bin/sh", ["-c", script], environment: env, directory: invocation.home, stdin: nil,
                                  timeout: timeout, outputLimit: 64_000, stdinFile: input?.path, stdoutFile: output?.path)
    }

    public func isConnected(_ host: HostEntry) async -> Bool {
        guard let endpoint = host.endpoint else { return true }
        let r = await Self.execute(SSHInvocation.sshPath, invocation.controlArguments(endpoint: endpoint, command: "check"),
                                   environment: environment(host), directory: nil, stdin: nil, timeout: 3, outputLimit: 4096)
        return r.status == 0
    }

    /// Runs a process with capped output and a hard timeout.
    ///
    /// Plain `posix_spawn` and dedicated threads rather than `Process` and the
    /// GCD pool: the child gets only stdin/stdout/stderr (no inherited
    /// descriptors), its own process group (a timeout kills the whole job),
    /// default signal handling (the app ignores SIGPIPE), and no blocking call
    /// ever waits on a shared worker pool.
    /// `stdinFile` / `stdoutFile` connect the child straight to local files
    /// (stdout is then not captured), so transfers never pass through memory.
    public static func execute(_ executable: String, _ arguments: [String], environment: [String: String]?,
                               directory: String?, stdin: Data?, timeout: TimeInterval, outputLimit: Int,
                               stdinFile: String? = nil, stdoutFile: String? = nil) async -> ShellResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ShellResult, Never>) in
            let started = Date()
            let state = ExecutionState(limit: outputLimit)
            let finish: @Sendable (Int32?) -> Void = { status in
                guard let result = state.finish(status: status ?? -1, started: started) else { return }
                trace("done status=\(result.status) out=\(result.stdout.count)B err=\(result.stderr.count)B timedOut=\(result.timedOut) \(String(format: "%.2fs", result.duration))")
                cont.resume(returning: result)
            }
            trace("exec \(executable) \(arguments.suffix(2).joined(separator: " ").prefix(120))")

            var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1], inPipe: [Int32] = [-1, -1]
            var piped = pipe(&outPipe) == 0 && pipe(&errPipe) == 0
            if piped, stdin != nil { piped = pipe(&inPipe) == 0 }
            guard piped else {
                for fd in outPipe + errPipe + inPipe where fd >= 0 { close(fd) }
                state.appendErr(Data("pipe: \(String(cString: strerror(errno)))".utf8))
                finish(127)
                return
            }

            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            if stdin != nil {
                posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
            } else {
                posix_spawn_file_actions_addopen(&actions, 0, stdinFile ?? "/dev/null", O_RDONLY, 0)
            }
            if let stdoutFile {
                posix_spawn_file_actions_addopen(&actions, 1, stdoutFile, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            } else {
                posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
            }
            posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
            if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }

            var attr: posix_spawnattr_t?
            posix_spawnattr_init(&attr)
            defer { posix_spawnattr_destroy(&attr) }
            let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            posix_spawnattr_setflags(&attr, Int16(flags))
            posix_spawnattr_setpgroup(&attr, 0)
            // Darwin's sigset_t is a bit mask: reset SIGPIPE, block nothing.
            var defaults: sigset_t = 1 << (SIGPIPE - 1)
            posix_spawnattr_setsigdefault(&attr, &defaults)
            var mask: sigset_t = 0
            posix_spawnattr_setsigmask(&attr, &mask)

            let env = (environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
            let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
            let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
            var pid: pid_t = 0
            let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
            let child = pid
            for p in argv + envp { free(p) }
            close(outPipe[1]); close(errPipe[1])
            if stdin != nil { close(inPipe[0]) }
            guard rc == 0 else {
                close(outPipe[0]); close(errPipe[0])
                if stdin != nil { close(inPipe[1]) }
                state.appendErr(Data("\(executable): \(String(cString: strerror(rc)))".utf8))
                finish(127)
                return
            }

            if let stdin {
                let fd = inPipe[1]
                Thread {
                    stdin.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                            if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { break }
                        }
                    }
                    close(fd)
                }.start()
            }

            let drained = DispatchGroup()
            for (fd, isOut) in [(outPipe[0], true), (errPipe[0], false)] {
                drained.enter()
                Thread {
                    let capacity = 65_536
                    var buffer = [UInt8](repeating: 0, count: capacity)
                    while true {
                        let n = read(fd, &buffer, capacity)
                        if n > 0 {
                            let chunk = Data(buffer[0..<n])
                            if isOut { state.appendOut(chunk) } else { state.appendErr(chunk) }
                        } else if n < 0, errno == EINTR {
                            continue
                        } else {
                            break
                        }
                    }
                    close(fd)
                    drained.leave()
                }.start()
            }

            let exited = DispatchSemaphore(value: 0)
            Thread {
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0, errno == EINTR {}
                exited.signal()
                let signal = status & 0x7f
                let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
                // Normally the pipes drain at once. Something that outlives the
                // command (a backgrounded job) may keep them open: answer with
                // what we have instead of waiting for it.
                if drained.wait(timeout: .now() + 3) == .timedOut {
                    trace("pipes still open 3s after exit: \(executable)")
                }
                finish(code)
            }.start()

            Thread {
                guard exited.wait(timeout: .now() + timeout) == .timedOut else { return }
                trace("timeout after \(timeout)s: \(executable)")
                state.markTimedOut()
                kill(-child, SIGTERM)
                kill(child, SIGTERM)
                if exited.wait(timeout: .now() + 2) == .timedOut {
                    kill(-child, SIGKILL)
                    kill(child, SIGKILL)
                    Thread.sleep(forTimeInterval: 1)
                    finish(nil)
                }
            }.start()
        }
    }
}

/// CI smoke runs (`LITEMUX_SMOKE_BRIDGE=1`) log every process to stderr.
private let tracing = ProcessInfo.processInfo.environment["LITEMUX_SMOKE_BRIDGE"] == "1"

private func trace(_ message: @autoclosure () -> String) {
    guard tracing else { return }
    FileHandle.standardError.write(Data(("bridge: " + message() + "\n").utf8))
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
