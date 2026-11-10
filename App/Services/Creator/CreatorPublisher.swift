import Darwin
import Foundation

/// Publishes verified templates through the real importer and rolls back unconfirmed transactions.
actor CreatorPublisher {
    struct Ticket: Equatable, Sendable { let id: UUID; let wallpaperID: String; let digest: String }
    private struct Journal: Codable {
        enum Phase: String, Codable { case prepared, installed, confirmed }
        let id: UUID
        let wallpaperID: String
        let digest: String
        let previousDigest: String?
        var phase: Phase
    }

    private let root: URL
    private let library: URL
    private let importer: WallpaperImportService
    private var active: URL { root.appendingPathComponent("active", isDirectory: true) }
    private var journalURL: URL { active.appendingPathComponent("journal.json") }

    init(root: URL = ClientPaths.storageURL.appendingPathComponent("Creator/Publication", isDirectory: true),
         library: URL = ClientPaths.libraryURL, importer: WallpaperImportService = WallpaperImportService()) {
        self.root = root
        self.library = library
        self.importer = importer
    }

    func publish(_ directory: URL, expectedDigest: String,
                 verifyInstalled: @escaping @Sendable (URL) async throws -> Void) async throws -> URL {
        let ticket = try prepare(directory, expectedDigest: expectedDigest)
        do {
            let installed = try await install(ticket)
            try await confirm(ticket, verifyInstalled: verifyInstalled)
            return installed
        } catch {
            let failure = error
            // Restoration must finish even if the generating/preview task was cancelled.
            try await Task.detached { try await self.recover() }.value
            throw failure
        }
    }

    /// Stage boundaries are explicit so a restarted owner can recover even between import and confirmation.
    func prepare(_ directory: URL, expectedDigest: String) throws -> Ticket {
        let descriptor = try lock()
        defer { close(descriptor) }
        guard !FileManager.default.fileExists(atPath: active.path) else { throw CreatorTemplate.Failure.busy }
        let snapshot = try CreatorDraftStore.read(directory, expectedDigest: expectedDigest)
        guard snapshot.bundleVersion == 1 else { throw CreatorPersistence.Failure.incompleteBundle }
        let installed = library.appendingPathComponent(snapshot.wallpaperID, isDirectory: true)
        let previous = FileManager.default.fileExists(atPath: installed.path) ? try CreatorDraftStore.read(installed) : nil
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: false)
        do {
            for name in ["candidate", "previous"] {
                try FileManager.default.createDirectory(at: active.appendingPathComponent(name), withIntermediateDirectories: false)
            }
            try CreatorDraftStore.write(snapshot.files, to: bundle("candidate", id: snapshot.wallpaperID))
            if let previous { try CreatorDraftStore.write(previous.files, to: bundle("previous", id: snapshot.wallpaperID)) }
            try Task.checkCancellation()
            let journal = Journal(id: UUID(), wallpaperID: snapshot.wallpaperID, digest: snapshot.digest,
                                  previousDigest: previous?.digest, phase: .prepared)
            try write(journal)
            return Ticket(id: journal.id, wallpaperID: journal.wallpaperID, digest: journal.digest)
        } catch {
            try? FileManager.default.removeItem(at: active)
            throw error
        }
    }

    func install(_ ticket: Ticket) async throws -> URL {
        let descriptor = try lock()
        defer { close(descriptor) }
        var journal = try read(ticket)
        guard journal.phase == .prepared else { throw CreatorTemplate.Failure.invalidTransaction }
        let source = bundle("candidate", id: journal.wallpaperID)
        _ = try CreatorDraftStore.read(source, expectedDigest: journal.digest)
        let destination = library.appendingPathComponent(journal.wallpaperID, isDirectory: true)
        let current = FileManager.default.fileExists(atPath: destination.path) ? try CreatorDraftStore.read(destination) : nil
        guard current?.digest == journal.previousDigest else { throw CreatorTemplate.Failure.changedContent }
        let report = try await importer.importItems([source], into: library, duplicates: .replaceChanged, progress: { _ in })
        guard report.failures.isEmpty, !report.cancelled else { throw CreatorTemplate.Failure.invalidTransaction }
        _ = try CreatorDraftStore.read(destination, expectedDigest: journal.digest)
        journal.phase = .installed
        try write(journal)
        return destination
    }

    func confirm(_ ticket: Ticket, verifyInstalled: @Sendable (URL) async throws -> Void) async throws {
        let descriptor = try lock()
        defer { close(descriptor) }
        var journal = try read(ticket)
        guard journal.phase == .installed else { throw CreatorTemplate.Failure.invalidTransaction }
        let destination = library.appendingPathComponent(journal.wallpaperID, isDirectory: true)
        try await verifyInstalled(destination)
        try Task.checkCancellation()
        _ = try CreatorDraftStore.read(destination, expectedDigest: journal.digest)
        journal.phase = .confirmed
        try write(journal)
        try FileManager.default.removeItem(at: active)
    }

    /// Call before accepting a new creation session. Unrelated or edited library bytes are never overwritten.
    func recover() async throws {
        let descriptor = try lock()
        defer { close(descriptor) }
        guard FileManager.default.fileExists(atPath: active.path) else { return }
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            // Import cannot start until a complete journal has been written.
            try FileManager.default.removeItem(at: active)
            return
        }
        let journal = try read()
        let destination = library.appendingPathComponent(journal.wallpaperID, isDirectory: true)
        let current = FileManager.default.fileExists(atPath: destination.path) ? try CreatorDraftStore.read(destination) : nil
        if journal.phase == .confirmed {
            guard current?.digest == journal.digest else { throw CreatorTemplate.Failure.changedContent }
        } else {
            guard current == nil || current?.digest == journal.digest || current?.digest == journal.previousDigest else {
                throw CreatorTemplate.Failure.changedContent
            }
            if let previousDigest = journal.previousDigest {
                let previous = bundle("previous", id: journal.wallpaperID)
                _ = try CreatorDraftStore.read(previous, expectedDigest: previousDigest)
                let report = try await importer.importItems([previous], into: library, duplicates: .replaceChanged, progress: { _ in })
                guard report.failures.isEmpty, !report.cancelled else { throw CreatorTemplate.Failure.invalidTransaction }
                _ = try CreatorDraftStore.read(destination, expectedDigest: previousDigest)
            } else if current != nil {
                try FileManager.default.removeItem(at: destination)
            }
        }
        try FileManager.default.removeItem(at: active)
    }

    private func bundle(_ side: String, id: String) -> URL {
        active.appendingPathComponent(side, isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    private func write(_ journal: Journal) throws {
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }

    private func read(_ ticket: Ticket? = nil) throws -> Journal {
        let data = try Data(contentsOf: journalURL)
        guard data.count < 16_384 else { throw CreatorTemplate.Failure.invalidTransaction }
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        guard journal.wallpaperID.hasPrefix(CreatorTemplate.idPrefix),
              let id = UUID(uuidString: String(journal.wallpaperID.dropFirst(CreatorTemplate.idPrefix.count))),
              journal.wallpaperID == CreatorTemplate.idPrefix + id.uuidString.lowercased(),
              journal.digest.count == 64,
              ticket == nil || ticket == Ticket(id: journal.id, wallpaperID: journal.wallpaperID, digest: journal.digest)
        else { throw CreatorTemplate.Failure.invalidTransaction }
        return journal
    }

    private func lock() throws -> Int32 {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CreatorTemplate.Failure.invalidPath }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CreatorTemplate.Failure.busy
        }
        return descriptor
    }
}
