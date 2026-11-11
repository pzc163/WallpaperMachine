import Foundation

/// Until a backup format can atomically carry the runtime registry, fail closed instead of
/// exporting/moving only Library. The durable marker fences a concurrent first Creator write.
enum CreatorStorageBoundary {
    struct Failure: LocalizedError {
        var errorDescription: String? { String(localized: "AI projects and policies cannot be moved or backed up in this version. Keep the current storage location.") }
    }
    static func lease(support: URL) throws -> CreatorPersistence.Lease {
        try CreatorPersistence.directory(support, create: true)
        return try CreatorPersistence.Lease(support.appendingPathComponent(".CreatorStorageBoundary.lock"))
    }
    static func requirePortable(support: URL, storage: URL) throws {
        let manager = FileManager.default
        for path in ["CreatorSettings.json", "CreatorRuntimeRegistry.json", ".CreatorWorkspacePresent"] {
            if CreatorPersistence.exists(support.appendingPathComponent(path)) { throw Failure() }
        }
        if try containsCreatorData(storage.appendingPathComponent("Creator")) { throw Failure() }
        let projects = storage.appendingPathComponent("Creator/Projects")
        if CreatorPersistence.exists(projects), !(try CreatorPersistence.directories(projects)).isEmpty { throw Failure() }
        let publication = storage.appendingPathComponent("Creator/Publication/active")
        if CreatorPersistence.exists(publication) { throw Failure() }
        let library = storage.appendingPathComponent("Library")
        if manager.fileExists(atPath: library.path) {
            for directory in try CreatorPersistence.directories(library) where CreatorRuntimeRegistry.isCandidate(directory) { throw Failure() }
        }
    }
    private static func containsCreatorData(_ root: URL, depth: Int = 0) throws -> Bool {
        guard CreatorPersistence.exists(root) else { return false }
        guard depth < 4 else { return true }
        for entry in try CreatorPersistence.directories(root) {
            if [".lock", ".owner"].contains(entry.lastPathComponent) { continue }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { return true }
            if values.isDirectory == true {
                if try containsCreatorData(entry, depth: depth + 1) { return true }
            } else { return true }
        }
        return false
    }
    static func beginCreatorWrite(support: URL = ClientPaths.supportURL) throws {
        let owner = try lease(support: support)
        defer { withExtendedLifetime(owner) {} }
        for name in [StorageMoveService.pendingFileName, WallpaperBackupService.pendingDirectoryName, WallpaperBackupService.transactionDirectoryName] {
            if CreatorPersistence.exists(support.appendingPathComponent(name)) { throw Failure() }
        }
        try CreatorPersistence.atomicWrite(Data("1".utf8), to: support.appendingPathComponent(".CreatorWorkspacePresent"))
    }
    static func requirePortablePackage(_ package: URL) throws {
        let library = package.appendingPathComponent("data/Library")
        guard CreatorPersistence.exists(library) else { return }
        for directory in try CreatorPersistence.directories(library) where CreatorRuntimeRegistry.isCandidate(directory) { throw Failure() }
    }
}
