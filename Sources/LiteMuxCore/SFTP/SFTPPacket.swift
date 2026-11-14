import Foundation

/// SFTP protocol version 3 (draft-ietf-secsh-filexfer-02), as spoken by OpenSSH.
public enum SFTPMessage: UInt8, Sendable {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case symlink = 20
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attrs = 105
    case extended = 200
    case extendedReply = 201
}

public struct SFTPOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let read = SFTPOpenFlags(rawValue: 0x01)
    public static let write = SFTPOpenFlags(rawValue: 0x02)
    public static let append = SFTPOpenFlags(rawValue: 0x04)
    public static let create = SFTPOpenFlags(rawValue: 0x08)
    public static let truncate = SFTPOpenFlags(rawValue: 0x10)
    public static let exclusive = SFTPOpenFlags(rawValue: 0x20)
}

public enum SFTPStatusCode: UInt32, Sendable {
    case ok = 0, eof, noSuchFile, permissionDenied, failure, badMessage, noConnection, connectionLost, unsupported
}

/// File attributes; only the fields that were present on the wire are set.
public struct SFTPAttributes: Equatable, Sendable {
    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    public var permissions: UInt32?
    public var accessTime: UInt32?
    public var modifyTime: UInt32?

    public init(size: UInt64? = nil, uid: UInt32? = nil, gid: UInt32? = nil,
                permissions: UInt32? = nil, accessTime: UInt32? = nil, modifyTime: UInt32? = nil) {
        self.size = size
        self.uid = uid
        self.gid = gid
        self.permissions = permissions
        self.accessTime = accessTime
        self.modifyTime = modifyTime
    }

    static let flagSize: UInt32 = 0x01
    static let flagUIDGID: UInt32 = 0x02
    static let flagPermissions: UInt32 = 0x04
    static let flagACModTime: UInt32 = 0x08
    static let flagExtended: UInt32 = 0x8000_0000

    public var fileType: FileEntry.Kind {
        guard let p = permissions else { return .file }
        switch p & 0o170000 {
        case 0o040000: return .directory
        case 0o120000: return .symlink
        case 0o100000: return .file
        default: return .other
        }
    }

    public var modificationDate: Date? {
        modifyTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

// MARK: - Wire encoding

public struct SFTPWriter {
    public private(set) var data = Data()
    public init() {}

    public mutating func byte(_ v: UInt8) { data.append(v) }
    public mutating func uint32(_ v: UInt32) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
    public mutating func uint64(_ v: UInt64) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
    public mutating func bytes(_ d: Data) {
        uint32(UInt32(d.count))
        data.append(d)
    }
    public mutating func string(_ s: String) { bytes(Data(s.utf8)) }

    public mutating func attributes(_ a: SFTPAttributes) {
        var flags: UInt32 = 0
        if a.size != nil { flags |= SFTPAttributes.flagSize }
        if a.uid != nil && a.gid != nil { flags |= SFTPAttributes.flagUIDGID }
        if a.permissions != nil { flags |= SFTPAttributes.flagPermissions }
        if a.accessTime != nil && a.modifyTime != nil { flags |= SFTPAttributes.flagACModTime }
        uint32(flags)
        if let s = a.size { uint64(s) }
        if let u = a.uid, let g = a.gid { uint32(u); uint32(g) }
        if let p = a.permissions { uint32(p) }
        if let at = a.accessTime, let mt = a.modifyTime { uint32(at); uint32(mt) }
    }

    /// Frames `type + payload` with the 4-byte length prefix.
    public static func packet(_ type: SFTPMessage, _ build: (inout SFTPWriter) -> Void) -> Data {
        var body = SFTPWriter()
        body.byte(type.rawValue)
        build(&body)
        var framed = SFTPWriter()
        framed.uint32(UInt32(body.data.count))
        framed.data.append(body.data)
        return framed.data
    }
}

public enum SFTPDecodeError: Error, Sendable {
    case truncated
    case badMessage
}

public struct SFTPReader {
    let data: Data
    public private(set) var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }

    public mutating func byte() throws -> UInt8 {
        guard remaining >= 1 else { throw SFTPDecodeError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    public mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTPDecodeError.truncated }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(data[offset + i]) }
        offset += 4
        return v
    }

    public mutating func uint64() throws -> UInt64 {
        let hi = UInt64(try uint32())
        let lo = UInt64(try uint32())
        return (hi << 32) | lo
    }

    public mutating func bytes() throws -> Data {
        let n = Int(try uint32())
        guard remaining >= n else { throw SFTPDecodeError.truncated }
        defer { offset += n }
        return data.subdata(in: offset..<(offset + n))
    }

    public mutating func string() throws -> String {
        let d = try bytes()
        return String(decoding: d, as: UTF8.self)
    }

    public mutating func attributes() throws -> SFTPAttributes {
        let flags = try uint32()
        var a = SFTPAttributes()
        if flags & SFTPAttributes.flagSize != 0 { a.size = try uint64() }
        if flags & SFTPAttributes.flagUIDGID != 0 { a.uid = try uint32(); a.gid = try uint32() }
        if flags & SFTPAttributes.flagPermissions != 0 { a.permissions = try uint32() }
        if flags & SFTPAttributes.flagACModTime != 0 { a.accessTime = try uint32(); a.modifyTime = try uint32() }
        if flags & SFTPAttributes.flagExtended != 0 {
            let count = try uint32()
            for _ in 0..<count { _ = try string(); _ = try string() }
        }
        return a
    }
}

/// Incrementally splits a byte stream into complete SFTP packets.
public struct SFTPFramer {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ chunk: Data) { buffer.append(chunk) }

    /// Returns the next packet body (type byte onwards) if fully buffered.
    public mutating func next() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let s = buffer.startIndex
        let length = Int(UInt32(buffer[s]) << 24 | UInt32(buffer[s + 1]) << 16 | UInt32(buffer[s + 2]) << 8 | UInt32(buffer[s + 3]))
        guard length > 0, length < 64 * 1024 * 1024 else { throw SFTPDecodeError.badMessage }
        guard buffer.count >= 4 + length else { return nil }
        let body = buffer.subdata(in: (s + 4)..<(s + 4 + length))
        buffer.removeSubrange(s..<(s + 4 + length))
        if buffer.isEmpty { buffer = Data() }
        return body
    }
}
