import Foundation

/// One plotted point. `x` is training progress in epochs when the log says
/// where it is, otherwise a running index.
public struct MetricPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// The history of one metric within a run.
public struct MetricSeries: Equatable, Sendable, Identifiable {
    public let name: String
    public private(set) var points: [MetricPoint] = []
    public var id: String { name }

    static let capacity = 3000

    public init(name: String, points: [MetricPoint] = []) {
        self.name = name
        self.points = points
    }

    public var last: Double? { points.last?.y }
    public var lowerIsBetter: Bool { MetricLineParser.lowerIsBetter(name) }
    public var isLearningRate: Bool { MetricLineParser.isLearningRate(name) }

    /// Best finite value so far (nil for learning rates).
    public var best: Double? {
        guard !isLearningRate else { return nil }
        let finite = points.lazy.map(\.y).filter(\.isFinite)
        return lowerIsBetter ? finite.min() : finite.max()
    }

    /// -1 falling, 0 flat, +1 rising: mean of the last 5 points against the 5 before.
    public var trend: Int {
        let ys = points.suffix(10).map(\.y).filter(\.isFinite)
        guard ys.count >= 4 else { return 0 }
        let half = ys.count / 2
        let a = ys.prefix(half).reduce(0, +) / Double(half)
        let b = ys.suffix(ys.count - half).reduce(0, +) / Double(ys.count - half)
        let scale = max(abs(a), abs(b), 1e-12)
        if abs(b - a) / scale < 0.01 { return 0 }
        return b > a ? 1 : -1
    }

    /// Adds or replaces the point at `x`. Redraws of the same log line land on
    /// the same `x`, so the curve never grows duplicates.
    mutating func upsert(_ p: MetricPoint) {
        if let lastX = points.last?.x {
            if abs(lastX - p.x) < 1e-9 { points[points.count - 1] = p; return }
            if p.x < lastX {
                var lo = 0, hi = points.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if points[mid].x < p.x { lo = mid + 1 } else { hi = mid }
                }
                if lo < points.count, abs(points[lo].x - p.x) < 1e-9 { points[lo] = p } else { points.insert(p, at: lo) }
                return
            }
        }
        points.append(p)
        if points.count > Self.capacity {
            // Halve the history, always keeping the newest point.
            let newest = points[points.count - 1]
            points = stride(from: 0, to: points.count - 1, by: 2).map { points[$0] } + [newest]
        }
    }
}

/// One training run, as far as the terminal has shown it.
public struct TrainingRun: Equatable, Sendable, Identifiable {
    public enum Status: Equatable, Sendable {
        case running
        case finished
        /// A metric became NaN or infinite.
        case diverged(metric: String)
        case crashed(reason: String)
    }

    public let id: UUID
    public let startedAt: Date
    public internal(set) var updatedAt: Date
    public internal(set) var status: Status = .running
    public internal(set) var series: [MetricSeries] = []
    public internal(set) var epoch: Double?
    public internal(set) var epochTotal: Int?
    public internal(set) var step: Int?
    public internal(set) var stepTotal: Int?
    /// 0…1 when the total number of epochs is known.
    public internal(set) var fraction: Double?
    /// First observation used for the ETA (the tracker may join a run halfway).
    var etaOrigin: (time: Date, fraction: Double)?
    var sequence = 0
    var maxEpoch: Double = -1
    var zeroBased = false
    /// x of the last record that said where it was.
    var lastX: Double?

    public static func == (a: TrainingRun, b: TrainingRun) -> Bool {
        a.id == b.id && a.updatedAt == b.updatedAt && a.status == b.status && a.series == b.series
            && a.epoch == b.epoch && a.step == b.step && a.fraction == b.fraction
    }

    init(now: Date) {
        id = UUID()
        startedAt = now
        updatedAt = now
    }

    public func series(named name: String) -> MetricSeries? { series.first { $0.name == name } }

    /// The metric for the status bar: `loss`, then any training loss, then anything.
    public var primary: MetricSeries? {
        let candidates = series.filter { !$0.points.isEmpty && !$0.isLearningRate }
        for name in ["loss", "train_loss", "train/loss", "total_loss", "Loss"] {
            if let s = candidates.first(where: { $0.name == name }) { return s }
        }
        let lower = { (s: MetricSeries) in s.name.lowercased() }
        return candidates.first { lower($0).contains("loss") && !lower($0).hasPrefix("val") && !lower($0).hasPrefix("eval") }
            ?? candidates.first { lower($0).contains("loss") }
            ?? candidates.first
            ?? series.first { !$0.points.isEmpty }
    }

