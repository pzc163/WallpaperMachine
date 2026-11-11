import CryptoKit
import Darwin
import Foundation

/// Canonical, checksummed JSON records and bounded file IO for native creator stores.
enum CreatorPersistence {
    enum Failure: Error { case invalidRecord, unsupportedVersion, invalidPath, tooLarge, busy, missing, staleJob, staleValidation, incompleteBundle }

    private struct Record<T: Codable>: Codable {
        let schemaVersion: Int
        let payload: T
        let digest: String
    }

    final class Lease: @unchecked Sendable {
        private let descriptor: Int32
        init(_ url: URL, shared: Bool = false) throws {
            try directory(url.deletingLastPathComponent())
            descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw Failure.invalidPath }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  flock(descriptor, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
                close(descriptor)
                throw Failure.busy
            }
        }
        deinit { close(descriptor) }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func record<T: Codable>(_ value: T) throws -> Data {
        try encode(Record(schemaVersion: 1, payload: value, digest: hash(encode(value))))
    }

    static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        let record = try JSONDecoder().decode(Record<T>.self, from: data)
        guard record.schemaVersion == 1 else { throw Failure.unsupportedVersion }
        guard hash(try encode(record.payload)) == record.digest, try encode(record) == data else { throw Failure.invalidRecord }
        return record.payload
    }

    static func read<T: Codable>(_ type: T.Type, at url: URL) throws -> T {
        try decode(type, from: bytes(url, limit: 256 * 1024))
    }

    static func write<T: Codable>(_ value: T, to url: URL) throws {
        let data = try record(value)
        guard data.count <= 256 * 1024 else { throw Failure.tooLarge }
        try atomicWrite(data, to: url)
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 || errno != ENOENT
    }

    /// Check every existing component, including dangling links, before creating owned folders.
    static func directory(_ url: URL, create: Bool = false) throws {
        let canonical = url.standardizedFileURL
        guard canonical.isFileURL, canonical.path.hasPrefix("/") else { throw Failure.invalidPath }
        // Resolve the system /var and /tmp aliases, but never an application-owned link.
        let components = canonical.pathComponents
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            if current.path == "/var" || current.path == "/tmp" {
                current = current.resolvingSymlinksInPath()
                continue
            }
            var info = stat()
            if lstat(current.path, &info) != 0 {
                guard errno == ENOENT, create else { throw Failure.invalidPath }
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
                guard lstat(current.path, &info) == 0 else { throw Failure.invalidPath }
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalidPath }
        }
    }

    static func bytes(_ url: URL, limit: Int) throws -> Data {
        try directory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.missing }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= limit else { throw Failure.invalidPath }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Failure.tooLarge }
        return data
    }

    static func atomicWrite(_ data: Data, to url: URL, limit: Int = 1024 * 1024, beforeRename: () throws -> Void = {}) throws {
        guard limit > 0, limit <= CreatorMediaFile.maximumBundleBytes + 1024 * 1024, data.count <= limit else { throw Failure.tooLarge }
        let parent = url.deletingLastPathComponent()
        try directory(parent)
        if exists(url) { _ = try bytes(url, limit: limit) }
        let temporary = parent.appendingPathComponent(".pending-" + UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.invalidPath }
        defer { close(fd) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try beforeRename()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func directories(_ url: URL) throws -> [URL] {
        try directory(url)
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func uuidName(_ id: UUID) -> String { id.uuidString.lowercased() }
    static func isUUIDName(_ name: String) -> Bool { UUID(uuidString: name).map { uuidName($0) == name } == true }
    static func timestamp() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
}
