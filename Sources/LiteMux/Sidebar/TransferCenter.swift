import AppKit
import Observation
import LiteMuxCore

/// Uploads and downloads, streamed through SFTP, with lightweight progress.
@MainActor @Observable
final class TransferCenter {
    @MainActor @Observable
    final class Item: Identifiable {
        enum Direction { case upload, download }
        enum State: Equatable { case running, done, failed(String) }

        let id = UUID()
        let direction: Direction
        let name: String
        var done: UInt64 = 0
        var total: UInt64 = 0
        var state: State = .running
        var localURL: URL?

        init(direction: Direction, name: String) {
            self.direction = direction
            self.name = name
        }

        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored weak var app: AppModel?

    var active: [Item] { items.filter { $0.state == .running } }

    var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    func download(_ entry: FileEntry, from host: HostEntry) {
        guard let app else { return }
        let destination = DownloadNaming.uniqueURL(in: downloadsDirectory, for: entry.name) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let item = Item(direction: .download, name: entry.name)
        item.total = entry.size
        item.localURL = destination
        items.insert(item, at: 0)
        Task {
            do {
                let fs = try await app.hub.fileSystem(for: host)
                try await fs.download(entry.path, to: destination, progress: self.progressHandler(item))
                item.state = .done
                item.done = max(item.done, item.total)
                app.toast("已下载 \(destination.lastPathComponent)", style: .success, action: ("在 Finder 中显示", {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }))
            } catch {
                item.state = .failed(error.localizedDescription)
                try? FileManager.default.removeItem(at: destination)
                app.toast("下载失败：\(error.localizedDescription)", style: .error)
            }
            self.prune()
        }
    }

    /// A whole folder as one `tar -czf -` stream over the shared tunnel (no
    /// remote temp file, no per-file round trips), unpacked into Downloads.
    func downloadFolder(_ entry: FileEntry, from host: HostEntry) {
        guard let app else { return }
        let destination = DownloadNaming.uniqueURL(in: downloadsDirectory, for: entry.name) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let item = Item(direction: .download, name: entry.name + "/")
        item.localURL = destination
        items.insert(item, at: 0)
        let fm = FileManager.default
        if host.isLocal {
            do {
                try fm.copyItem(at: URL(fileURLWithPath: entry.path), to: destination)
                item.state = .done
                app.toast("已下载 \(destination.lastPathComponent)", style: .success)
            } catch {
                item.state = .failed(error.localizedDescription)
                app.toast("下载失败：\(error.localizedDescription)", style: .error)
            }
            return
        }
        let env = app.hub.environment(for: host)
        let shell = ProcessBridgeShell(invocation: app.hub.invocation) { _ in env }
        let archive = fm.temporaryDirectory.appendingPathComponent("litemux-\(UUID().uuidString).tgz")
        Task {
            // Bytes received so far; the compressed size is not known up front.
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    item.done = ((try? fm.attributesOfItem(atPath: archive.path))?[.size] as? NSNumber)?.uint64Value ?? 0
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
            let r = await shell.stream(BridgeScripts.download(entry.path, directory: true), on: host,
                                       input: nil, output: archive, timeout: 6 * 3600)
            poll.cancel()
            defer { try? fm.removeItem(at: archive) }
            guard r.status == 0 else {
                let reason = r.timedOut ? "超时" : r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                item.state = .failed(reason)
                app.toast("下载 \(entry.name) 失败：\(reason)", style: .error)
                self.prune()
                return
            }
            try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let x = await ProcessBridgeShell.execute("/usr/bin/tar", ["-xzf", archive.path, "-C", destination.path],
                                                     environment: nil, directory: nil, stdin: nil, timeout: 3600, outputLimit: 16_000)
            if x.status == 0 {
                item.state = .done
                item.total = item.done
                app.toast("已下载文件夹 \(destination.lastPathComponent)", style: .success, action: ("在 Finder 中显示", {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }))
            } else {
                item.state = .failed(x.err)
                app.toast("解包 \(entry.name) 失败：\(x.err.trimmingCharacters(in: .whitespacesAndNewlines))", style: .error)
            }
            self.prune()
        }
    }

    func upload(_ urls: [URL], to dir: String, on host: HostEntry, completion: @escaping () async -> Void) {
        guard let app else { return }
        Task {
            var failures = 0
            for url in urls {
                let item = Item(direction: .upload, name: url.lastPathComponent)
                item.total = Self.size(of: url)
                items.insert(item, at: 0)
                do {
                    let fs = try await app.hub.fileSystem(for: host)
                    try await fs.upload(url, to: RemotePath.join(dir, url.lastPathComponent),
                                        progress: self.progressHandler(item))
                    item.state = .done
                    item.done = item.total
                } catch {
                    failures += 1
                    item.state = .failed(error.localizedDescription)
                    app.toast("上传 \(url.lastPathComponent) 失败：\(error.localizedDescription)", style: .error)
                }
            }
            await completion()
            if failures == 0 {
                app.toast(urls.count == 1 ? "已上传 \(urls[0].lastPathComponent)" : "已上传 \(urls.count) 个项目", style: .success)
            }
            self.prune()
        }
    }

    private func progressHandler(_ item: Item) -> TransferProgress {
        // Progress arrives off the main actor; coalesce UI updates.
        let throttle = ProgressThrottle()
        return { done, total in
            guard throttle.shouldEmit(done: done, total: total) else { return }
            Task { @MainActor in
                item.done = done
                item.total = max(item.total, total)
            }
        }
    }

    private func prune() {
        let finished = items.filter { $0.state != .running }
        if finished.count > 20 {
            let keep = Set(finished.prefix(20).map(\.id))
            items.removeAll { $0.state != .running && !keep.contains($0.id) }
        }
    }

    private static func size(of url: URL) -> UInt64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        }
        var total: UInt64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e {
                total += UInt64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}

/// Limits progress callbacks to ~20 per second.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func shouldEmit(done: UInt64, total: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if done >= total || now.timeIntervalSince(last) > 0.05 {
            last = now
            return true
        }
        return false
    }
}
