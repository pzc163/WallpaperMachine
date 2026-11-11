import Darwin
import Foundation

/// Owns drafts outside the installed library and snapshots only byte-verified template bundles.
actor CreatorDraftStore {
    struct Snapshot: Sendable {
        let specification: CreatorTemplate.Specification
        let files: [String: Data]
        let digest: String
        var manifest: CreatorBundleManifest? = nil
        var bundleVersion: Int { manifest?.bundleVersion ?? 1 }
        var wallpaperID: String { manifest == nil ? specification.wallpaperID : "ai-" + specification.projectID.uuidString.lowercased() }
        var renderDigest: String {
            get throws {
                if manifest == nil { return digest }
                return CreatorTemplate.digest(try CreatorBundleManifest.files(for: specification, presentation: manifest?.presentation, source: specification.kind == .code ? files["index.html"] : nil))
            }
        }
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
        try CreatorBundleManifest.read(directory, expectedDigest: expectedDigest)
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
