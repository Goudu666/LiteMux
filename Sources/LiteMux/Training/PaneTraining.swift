import AppKit
import Observation
import SwiftTerm
import LiteMuxCore

/// Training Pulse for one terminal pane.
///
/// After each output batch the pane's visible screen is read (at most a few times
/// a second) and handed to `TrainingTracker`. This is purely local: it looks at
/// what the terminal already shows and never runs anything on the server.
@MainActor @Observable
final class PaneTraining {
    private(set) var run: TrainingRun?
    private(set) var previous: TrainingRun?

    @ObservationIgnored var onEvent: ((TrainingEvent, TrainingRun) -> Void)?
    @ObservationIgnored private let tracker = TrainingTracker()
    @ObservationIgnored private weak var view: TerminalView?
    @ObservationIgnored private let pending = PendingFlag()
    @ObservationIgnored private var lastRevision = -1

    /// CI smoke runs log every change to stderr.
    private static let trace = ProcessInfo.processInfo.environment["LITEMUX_SMOKE_PULSE"] == "1"

    /// Seconds between screen reads while output keeps coming.
    static let interval: TimeInterval = 0.35

    func attach(to view: LocalProcessTerminalView) {
        self.view = view
        let pending = self.pending
        let owner = WeakTraining(self)
        view.setProcessOutputHandler {
            // Parse thread: only schedule; the read happens on main, coalesced.
            guard pending.setIfClear() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + PaneTraining.interval) {
                pending.clear()
                MainActor.assumeIsolated { owner.value?.scan() }
            }
        }
    }

    /// Reads the visible screen now.
    func scan() {
        guard let view else { return }
        let snapshot = view.terminalStateSnapshot()
        let rows = snapshot.visibleRows.map { ScreenRow(text: $0.text, isWrapped: $0.isWrapped) }
        let events = tracker.ingest(rows: rows, cols: snapshot.dimensions.cols)
        if Self.trace {
            let tail = rows.suffix(5).map { "[\($0.text.count)\($0.isWrapped ? "w" : "")] \($0.text)" }.joined(separator: "\n    ")
            FileHandle.standardError.write(Data("scan cols=\(snapshot.dimensions.cols) rows=\(rows.count)\n    \(tail)\n".utf8))
        }
        guard tracker.revision != lastRevision else { return }
        lastRevision = tracker.revision
        if Self.trace {
            let c = tracker.current
            FileHandle.standardError.write(Data("pulse rev=\(tracker.revision) epoch=\(c?.epoch ?? -1) status=\(String(describing: c?.status)) events=\(events)\n".utf8))
        }
        run = tracker.current
        previous = tracker.previous
        if let run = tracker.current {
            for e in events { onEvent?(e, run) }
        }
    }

    /// Whether the status bar should show anything for this pane.
    var hasCurves: Bool { run?.primary != nil }
}

/// Lets the parse-thread callback reach the pane without retaining it.
private final class WeakTraining: @unchecked Sendable {
    weak var value: PaneTraining?
    init(_ value: PaneTraining) { self.value = value }
}

/// A test-and-set flag shared with SwiftTerm's parse thread.
private final class PendingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func setIfClear() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }

    func clear() {
        lock.lock(); value = false; lock.unlock()
    }
}
