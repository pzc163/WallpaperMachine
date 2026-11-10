import Darwin
import Foundation

/// Owns drafts outside the installed library and snapshots only byte-verified template bundles.
actor CreatorDraftStore {
    struct Snapshot: Sendable {
        let specification: CreatorTemplate.Specification
        let files: [String: Data]
        let digest: String
        var wallpaperID: String { specification.wallpaperID }
    }

    let root: URL

    init(root: URL = ClientPaths.storageURL.appendingPathComponent("Creator/Drafts", isDirectory: true)) {
        self.root = root
    }

    func create(_ specification: CreatorTemplate.Specification) throws -> URL {
        try Task.checkCancellation()
        let files = try CreatorTemplate.files(for: specification)
        let directory = root.appendingPathComponent(specification.wallpaperID, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw CreatorTemplate.Failure.busy }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent(".pending-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staged) }
        try Self.write(files, to: staged)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staged, to: directory)
        return directory
    }

    func snapshot(_ directory: URL, expectedDigest: String? = nil) throws -> Snapshot {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = directory.standardizedFileURL
        guard candidate.deletingLastPathComponent().resolvingSymlinksInPath() == base else {
            throw CreatorTemplate.Failure.invalidPath
        }
        return try Self.read(directory, expectedDigest: expectedDigest)
    }

    /// Also used on library copies; the in-memory snapshot never rereads files while rendering.
    nonisolated static func read(_ directory: URL, expectedDigest: String? = nil) throws -> Snapshot {
        try Task.checkCancellation()
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CreatorTemplate.Failure.invalidPath
        }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let expectedNames: Set<String> = ["project.json", "index.html", CreatorTemplate.metadataFile]
        guard Set(urls.map(\.lastPathComponent)) == expectedNames else { throw CreatorTemplate.Failure.invalidBundle }
        var files: [String: Data] = [:]
        for url in urls {
            try Task.checkCancellation()
            // O_NOFOLLOW and fstat apply to the same opened object, not a separate path check.
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw CreatorTemplate.Failure.invalidPath }
            defer { close(descriptor) }
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, info.st_size > 0, info.st_size <= 256 * 1024 else {
                throw CreatorTemplate.Failure.invalidBundle
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let data = try handle.read(upToCount: 256 * 1024 + 1) ?? Data()
            guard data.count <= 256 * 1024 else { throw CreatorTemplate.Failure.invalidBundle }
            files[url.lastPathComponent] = data
        }
        let spec = try JSONDecoder().decode(CreatorTemplate.Specification.self, from: files[CreatorTemplate.metadataFile]!)
        guard directory.lastPathComponent == spec.wallpaperID else { throw CreatorTemplate.Failure.invalidPath }
        guard try CreatorTemplate.files(for: spec) == files else { throw CreatorTemplate.Failure.changedContent }
        let digest = CreatorTemplate.digest(files)
        if let expectedDigest, expectedDigest != digest { throw CreatorTemplate.Failure.changedContent }
        return Snapshot(specification: spec, files: files, digest: digest)
    }

    nonisolated static func write(_ files: [String: Data], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for (name, data) in files {
            guard ["index.html", "project.json", CreatorTemplate.metadataFile].contains(name) else {
                throw CreatorTemplate.Failure.invalidPath
            }
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }
}
