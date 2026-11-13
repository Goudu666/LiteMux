import Foundation

public typealias TransferProgress = @Sendable (_ done: UInt64, _ total: UInt64) -> Void

/// The file operations the sidebar and editor need, local or remote.
/// Size and modification time: enough to notice that someone else changed a file.
public struct FileStamp: Equatable, Sendable {
    public var size: UInt64?
    public var modified: Date?
    public init(size: UInt64?, modified: Date?) {
        self.size = size
        self.modified = modified
    }
}

public protocol FileSystemProvider: AnyObject, Sendable {
    func homeDirectory() async throws -> String
    func stamp(of path: String) async throws -> FileStamp
    func list(_ path: String) async throws -> [FileEntry]
    func size(of path: String) async throws -> UInt64
    func readFile(_ path: String) async throws -> Data
    func readHead(_ path: String, length: Int) async throws -> Data
    func writeFile(_ path: String, data: Data) async throws
    func createFile(_ path: String) async throws
    func createDirectory(_ path: String) async throws
    func rename(_ from: String, to: String) async throws
    func removeRecursively(_ path: String) async throws
    func upload(_ local: URL, to path: String, progress: TransferProgress?) async throws
    func download(_ path: String, to local: URL, progress: TransferProgress?) async throws
    func resolve(_ path: String) async throws -> String
}

/// The Mac's own disk, through FileManager.
public final class LocalFileSystem: FileSystemProvider, @unchecked Sendable {
    public init() {}

    private var fm: FileManager { FileManager.default }

    public func homeDirectory() async throws -> String { NSHomeDirectory() }

    public func resolve(_ path: String) async throws -> String {
        let expanded = ShellWords.expandTilde(path)
        return (expanded as NSString).standardizingPath
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        let entries: [FileEntry] = urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let isLink = v?.isSymbolicLink ?? false
            var kind: FileEntry.Kind = (v?.isDirectory ?? false) ? .directory : .file
            var linkDir = false
            if isLink {
                kind = .symlink
                var isDir: ObjCBool = false
                linkDir = fm.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
            }
            return FileEntry(name: u.lastPathComponent, path: u.path, kind: kind, symlinkIsDirectory: linkDir,
                             size: UInt64(v?.fileSize ?? 0), modified: v?.contentModificationDate)
        }
        return FileEntry.sorted(entries)
    }

    public func size(of path: String) async throws -> UInt64 {
        let a = try fm.attributesOfItem(atPath: path)
        return (a[.size] as? NSNumber)?.uint64Value ?? 0
    }

    public func stamp(of path: String) async throws -> FileStamp {
        let a = try fm.attributesOfItem(atPath: path)
        return FileStamp(size: (a[.size] as? NSNumber)?.uint64Value, modified: a[.modificationDate] as? Date)
    }

    public func readFile(_ path: String) async throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func readHead(_ path: String, length: Int) async throws -> Data {
        let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? h.close() }
        return try h.read(upToCount: length) ?? Data()
    }

    public func writeFile(_ path: String, data: Data) async throws {
        // Write through the existing inode so permissions and ownership stay put.
        if fm.fileExists(atPath: path) {
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? h.close() }
            try h.truncate(atOffset: 0)
            try h.write(contentsOf: data)
        } else {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    public func createFile(_ path: String) async throws {
        guard !fm.fileExists(atPath: path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: path])
        }
        fm.createFile(atPath: path, contents: Data())
    }

    public func createDirectory(_ path: String) async throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    public func rename(_ from: String, to: String) async throws {
        try fm.moveItem(atPath: from, toPath: to)
    }

    public func removeRecursively(_ path: String) async throws {
        // Local deletes go to the Trash so they can be undone in Finder.
        try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    public func upload(_ local: URL, to path: String, progress: TransferProgress?) async throws {
        try fm.copyItem(at: local, to: URL(fileURLWithPath: path))
        let s = (try? await size(of: path)) ?? 0
        progress?(s, s)
    }

    public func download(_ path: String, to local: URL, progress: TransferProgress?) async throws {
        try fm.copyItem(at: URL(fileURLWithPath: path), to: local)
        let s = (try? await size(of: path)) ?? 0
        progress?(s, s)
    }
}

/// A remote file system backed by one SFTP channel.
public final class SFTPFileSystem: FileSystemProvider, @unchecked Sendable {
    public let client: SFTPClient

    public init(client: SFTPClient) {
        self.client = client
    }

    public func homeDirectory() async throws -> String { try await client.realpath(".") }

    public func resolve(_ path: String) async throws -> String {
        if path == "~" { return try await client.realpath(".") }
        if path.hasPrefix("~/") {
            let home = try await client.realpath(".")
            return try await client.realpath(RemotePath.join(home, String(path.dropFirst(2))))
        }
        return try await client.realpath(path)
    }

    public func list(_ path: String) async throws -> [FileEntry] { try await client.listDirectory(path) }

    public func size(of path: String) async throws -> UInt64 { try await client.stat(path).size ?? 0 }

    public func stamp(of path: String) async throws -> FileStamp {
        let a = try await client.stat(path)
        return FileStamp(size: a.size, modified: a.modifyTime.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }

    public func readFile(_ path: String) async throws -> Data { try await client.readFile(path) }

    public func readHead(_ path: String, length: Int) async throws -> Data {
        let h = try await client.open(path, flags: .read)
        defer { Task { try? await self.client.closeHandle(h) } }
        return try await client.read(h, offset: 0, length: UInt32(length)) ?? Data()
    }

    public func writeFile(_ path: String, data: Data) async throws { try await client.writeFile(path, data: data) }

    public func createFile(_ path: String) async throws { try await client.createEmptyFile(path) }

    public func createDirectory(_ path: String) async throws { try await client.mkdir(path) }

    public func rename(_ from: String, to: String) async throws { try await client.rename(from, to: to) }

    public func removeRecursively(_ path: String) async throws { try await client.removeRecursively(path) }

    public func upload(_ local: URL, to path: String, progress: TransferProgress?) async throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir), isDir.boolValue {
            try await uploadDirectory(local, to: path, progress: progress)
        } else {
            try await client.upload(local, to: path, progress: progress)
        }
    }

    private func uploadDirectory(_ local: URL, to path: String, progress: TransferProgress?) async throws {
        try? await client.mkdir(path)
        let children = try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)
        for child in children {
            try await upload(child, to: RemotePath.join(path, child.lastPathComponent), progress: progress)
        }
    }

    public func download(_ path: String, to local: URL, progress: TransferProgress?) async throws {
        try await client.download(path, to: local, progress: progress)
    }
}
