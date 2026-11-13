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

    /// Seconds between screen reads while output keeps coming.
    static let interval: TimeInterval = 0.35

    func attach(to view: LocalProcessTerminalView) {
        self.view = view
        let pending = self.pending
        view.setProcessOutputHandler { [weak self] in
            // Parse thread: only schedule; the read happens on main, coalesced.
            guard pending.setIfClear() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + PaneTraining.interval) {
                pending.clear()
                MainActor.assumeIsolated { self?.scan() }
            }
        }
    }

    /// Reads the visible screen now.
    func scan() {
        guard let view else { return }
        let snapshot = view.terminalStateSnapshot()
        let rows = snapshot.visibleRows.map { ScreenRow(text: $0.text, isWrapped: $0.isWrapped) }
        let events = tracker.ingest(rows: rows, cols: snapshot.dimensions.cols)
        guard tracker.revision != lastRevision else { return }
        lastRevision = tracker.revision
        run = tracker.current
        previous = tracker.previous
        if let run = tracker.current {
            for e in events { onEvent?(e, run) }
        }
    }

    /// Whether the status bar should show anything for this pane.
    var hasCurves: Bool { run?.primary != nil }
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
