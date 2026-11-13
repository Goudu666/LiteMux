import Foundation
import Darwin
import Observation
import LiteMuxCore

/// Samples only the foreground host, every 5 seconds. Switching hosts stops
/// the previous sampler at once, so background hosts cost nothing.
@MainActor @Observable
final class StatusMonitor {
    enum Health: Equatable {
        case idle
        case connecting
        case online
        case waitingForAuth
        case offline(String)
    }

    private(set) var hostID: String?
    private(set) var hostTitle = ""
    private(set) var sample = ServerSample()
    private(set) var health: Health = .idle

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var channel: RemoteProbeChannel?
    @ObservationIgnored private var previousTicks: CPUTicks?
    @ObservationIgnored private weak var hub: ConnectionHub?
    @ObservationIgnored private var currentHost: HostEntry?

    static let interval: UInt64 = 5_000_000_000

    init(hub: ConnectionHub) {
        self.hub = hub
    }

    func follow(_ host: HostEntry?) {
        guard host?.id != hostID else { return }
        stop()
        hostID = host?.id
        hostTitle = host?.title ?? ""
        currentHost = host
        sample = ServerSample()
        previousTicks = nil
        guard let host else { health = .idle; return }
        health = host.isLocal ? .online : .connecting
        start(host)
    }

    /// Re-try a host that was waiting for the terminal to authenticate.
    func retryIfWaiting(_ hostID: String) {
        guard hostID == self.hostID, let host = currentHost else { return }
        switch health {
        case .waitingForAuth, .offline:
            stop()
            health = .connecting
            start(host)
        default: break
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        channel?.close()
        channel = nil
    }

    private func start(_ host: HostEntry) {
        if host.isLocal {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    self?.sampleLocal()
                    try? await Task.sleep(nanoseconds: StatusMonitor.interval)
                }
            }
            return
        }
        guard let endpoint = host.endpoint, let hub else { return }
        let args = hub.invocation.probeShellArguments(endpoint: endpoint, usesAskpass: host.hasSavedPassword)
        let env = hub.environment(for: host)
        let hostID = host.id
        loop = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.channel == nil || self.channel?.isAlive == false {
                    let ch = RemoteProbeChannel(arguments: args, environment: env)
                    do {
                        try ch.start()
                        self.channel = ch
                    } catch {
                        self.health = .offline(error.localizedDescription)
                    }
                }
                if let ch = self.channel {
                    do {
                        let (output, latency) = try await ch.probe()
                        let parsed = ServerProbe.parse(output)
                        self.sample = ServerProbe.sample(from: parsed, previousTicks: self.previousTicks, latencyMs: latency)
                        if parsed.ticks != nil { self.previousTicks = parsed.ticks }
                        self.health = .online
                        hub.markOnline(hostID)
                        failures = 0
                        // First sample has no CPU delta yet: take the second one quickly.
                        if self.sample.cpuPercent == nil {
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            continue
                        }
                    } catch {
                        failures += 1
                        let reason = ch.failureReason
                        ch.close()
                        self.channel = nil
                        if Self.looksLikeAuth(reason) {
                            self.health = .waitingForAuth
                        } else {
                            self.health = .offline(reason.isEmpty ? "无响应" : reason)
                            hub.markOffline(hostID)
                        }
                    }
                }
                let backoff = failures == 0 ? StatusMonitor.interval : min(UInt64(failures) * StatusMonitor.interval, 30_000_000_000)
                try? await Task.sleep(nanoseconds: backoff)
            }
        }
    }

    static func looksLikeAuth(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return r.contains("permission denied") || r.contains("authentication") || r.contains("batch")
            || r.contains("host key verification")
    }

    // MARK: Local Mac

    private func sampleLocal() {
        var s = ServerSample()
        if let ticks = LocalStats.cpuTicks() {
            if let prev = previousTicks { s.cpuPercent = CPUTicks.percent(from: prev, to: ticks) }
            previousTicks = ticks
        }
        let mem = LocalStats.memory()
        s.memoryUsedBytes = mem.used
        s.memoryTotalBytes = mem.total
        s.diskFreeBytes = LocalStats.homeDiskFree()
        sample = s
        health = .online
    }
}

/// Mach/Foundation readings for the local Mac.
enum LocalStats {
    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let total = user + system + idle + nice
        return CPUTicks(busy: total - idle, total: total)
    }

    static func memory() -> (used: UInt64?, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (nil, total) }
        let page = UInt64(getpagesize())
        // Activity Monitor's "Memory Used": app memory + wired + compressed.
        let app = UInt64(stats.internal_page_count) - UInt64(min(stats.purgeable_count, stats.internal_page_count))
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    static func homeDiskFree() -> UInt64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return UInt64(max(0, free))
    }
}

/// A long-lived `sh` on the server, multiplexed over the shared tunnel. Each
/// probe writes the script to its stdin and reads until the end marker; the
/// time until the first marker echoes back is the round-trip latency.
final class RemoteProbeChannel: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var buffer = ""
    private var stderrText = ""
    private var waiter: CheckedContinuation<(String, Double?), Error>?
    private var sentAt: Date?
    private var latency: Double?
    private var dead = false
    private var generation: UInt64 = 0

    init(arguments: [String], environment: [String: String]) {
        process.executableURL = URL(fileURLWithPath: SSHInvocation.sshPath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    deinit { close() }

    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !dead && process.isRunning
    }

    var failureReason: String {
        lock.lock(); defer { lock.unlock() }
        let lines = stderrText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        return lines.last ?? ""
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; self.fail(); return }
            self.receive(String(decoding: d, as: UTF8.self))
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.lock.lock()
            if self.stderrText.count < 4096 { self.stderrText += String(decoding: d, as: UTF8.self) }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { self?.fail() }
        }
        try process.run()
    }

    func probe(timeout: TimeInterval = 9) async throws -> (String, Double?) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, Double?), Error>) in
            lock.lock()
            if dead {
                lock.unlock()
                cont.resume(throwing: SFTPError.connectionClosed(""))
                return
            }
            generation &+= 1
            let token = generation
            waiter = cont
            buffer = ""
            latency = nil
            sentAt = Date()
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.expire(token)
            }
            do {
                try input.fileHandleForWriting.write(contentsOf: Data(ServerProbe.script.utf8))
            } catch {
                fail()
            }
        }
    }

    private func expire(_ token: UInt64) {
        lock.lock()
        guard token == generation, let w = waiter else { lock.unlock(); return }
        waiter = nil
        lock.unlock()
        w.resume(throwing: SFTPError.timeout)
    }

    private func receive(_ text: String) {
        var done: (CheckedContinuation<(String, Double?), Error>, String, Double?)?
        lock.lock()
        buffer += text
        if latency == nil, buffer.contains(ServerProbe.beginMarker), let sent = sentAt {
            latency = Date().timeIntervalSince(sent) * 1000
        }
        if buffer.contains(ServerProbe.endMarker), let w = waiter {
            done = (w, buffer, latency)
            waiter = nil
            buffer = ""
        }
        lock.unlock()
        if let d = done { d.0.resume(returning: (d.1, d.2)) }
    }

    private func fail() {
        lock.lock()
        dead = true
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(throwing: SFTPError.connectionClosed(failureReason))
    }

    func close() {
        lock.lock()
        dead = true
        let w = waiter
        waiter = nil
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        w?.resume(throwing: SFTPError.connectionClosed("closed"))
        if process.isRunning { process.terminate() }
    }
}
