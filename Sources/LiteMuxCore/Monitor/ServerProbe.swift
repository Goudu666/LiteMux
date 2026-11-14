import Foundation

/// One GPU line from `nvidia-smi`.
public struct GPUReading: Equatable, Sendable, Identifiable {
    public var index: Int
    public var name: String
    public var memoryUsedMiB: Double
    public var memoryTotalMiB: Double
    public var utilization: Double

    public var id: Int { index }
    public var memoryFraction: Double { memoryTotalMiB > 0 ? memoryUsedMiB / memoryTotalMiB : 0 }

    /// `GPU0 1.2/24G 12%`
    public var compact: String {
        String(format: "GPU%d %.1f/%.0fG %.0f%%", index, memoryUsedMiB / 1024, memoryTotalMiB / 1024, utilization)
    }
}

/// A parsed status-bar sample. Missing fields are simply nil and hidden.
public struct ServerSample: Equatable, Sendable {
    public var cpuPercent: Double?
    public var memoryUsedBytes: UInt64?
    public var memoryTotalBytes: UInt64?
    public var diskFreeBytes: UInt64?
    public var gpus: [GPUReading] = []
    public var latencyMs: Double?

    public init() {}
}

/// Raw cumulative CPU jiffies from the first line of `/proc/stat`.
public struct CPUTicks: Equatable, Sendable {
    public var busy: UInt64
    public var total: UInt64

    public init(busy: UInt64, total: UInt64) {
        self.busy = busy
        self.total = total
    }

    public static func percent(from old: CPUTicks, to new: CPUTicks) -> Double? {
        guard new.total > old.total, new.busy >= old.busy else { return nil }
        let dt = Double(new.total - old.total)
        return min(100, max(0, Double(new.busy - old.busy) / dt * 100))
    }
}

/// The probe script and its parser. The script is plain POSIX sh, reads only
/// `/proc` and standard tools, and leaves nothing behind on the server.
public enum ServerProbe {
    public static let endMarker = "@@lm-end"
    public static let beginMarker = "@@lm-begin"

    /// Written to the long-lived remote `sh` every sample.
    public static let script: String = """
    echo \(beginMarker)
    echo @@cpu; head -n 1 /proc/stat 2>/dev/null
    echo @@mem; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo 2>/dev/null
    echo @@disk; df -Pk "$HOME" 2>/dev/null | tail -n 1
    echo @@gpu; command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null
    echo \(endMarker)

    """

    public struct Parsed: Equatable, Sendable {
        public var ticks: CPUTicks?
        public var memTotalKiB: UInt64?
        public var memAvailableKiB: UInt64?
        public var diskFreeKiB: UInt64?
        public var gpus: [GPUReading] = []
    }

    public static func parse(_ output: String) -> Parsed {
        var parsed = Parsed()
        var section = ""
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("@@") { section = line; continue }
            switch section {
            case "@@cpu":
                parsed.ticks = parseCPU(line)
            case "@@mem":
                let parts = line.split(whereSeparator: { $0 == " " || $0 == ":" }).map(String.init)
                if parts.count >= 2, let v = UInt64(parts[1]) {
                    if parts[0] == "MemTotal" { parsed.memTotalKiB = v }
                    if parts[0] == "MemAvailable" { parsed.memAvailableKiB = v }
                }
            case "@@disk":
                // Filesystem 1024-blocks Used Available Capacity Mounted
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 4, let avail = UInt64(parts[3]) { parsed.diskFreeKiB = avail }
            case "@@gpu":
                if let g = parseGPU(line) { parsed.gpus.append(g) }
            default:
                break
            }
        }
        return parsed
    }

    static func parseCPU(_ line: String) -> CPUTicks? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.first == "cpu" else { return nil }
        let values = parts.dropFirst().compactMap { UInt64($0) }
        guard values.count >= 4 else { return nil }
        // user nice system idle iowait irq softirq steal (guest is already in user)
        let fields = Array(values.prefix(8))
        let total = fields.reduce(0, +)
        let idle = fields[3] + (fields.count > 4 ? fields[4] : 0)
        return CPUTicks(busy: total - idle, total: total)
    }

    static func parseGPU(_ line: String) -> GPUReading? {
        let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 5, let index = Int(parts[0]),
              let used = Double(parts[2]), let total = Double(parts[3]) else { return nil }
        let util = Double(parts[4]) ?? 0
        return GPUReading(index: index, name: parts[1], memoryUsedMiB: used, memoryTotalMiB: total, utilization: util)
    }

    /// Converts a parse into a sample, using the previous CPU ticks for a delta.
    public static func sample(from parsed: Parsed, previousTicks: CPUTicks?, latencyMs: Double?) -> ServerSample {
        var s = ServerSample()
        if let prev = previousTicks, let now = parsed.ticks {
            s.cpuPercent = CPUTicks.percent(from: prev, to: now)
        }
        if let total = parsed.memTotalKiB {
            s.memoryTotalBytes = total * 1024
            if let avail = parsed.memAvailableKiB { s.memoryUsedBytes = (total - min(total, avail)) * 1024 }
        }
        s.diskFreeBytes = parsed.diskFreeKiB.map { $0 * 1024 }
        s.gpus = parsed.gpus.sorted { $0.index < $1.index }
        s.latencyMs = latencyMs
        return s
    }
}

/// Notices a GPU going quiet after real work: a finished (or dead) job on a
/// machine rented by the hour.
public struct GPUIdleDetector: Sendable {
    public var idleAfter: TimeInterval
    public var minimumBusy: TimeInterval
    private var busySince: Date?
    private var lastBusy: Date?
    private var idleSince: Date?

    public init(idleAfter: TimeInterval = 300, minimumBusy: TimeInterval = 120) {
        self.idleAfter = idleAfter
        self.minimumBusy = minimumBusy
    }

    static func isBusy(_ g: GPUReading) -> Bool { g.utilization >= 30 || g.memoryFraction >= 0.10 }
    static func isIdle(_ g: GPUReading) -> Bool { g.utilization < 5 && g.memoryFraction < 0.05 }

    /// True exactly once per busy → idle transition, `idleAfter` into the quiet.
    public mutating func observe(_ gpus: [GPUReading], at now: Date = Date()) -> Bool {
        guard !gpus.isEmpty else { return false }
        if gpus.contains(where: Self.isBusy) {
            if busySince == nil { busySince = now }
            lastBusy = now
            idleSince = nil
            return false
        }
        guard gpus.allSatisfy(Self.isIdle) else { idleSince = nil; return false }
        guard let start = busySince, let end = lastBusy, end.timeIntervalSince(start) >= minimumBusy else {
            busySince = nil
            return false
        }
        if idleSince == nil { idleSince = now }
        if let quiet = idleSince, now.timeIntervalSince(quiet) >= idleAfter {
            busySince = nil
            lastBusy = nil
            idleSince = nil
            return true
        }
        return false
    }
}
