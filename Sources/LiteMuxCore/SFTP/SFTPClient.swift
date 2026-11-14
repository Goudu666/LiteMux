import Foundation

public enum SFTPError: LocalizedError, Sendable {
    case status(SFTPStatusCode?, String)
    case connectionClosed(String)
    case protocolError(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .status(let code, let message):
            switch code {
            case .noSuchFile: return message.isEmpty ? "文件不存在" : message
            case .permissionDenied: return message.isEmpty ? "没有权限" : message
            default: return message.isEmpty ? "SFTP 操作失败" : message
            }
        case .connectionClosed(let reason): return reason.isEmpty ? "SFTP 连接已断开" : reason
        case .protocolError(let message): return "SFTP 协议错误：\(message)"
        case .timeout: return "连接超时"
        }
    }

    /// True when the failure means the background channel could not authenticate
    /// on its own and the user should finish logging in from a terminal first.
    public var needsInteractiveAuth: Bool {
        if case .connectionClosed(let reason) = self {
            let r = reason.lowercased()
            return r.contains("permission denied") || r.contains("batch mode") || r.contains("host key verification")
                || r.contains("authentication")
        }
        return false
    }
}

/// A small, dependency-free SFTP v3 client that runs over `ssh -s … sftp`.
///
/// Requests are pipelined: many may be in flight at once and responses are
/// matched by request id, which keeps transfers fast on high-latency links.
public final class SFTPClient: @unchecked Sendable {

    public enum Response {
        case status(SFTPStatusCode?, String)
        case handle(Data)
        case data(Data)
        case name([(name: String, longName: String, attributes: SFTPAttributes)])
        case attrs(SFTPAttributes)
    }