    /// Series in display order: losses, then quality metrics, then the learning rate.
    public var orderedSeries: [MetricSeries] {
        series.filter { !$0.points.isEmpty }.sorted { a, b in
            func rank(_ s: MetricSeries) -> Int {
                if s.isLearningRate { return 3 }
                let n = s.name.lowercased()
                if n.contains("loss") { return n.hasPrefix("val") || n.hasPrefix("eval") || n.hasPrefix("test") ? 1 : 0 }
                return 2
            }
            let (ra, rb) = (rank(a), rank(b))
            return ra != rb ? ra < rb : a.name < b.name
        }
    }

    public var isActive: Bool { status == .running }

    /// Estimated seconds left, from the pace observed since the tracker joined.
    public func eta(now: Date = Date()) -> TimeInterval? {
        guard status == .running, let f = fraction, let origin = etaOrigin, f < 1 else { return nil }
        let done = f - origin.fraction
        let elapsed = now.timeIntervalSince(origin.time)
        guard done > 0.004, elapsed > 5 else { return nil }
        return elapsed / done * (1 - f)
    }
}

/// What the app may want to tell the user about.
public enum TrainingEvent: Equatable, Sendable {
    case started
    case finished
    case diverged(metric: String)
    case crashed(reason: String)
}

/// A rendered terminal row.
public struct ScreenRow: Equatable, Sendable {
    public var text: String
    /// The row continues the previous one (soft wrap).
    public var isWrapped: Bool
    public init(text: String, isWrapped: Bool = false) {
        self.text = text
        self.isWrapped = isWrapped
    }
}

/// Watches what a terminal pane shows and keeps the training curves.
///
/// Fed with snapshots of the visible screen (not the byte stream), so it works the
/// same through tmux redraws, reattaches and `\r` progress bars: every logical line
/// is parsed once, and points are keyed by their epoch/step so a redraw replaces
/// rather than duplicates. Nothing runs on the remote host.
public final class TrainingTracker {
    public private(set) var current: TrainingRun?
    /// The run before `current`, kept to draw as a ghost for comparison.
    public private(set) var previous: TrainingRun?
    /// Bumped whenever `current` or `previous` changes.
    public private(set) var revision = 0

    private var parser = MetricLineParser()
    private var seen = RecentSet(capacity: 2048)
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Joins soft-wrapped rows into logical lines.
    ///
    /// Through tmux the terminal's wrap flag is unreliable in both directions (a
    /// full redraw drops it, and scrolling can set it on a row that starts a new
    /// line), so a row continues the previous one exactly when the previous row
    /// filled the width. tmux moves the wrapping space to the next row, so "full"
    /// means at least `cols - 1` characters.
    public static func logicalLines(_ rows: [ScreenRow], cols: Int) -> [String] {
        var lines: [String] = []
        var previousFull = false
        for row in rows {
            if previousFull, !lines.isEmpty {
                lines[lines.count - 1] += row.text
            } else {
                lines.append(row.text)
            }
            previousFull = cols > 8 && row.text.count >= cols - 1
        }
        return lines
    }

    @discardableResult
    public func ingest(rows: [ScreenRow], cols: Int) -> [TrainingEvent] {
        ingest(lines: Self.logicalLines(rows, cols: cols))
    }

