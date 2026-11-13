import AppKit
import UserNotifications
import LiteMuxCore

/// Tells the user when a run finishes, diverges or crashes.
///
/// While LiteMux is frontmost and the pane is in view, the status bar already shows
/// it, so a toast is enough; otherwise a system notification is posted.
@MainActor
enum TrainingNotifier {
    private static var authorized: Bool?

    /// UNUserNotificationCenter aborts in a process without an app bundle (e.g. `swift run`).
    private static var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func message(for event: TrainingEvent, run: TrainingRun) -> (title: String, body: String)? {
        let primary = run.primary
        let value = primary.flatMap { s in s.last.map { "\(s.name) \(PulseFormat.value($0, name: s.name))" } }
        let best = primary.flatMap { s in s.best.map { "最佳 \(PulseFormat.value($0, name: s.name))" } }
        let epoch = PulseFormat.epoch(run)
        switch event {
        case .started:
            return nil
        case .finished:
            let took = PulseFormat.duration(run.updatedAt.timeIntervalSince(run.startedAt))
            return ("训练完成", [epoch, value, best, "用时 \(took)"].compactMap { $0 }.joined(separator: " · "))
        case .diverged(let metric):
            return ("\(metric) 变成了 NaN", [epoch, "训练很可能已经发散"].compactMap { $0 }.joined(separator: " · "))
        case .crashed(let reason):
            return ("训练中断", [reason, epoch].compactMap { $0 }.joined(separator: " · "))
        }
    }

    static func post(_ event: TrainingEvent, run: TrainingRun, where place: String, paneVisible: Bool,
                     toast: (String, Toast.Style) -> Void) {
        guard let m = message(for: event, run: run) else { return }
        if NSApp.isActive && paneVisible {
            toast("\(place) · \(m.title)：\(m.body)", event == .finished ? .success : .error)
            return
        }
        postSystem(title: "\(place) · \(m.title)", body: m.body)
    }

    /// A macOS notification (asks for permission the first time).
    static func postSystem(title: String, body: String) {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if authorized == true { send(); return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                authorized = granted
                if granted { send() }
            }
        }
    }
}