    public static let chunkSize: UInt32 = 32 * 1024
    public static let window = 16

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "litemux.sftp.write")

    private let lock = NSLock()
    private var pending: [UInt32: CheckedContinuation<Response, Error>] = [:]
    private var versionWaiter: CheckedContinuation<UInt32, Error>?
    private var nextRequestID: UInt32 = 1
    private var framer = SFTPFramer()
    private var closedReason: String?
    private var stderrBuffer = ""

    public private(set) var serverVersion: UInt32 = 0
    public var onClose: (@Sendable (String) -> Void)?

    public init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    public var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return closedReason == nil && process.isRunning
    }

    /// Launches ssh and performs the INIT/VERSION handshake.
    public func start(timeout: TimeInterval = 12) async throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self else { return }
            if chunk.isEmpty {
                h.readabilityHandler = nil
                self.shutdown(reason: nil)
            } else {
                self.consume(chunk)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self else { return }
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            self.lock.lock()
            if self.stderrBuffer.count < 8192 { self.stderrBuffer += String(decoding: chunk, as: UTF8.self) }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in
            // Give stderr a moment to drain so the error message is complete.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { self?.shutdown(reason: nil) }
        }
        try process.run()

        let version: UInt32 = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt32, Error>) in
            lock.lock()
            if let reason = closedReason {
                lock.unlock()
                cont.resume(throwing: SFTPError.connectionClosed(reason))
                return
            }
            versionWaiter = cont
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stillWaiting = self.versionWaiter != nil
                self.lock.unlock()
                if stillWaiting {
                    self.shutdown(reason: "连接超时")
                    if self.process.isRunning { self.process.terminate() }
                }
            }
            let packet = SFTPWriter.packet(.initialize) { $0.uint32(3) }
            writeQueue.async { self.writeRaw(packet) }
        }
        serverVersion = version
    }

    public func close() {
        shutdown(reason: "closed")
        if process.isRunning { process.terminate() }
    }

    // MARK: - Plumbing

    private func writeRaw(_ data: Data) {
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            shutdown(reason: "写入 SFTP 通道失败")
        }
    }

    private func consume(_ chunk: Data) {
        var deliveries: [(CheckedContinuation<Response, Error>, Result<Response, Error>)] = []
        var versionDelivery: (CheckedContinuation<UInt32, Error>, UInt32)?
        lock.lock()
        framer.append(chunk)
        do {
            while let body = try framer.next() {
                var r = SFTPReader(body)
                let rawType = try r.byte()
                guard let type = SFTPMessage(rawValue: rawType) else { continue }
                if type == .version {
                    let v = try r.uint32()
                    if let w = versionWaiter { versionDelivery = (w, v); versionWaiter = nil }
                    continue
                }
                let id = try r.uint32()
                guard let cont = pending.removeValue(forKey: id) else { continue }
                deliveries.append((cont, Result { try Self.decode(type, &r) }))
            }
        } catch {
            lock.unlock()
            shutdown(reason: "SFTP 数据流损坏")
            return
        }
        lock.unlock()
        if let vd = versionDelivery { vd.0.resume(returning: vd.1) }
        for (cont, result) in deliveries { cont.resume(with: result) }
    }

    private static func decode(_ type: SFTPMessage, _ r: inout SFTPReader) throws -> Response {
        switch type {
        case .status:
            let code = try r.uint32()
            let message = (try? r.string()) ?? ""
            return .status(SFTPStatusCode(rawValue: code), message)
        case .handle:
            return .handle(try r.bytes())
        case .data:
            return .data(try r.bytes())
        case .name:
            let count = try r.uint32()
            var items: [(String, String, SFTPAttributes)] = []
            items.reserveCapacity(Int(min(count, 4096)))
            for _ in 0..<count {
                let name = try r.string()
                let long = try r.string()
                let attrs = try r.attributes()
                items.append((name, long, attrs))
            }
            return .name(items.map { (name: $0.0, longName: $0.1, attributes: $0.2) })
        case .attrs:
            return .attrs(try r.attributes())
        default:
            throw SFTPError.protocolError("unexpected message \(type.rawValue)")
        }
    }

    private func shutdown(reason: String?) {
        lock.lock()
        if closedReason != nil { lock.unlock(); return }
        let err = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalReason = Self.summarize(stderr: err) ?? reason ?? "SFTP 连接已断开"
        closedReason = finalReason
        let waiters = pending
        pending.removeAll()
        let vw = versionWaiter
        versionWaiter = nil
        lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        for (_, c) in waiters { c.resume(throwing: SFTPError.connectionClosed(finalReason)) }
        vw?.resume(throwing: SFTPError.connectionClosed(finalReason))
        onClose?(finalReason)
    }

    /// Picks the meaningful line out of ssh's stderr.
    static func summarize(stderr: String) -> String? {
        let lines = stderr.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        return lines.last
    }

    /// Sends one request and awaits its response.
    public func request(_ type: SFTPMessage, _ build: @escaping (inout SFTPWriter) -> Void) async throws -> Response {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Response, Error>) in
            lock.lock()
            if let reason = closedReason {
                lock.unlock()
                cont.resume(throwing: SFTPError.connectionClosed(reason))
                return
            }
            let id = nextRequestID
            nextRequestID &+= 1
            pending[id] = cont
            lock.unlock()
            let packet = SFTPWriter.packet(type) { w in
                w.uint32(id)
                build(&w)
            }
            writeQueue.async { self.writeRaw(packet) }
        }
    }

    // MARK: - Typed helpers

    private func expectStatus(_ r: Response) throws {
        guard case .status(let code, let msg) = r else { throw SFTPError.protocolError("expected status") }
        if code != .ok { throw SFTPError.status(code, msg) }
    }

    private func expectHandle(_ r: Response) throws -> Data {
        switch r {
        case .handle(let h): return h
        case .status(let code, let msg): throw SFTPError.status(code, msg)
        default: throw SFTPError.protocolError("expected handle")
        }
    }

    private func expectAttrs(_ r: Response) throws -> SFTPAttributes {
        switch r {
        case .attrs(let a): return a
        case .status(let code, let msg): throw SFTPError.status(code, msg)
        default: throw SFTPError.protocolError("expected attrs")
        }
    }

    public func realpath(_ path: String) async throws -> String {
        let r = try await request(.realpath) { $0.string(path) }
        switch r {
        case .name(let items) where !items.isEmpty: return items[0].name
        case .status(let code, let msg): throw SFTPError.status(code, msg)
        default: throw SFTPError.protocolError("expected name")
        }
    }

    public func stat(_ path: String) async throws -> SFTPAttributes {
        try expectAttrs(try await request(.stat) { $0.string(path) })
    }

    public func lstat(_ path: String) async throws -> SFTPAttributes {
        try expectAttrs(try await request(.lstat) { $0.string(path) })
    }

    public func open(_ path: String, flags: SFTPOpenFlags, attributes: SFTPAttributes = SFTPAttributes()) async throws -> Data {
        try expectHandle(try await request(.open) { w in
            w.string(path)
            w.uint32(flags.rawValue)
            w.attributes(attributes)
        })
    }

    public func closeHandle(_ handle: Data) async throws {
        try expectStatus(try await request(.close) { $0.bytes(handle) })
    }

    /// Returns nil at end of file.
    public func read(_ handle: Data, offset: UInt64, length: UInt32) async throws -> Data? {
        let r = try await request(.read) { w in
            w.bytes(handle)
            w.uint64(offset)
            w.uint32(length)
        }
        switch r {
        case .data(let d): return d
        case .status(.eof, _): return nil
        case .status(let code, let msg): throw SFTPError.status(code, msg)
        default: throw SFTPError.protocolError("expected data")
        }
    }

    public func write(_ handle: Data, offset: UInt64, data: Data) async throws {
        try expectStatus(try await request(.write) { w in
            w.bytes(handle)
            w.uint64(offset)
            w.bytes(data)
        })
    }

    public func mkdir(_ path: String) async throws {
        try expectStatus(try await request(.mkdir) { w in
            w.string(path)
            w.attributes(SFTPAttributes())
        })
    }

    public func rmdir(_ path: String) async throws {
        try expectStatus(try await request(.rmdir) { $0.string(path) })
    }

    public func remove(_ path: String) async throws {
        try expectStatus(try await request(.remove) { $0.string(path) })
    }

    public func rename(_ from: String, to: String) async throws {
        try expectStatus(try await request(.rename) { w in
            w.string(from)
            w.string(to)
        })
    }

    /// Lists a directory, resolving whether symlinks point at directories.
    public func listDirectory(_ path: String) async throws -> [FileEntry] {
        let handle = try expectHandle(try await request(.opendir) { $0.string(path) })
        var entries: [FileEntry] = []
        readLoop: while true {
            let r = try await request(.readdir) { $0.bytes(handle) }
            switch r {
            case .name(let items):
                for item in items where item.name != "." && item.name != ".." {
                    let a = item.attributes
                    entries.append(FileEntry(name: item.name, path: RemotePath.join(path, item.name),
                                             kind: a.fileType, size: a.size ?? 0,
                                             permissions: a.permissions, modified: a.modificationDate))
                }
            case .status(.eof, _):
                break readLoop
            case .status(let code, let msg):
                try? await closeHandle(handle)
                throw SFTPError.status(code, msg)
            default:
                break readLoop
            }
        }
        try? await closeHandle(handle)

        // Resolve symlink targets concurrently.
        let links = entries.enumerated().filter { $0.element.kind == .symlink }
        if !links.isEmpty {
            let resolved: [(Int, Bool)] = await withTaskGroup(of: (Int, Bool).self) { group in
                for (index, entry) in links {
                    group.addTask {
                        let isDir = (try? await self.stat(entry.path))?.fileType == .directory
                        return (index, isDir)
                    }
                }
                var out: [(Int, Bool)] = []
                for await item in group { out.append(item) }
                return out
            }
            for (index, isDir) in resolved { entries[index].symlinkIsDirectory = isDir }
        }
        return FileEntry.sorted(entries)
    }

    /// Reads a whole (small) file.
    public func readFile(_ path: String, maxSize: UInt64 = TextFileGate.maxEditableSize) async throws -> Data {
        let handle = try await open(path, flags: .read)
        defer { Task { try? await self.closeHandle(handle) } }
        var result = Data()
        var offset: UInt64 = 0
        while true {
            // Small files: a few pipelined reads per round trip.
            let offsets = (0..<4).map { offset + UInt64($0) * UInt64(Self.chunkSize) }
            let chunks: [(UInt64, Data?)] = try await withThrowingTaskGroup(of: (UInt64, Data?).self) { group in
                for off in offsets {
                    group.addTask { let d = try await self.read(handle, offset: off, length: Self.chunkSize); return (off, d) }
                }
                var out: [(UInt64, Data?)] = []
                for try await c in group { out.append(c) }
                return out.sorted { $0.0 < $1.0 }
            }
            var reachedEnd = false
            for (_, d) in chunks {
                guard let d, !d.isEmpty else { reachedEnd = true; break }
                result.append(d)
                offset += UInt64(d.count)
                if d.count < Int(Self.chunkSize) { reachedEnd = true; break }
            }
            if result.count > maxSize { throw SFTPError.status(.failure, "文件超过 \(maxSize.compactByteString)") }
            if reachedEnd { break }
        }
        return result
    }

    /// Writes data in place, keeping the file's existing permissions.
    public func writeFile(_ path: String, data: Data) async throws {
        let handle = try await open(path, flags: [.write, .create, .truncate])
        do {
            var offset = 0
            let chunk = Int(Self.chunkSize)
            while offset < data.count {
                // Up to `window` writes in flight.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var scheduled = 0
                    while scheduled < Self.window && offset < data.count {
                        let end = min(offset + chunk, data.count)
                        let piece = data.subdata(in: offset..<end)
                        let off = UInt64(offset)
                        group.addTask { try await self.write(handle, offset: off, data: piece) }
                        offset = end
                        scheduled += 1
                    }
                    try await group.waitForAll()
                }
            }
        } catch {
            try? await closeHandle(handle)
            throw error
        }
        try await closeHandle(handle)
    }

    /// Streams a remote file to disk. Memory use is bounded by window × chunk.
    public func download(_ path: String, to local: URL,
                         progress: (@Sendable (UInt64, UInt64) -> Void)? = nil) async throws {
        let total = (try? await stat(path))?.size ?? 0
        let handle = try await open(path, flags: .read)
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let out = try FileHandle(forWritingTo: local)
        defer { try? out.close() }
        var done: UInt64 = 0
        do {
            try await withThrowingTaskGroup(of: (UInt64, UInt32, Data?).self) { group in
                var nextOffset: UInt64 = 0
                var eof = false
                for _ in 0..<Self.window {
                    let off = nextOffset
                    group.addTask { let d = try await self.read(handle, offset: off, length: Self.chunkSize); return (off, Self.chunkSize, d) }
                    nextOffset += UInt64(Self.chunkSize)
                }
                while let result = try await group.next() {
                    let (off, len, data) = result
                    guard let data, !data.isEmpty else { eof = true; continue }
                    try out.seek(toOffset: off)
                    try out.write(contentsOf: data)
                    done += UInt64(data.count)
                    progress?(done, max(total, done))
                    if data.count < Int(len) {
                        // Short read: fetch the rest of this slice.
                        let restOff = off + UInt64(data.count)
                        let restLen = len - UInt32(data.count)
                        group.addTask { let d = try await self.read(handle, offset: restOff, length: restLen); return (restOff, restLen, d) }
                    } else if !eof {
                        let nextOff = nextOffset
                        group.addTask { let d = try await self.read(handle, offset: nextOff, length: Self.chunkSize); return (nextOff, Self.chunkSize, d) }
                        nextOffset += UInt64(Self.chunkSize)
                    }
                }
            }
        } catch {
            try? await closeHandle(handle)
            throw error
        }
        try? await closeHandle(handle)
    }

    /// Streams a local file to the remote path.
    public func upload(_ local: URL, to path: String,
                       progress: (@Sendable (UInt64, UInt64) -> Void)? = nil) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: local.path)
        let total = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        let handle = try await open(path, flags: [.write, .create, .truncate])
        var offset: UInt64 = 0
        do {
            var finished = false
            while !finished {
                try await withThrowingTaskGroup(of: Int.self) { group in
                    for _ in 0..<Self.window {
                        guard let piece = try input.read(upToCount: Int(Self.chunkSize)), !piece.isEmpty else {
                            finished = true
                            break
                        }
                        let off = offset
                        offset += UInt64(piece.count)
                        group.addTask {
                            try await self.write(handle, offset: off, data: piece)
                            return piece.count
                        }
                    }
                    for try await _ in group {}
                    progress?(offset, max(total, offset))
                }
            }
        } catch {
            try? await closeHandle(handle)
            throw error
        }
        try await closeHandle(handle)
    }

    /// Deletes a file, or a directory and everything inside it.
    public func removeRecursively(_ path: String) async throws {
        let a = try await lstat(path)
        if a.fileType == .directory {
            for child in try await listDirectory(path) {
                if child.kind == .directory {
                    try await removeRecursively(child.path)
                } else {
                    try await remove(child.path)
                }
            }
            try await rmdir(path)
        } else {
            try await remove(path)
        }
    }

    /// Creates an empty file; fails if it already exists.
    public func createEmptyFile(_ path: String) async throws {
        let h = try await open(path, flags: [.write, .create, .exclusive])
        try await closeHandle(h)
    }
}