    @discardableResult
    public func ingest(lines: [String]) -> [TrainingEvent] {
        var events: [TrainingEvent] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, seen.insert(line) else { continue }
            guard let parsed = parser.parse(line) else { continue }
            switch parsed {
            case .record(let r):
                events += apply(r)
            case .signal(.finished):
                if var run = current, run.status == .running, !run.series.isEmpty {
                    run.status = .finished
                    run.fraction = run.epochTotal != nil ? 1 : run.fraction
                    run.updatedAt = now()
                    set(run)
                    events.append(.finished)
                }
            case .signal(.crash(let reason)):
                // Only a crash of something we were following is news.
                if var run = current, run.status == .running, !run.series.isEmpty {
                    run.status = .crashed(reason: reason)
                    run.updatedAt = now()
                    set(run)
                    events.append(.crashed(reason: reason))
                }
            }
        }
        return events
    }

    private func set(_ run: TrainingRun) {
        current = run
        revision &+= 1
    }

    private func startRun() -> TrainingRun {
        if let c = current, !c.series.isEmpty { previous = c }
        return TrainingRun(now: now())
    }

    private func apply(_ r: MetricRecord) -> [TrainingEvent] {
        var events: [TrainingEvent] = []
        let t = now()
        var run: TrainingRun
        if let c = current {
            run = c
            let restarted: Bool = {
                let substantive = !r.values.isEmpty || r.epochTotal != nil
                if let e = r.epoch, e <= 1, run.maxEpoch >= 2, substantive { return true }
                if let total = r.epochTotal, let old = run.epochTotal, total != old { return true }
                if run.status != .running, r.hasProgress, (r.epoch ?? 0) <= 1, substantive { return true }
                return false
            }()
            if restarted {
                run = startRun()
                events.append(.started)
            }
        } else {
            run = startRun()
            if !r.values.isEmpty { events.append(.started) }
        }

        if let e = r.epoch {
            run.epoch = e
            run.maxEpoch = max(run.maxEpoch, e)
            if r.step == nil { run.step = nil; run.stepTotal = nil }
        }
        if let total = r.epochTotal { run.epochTotal = total }
        if let s = r.step { run.step = s; run.stepTotal = r.stepTotal ?? run.stepTotal }

        // Where on the x axis this record sits: epochs done, counting partial ones.
        let stepFraction: Double? = {
            guard let s = r.step, let total = r.stepTotal, total > 0 else { return nil }
            return min(1, Double(s) / Double(total))
        }()
        var progress: Double?
        let x: Double
        // Keras bars and YOLO validation rows carry no epoch: they belong to the last one announced.
        if let e = r.epoch ?? ((r.isTableRow || stepFraction != nil) ? run.epoch : nil) {
            if e.rounded() != e {
                run.zeroBased = true                            // Hugging Face: 'epoch': 0.37
                progress = e
            } else {
                if e == 0 { run.zeroBased = true }
                let started = run.zeroBased ? e : e - 1        // epochs finished before this one
                if let f = stepFraction { progress = started + f }
                else if r.values.isEmpty { progress = started } // "Epoch 3/10" header: just begun
                else { progress = started + 1 }                 // per-epoch summary line
            }
            x = progress ?? e
        } else if let s = r.step {
            x = Double(s)
        } else {
            if let last = run.lastX {
                // Values only, e.g. the second half of a line the terminal wrapped,
                // or a validation summary: it belongs where the log last was.
                x = last
            } else {
                run.sequence += 1
                x = Double(run.sequence)
            }
        }

        if r.hasProgress || r.isTableRow || stepFraction != nil { run.lastX = x }

        // Overall progress, when the total is known.
        if let total = run.epochTotal, total > 0, let p = progress {
            let fraction = min(1, max(0, p / Double(total)))
            run.fraction = fraction
            // Lines that arrive together (the screen the tracker joined on) are backlog,
            // not pace: keep moving the origin until time actually passes.
            if let o = run.etaOrigin, t.timeIntervalSince(o.time) >= 1 {} else { run.etaOrigin = (run.etaOrigin?.time ?? t, fraction) }
        }

        for (name, value) in r.values.sorted(by: { $0.key < $1.key }) {
            if let i = run.series.firstIndex(where: { $0.name == name }) {
                run.series[i].upsert(MetricPoint(x: x, y: value))
            } else {
                run.series.append(MetricSeries(name: name, points: [MetricPoint(x: x, y: value)]))
            }
            if !value.isFinite, run.status == .running, !MetricLineParser.isLearningRate(name) {
                run.status = .diverged(metric: name)
                events.append(.diverged(metric: name))
            }
        }

        if run.status == .running, let f = run.fraction, f >= 1, progress != nil, !r.values.isEmpty || stepFraction != nil {
            run.status = .finished
            run.fraction = 1
            events.append(.finished)
        }
        run.updatedAt = t
        set(run)
        return events
    }
}

/// A bounded set of recently seen lines (FIFO eviction).
struct RecentSet {
    private var order: [String] = []
    private var members: Set<String> = []
    private var head = 0
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    /// Returns false if `s` was already present.
    mutating func insert(_ s: String) -> Bool {
        guard !members.contains(s) else { return false }
        members.insert(s)
        if order.count < capacity {
            order.append(s)
        } else {
            members.remove(order[head])
            order[head] = s
            head = (head + 1) % capacity
        }
        return true
    }
}
