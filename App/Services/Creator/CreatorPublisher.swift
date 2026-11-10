import Darwin
import Foundation

/// Publishes verified templates through the real importer and rolls back unconfirmed transactions.
actor CreatorPublisher {
    enum Checkpoint: Sendable { case afterImport, afterRegistry, afterConfirmation }
    struct Ticket: Equatable, Sendable { let id: UUID; let wallpaperID: String; let digest: String }
    private struct Journal: Codable {
        enum Phase: String, Codable { case prepared, installed, confirmed }
        let id: UUID
        let wallpaperID: String
        let digest: String
        let previousDigest: String?
        var phase: Phase
        var binding: CreatorRuntimeRegistry.Binding? = nil
        var previousBinding: CreatorRuntimeRegistry.Binding? = nil
    }

    private let root: URL
    private let library: URL
    private let importer: WallpaperImportService
    private let registry: CreatorRuntimeRegistry
    private let checkpoint: @Sendable (Checkpoint) throws -> Void
    private var active: URL { root.appendingPathComponent("active", isDirectory: true) }
    private var journalURL: URL { active.appendingPathComponent("journal.json") }

    init(root: URL = ClientPaths.storageURL.appendingPathComponent("Creator/Publication", isDirectory: true),
         library: URL = ClientPaths.libraryURL, importer: WallpaperImportService = WallpaperImportService(),
         registry: CreatorRuntimeRegistry = CreatorRuntimeRegistry(),
         checkpoint: @escaping @Sendable (Checkpoint) throws -> Void = { _ in }) {
        self.root = root
        self.library = library
        self.importer = importer
        self.registry = registry
        self.checkpoint = checkpoint
    }

    func publish(projectID: UUID, revisionID: UUID, store: CreatorRevisionStore,
                 verifyInstalled: @escaping @Sendable (URL) async throws -> Void = { _ in }) async throws -> URL {
        var owner: CreatorPersistence.Lease? = try ownPublication()
        defer { withExtendedLifetime(owner) {} }
        let expected = try await store.publication(projectID: projectID, revisionID: revisionID).binding
        let ticket = try await prepare(projectID: projectID, revisionID: revisionID, store: store)
        do {
            let installed = try await install(ticket)
            try await confirm(ticket) { url in
                try await verifyInstalled(url)
                let current = try await store.publication(projectID: projectID, revisionID: revisionID)
                guard current.binding == expected else { throw CreatorPersistence.Failure.staleValidation }
            }
            return installed
        } catch {
            let failure = error
            owner = nil
            try await Task.detached { try await self.recover() }.value
            throw failure
        }
    }

    func prepare(projectID: UUID, revisionID: UUID, store: CreatorRevisionStore) async throws -> Ticket {
        let publication = try await store.publication(projectID: projectID, revisionID: revisionID)
        let before = try await registry.bindings()[publication.snapshot.wallpaperID]
        return try prepareSnapshot(publication.snapshot, binding: publication.binding, previousBinding: before)
    }

    func publish(_ directory: URL, expectedDigest: String,
                 verifyInstalled: @escaping @Sendable (URL) async throws -> Void) async throws -> URL {
        var owner: CreatorPersistence.Lease? = try ownPublication()
        defer { withExtendedLifetime(owner) {} }
        let ticket = try prepare(directory, expectedDigest: expectedDigest)
        do {
            let installed = try await install(ticket)
            try await confirm(ticket, verifyInstalled: verifyInstalled)
            return installed
        } catch {
            let failure = error
            owner = nil
            // Restoration must finish even if the generating/preview task was cancelled.
            try await Task.detached { try await self.recover() }.value
            throw failure
        }
    }

    /// Stage boundaries are explicit so a restarted owner can recover even between import and confirmation.
    func prepare(_ directory: URL, expectedDigest: String) throws -> Ticket {
        let snapshot = try CreatorDraftStore.read(directory, expectedDigest: expectedDigest)
        guard snapshot.bundleVersion == 1 else { throw CreatorPersistence.Failure.incompleteBundle }
        return try prepareSnapshot(snapshot)
    }

    private func prepareSnapshot(_ snapshot: CreatorDraftStore.Snapshot, binding: CreatorRuntimeRegistry.Binding? = nil,
                                 previousBinding: CreatorRuntimeRegistry.Binding? = nil) throws -> Ticket {
        let descriptor = try lock()
        defer { close(descriptor) }
        guard !FileManager.default.fileExists(atPath: active.path) else { throw CreatorTemplate.Failure.busy }
        let installed = library.appendingPathComponent(snapshot.wallpaperID, isDirectory: true)
        let previous = FileManager.default.fileExists(atPath: installed.path) ? try CreatorDraftStore.read(installed) : nil
        if let binding {
            try CreatorRuntimeRegistry.validateBinding(binding, snapshot: snapshot)
            guard (previous == nil) == (previousBinding == nil) else { throw CreatorPersistence.Failure.staleValidation }
            if let previous, let previousBinding { try CreatorRuntimeRegistry.validateBinding(previousBinding, snapshot: previous) }
        }
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: false)
        do {
            for name in ["candidate", "previous"] {
                try FileManager.default.createDirectory(at: active.appendingPathComponent(name), withIntermediateDirectories: false)
            }
            try writeBundle(snapshot, to: bundle("candidate", id: snapshot.wallpaperID))
            if let previous { try writeBundle(previous, to: bundle("previous", id: snapshot.wallpaperID)) }
            try Task.checkCancellation()
            let journal = Journal(id: UUID(), wallpaperID: snapshot.wallpaperID, digest: snapshot.digest,
                                  previousDigest: previous?.digest, phase: .prepared, binding: binding, previousBinding: previousBinding)
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
        if journal.binding != nil {
            guard try await registry.bindings()[journal.wallpaperID] == journal.previousBinding else { throw CreatorPersistence.Failure.staleValidation }
        }
        let report = try await importer.importItems([source], into: library, duplicates: .replaceChanged,
                                                     creatorPermit: journal.binding, progress: { _ in })
        guard report.failures.isEmpty, !report.cancelled else { throw CreatorTemplate.Failure.invalidTransaction }
        _ = try CreatorDraftStore.read(destination, expectedDigest: journal.digest)
        try checkpoint(.afterImport)
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
        if let binding = journal.binding {
            let snapshot = try CreatorDraftStore.read(destination, expectedDigest: journal.digest)
            try CreatorRuntimeRegistry.validateBinding(binding, snapshot: snapshot)
            try await registry.replace(journal.wallpaperID, expected: journal.previousBinding, with: binding)
            try checkpoint(.afterRegistry)
            _ = try CreatorRuntimeRegistry.readForPlayback(destination, expectedDigest: journal.digest, registryURL: registry.url)
        }
        try await verifyInstalled(destination)
        try Task.checkCancellation()
        _ = try CreatorDraftStore.read(destination, expectedDigest: journal.digest)
        if let binding = journal.binding {
            guard try await registry.bindings()[journal.wallpaperID] == binding else { throw CreatorPersistence.Failure.staleValidation }
        }
        journal.phase = .confirmed
        try write(journal)
        try checkpoint(.afterConfirmation)
        try FileManager.default.removeItem(at: active)
    }

    /// Call before accepting a new creation session. Unrelated or edited library bytes are never overwritten.
    func recover() async throws {
        let owner = try ownPublication()
        defer { withExtendedLifetime(owner) {} }
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
        let currentBinding = journal.binding == nil ? nil : try await registry.bindings()[journal.wallpaperID]
        if journal.binding != nil {
            guard currentBinding == journal.binding || currentBinding == journal.previousBinding else { throw CreatorPersistence.Failure.staleValidation }
        }
        if journal.phase == .confirmed {
            guard current?.digest == journal.digest else { throw CreatorTemplate.Failure.changedContent }
            if let binding = journal.binding {
                guard currentBinding == binding else { throw CreatorPersistence.Failure.staleValidation }
                _ = try CreatorRuntimeRegistry.readForPlayback(destination, registryURL: registry.url)
            }
        } else {
            guard current == nil || current?.digest == journal.digest || current?.digest == journal.previousDigest else {
                throw CreatorTemplate.Failure.changedContent
            }
            if let previousDigest = journal.previousDigest {
                let previous = bundle("previous", id: journal.wallpaperID)
                _ = try CreatorDraftStore.read(previous, expectedDigest: previousDigest)
                let report = try await importer.importItems([previous], into: library, duplicates: .replaceChanged,
                                                             creatorPermit: journal.previousBinding, progress: { _ in })
                guard report.failures.isEmpty, !report.cancelled else { throw CreatorTemplate.Failure.invalidTransaction }
                _ = try CreatorDraftStore.read(destination, expectedDigest: previousDigest)
            } else if current != nil {
                try FileManager.default.removeItem(at: destination)
            }
            if journal.binding != nil, currentBinding != journal.previousBinding {
                try await registry.replace(journal.wallpaperID, expected: currentBinding, with: journal.previousBinding)
            }
        }
        try FileManager.default.removeItem(at: active)
    }

    func recover(store: CreatorRevisionStore) async throws {
        try await recover()
        for binding in try await registry.bindings().values where binding.bundleVersion == 2 {
            _ = try CreatorRuntimeRegistry.readForPlayback(library.appendingPathComponent(binding.wallpaperID), registryURL: registry.url)
            try await store.recordPublished(binding)
        }
    }

    private func ownPublication() throws -> CreatorPersistence.Lease {
        try CreatorPersistence.directory(root, create: true)
        return try CreatorPersistence.Lease(root.appendingPathComponent(".owner"))
    }

    private func bundle(_ side: String, id: String) -> URL {
        active.appendingPathComponent(side, isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    private func writeBundle(_ snapshot: CreatorDraftStore.Snapshot, to directory: URL) throws {
        if snapshot.bundleVersion == 1 { try CreatorDraftStore.write(snapshot.files, to: directory); return }
        guard snapshot.manifest?.packaging == .sealed,
              Set(snapshot.files.keys) == ["creator.json", "project.json", "index.html", "preview.jpg"]
        else { throw CreatorPersistence.Failure.incompleteBundle }
        try CreatorPersistence.directory(directory, create: true)
        for (name, data) in snapshot.files {
            try Task.checkCancellation()
            try CreatorPersistence.atomicWrite(data, to: directory.appendingPathComponent(name))
        }
        _ = try CreatorBundleManifest.read(directory, expectedDigest: snapshot.digest)
    }

    private func write(_ journal: Journal) throws {
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }

    private func read(_ ticket: Ticket? = nil) throws -> Journal {
        let data = try Data(contentsOf: journalURL)
        guard data.count < 16_384 else { throw CreatorTemplate.Failure.invalidTransaction }
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        let prefix = journal.binding == nil ? CreatorTemplate.idPrefix : "ai-"
        guard journal.wallpaperID.hasPrefix(prefix),
              let id = UUID(uuidString: String(journal.wallpaperID.dropFirst(prefix.count))),
              journal.wallpaperID == prefix + id.uuidString.lowercased(),
              CreatorPersistence.validDigest(journal.digest), journal.previousDigest.map(CreatorPersistence.validDigest) ?? true,
              ticket == nil || ticket == Ticket(id: journal.id, wallpaperID: journal.wallpaperID, digest: journal.digest)
        else { throw CreatorTemplate.Failure.invalidTransaction }
        if let binding = journal.binding {
            try CreatorRuntimeRegistry.validate(.init(entries: [journal.wallpaperID: binding]))
            guard binding.bundleVersion == 2, binding.wallpaperID == journal.wallpaperID, binding.bundleDigest == journal.digest,
                  (journal.previousDigest == nil) == (journal.previousBinding == nil)
            else { throw CreatorTemplate.Failure.invalidTransaction }
            if let previous = journal.previousBinding {
                try CreatorRuntimeRegistry.validate(.init(entries: [journal.wallpaperID: previous]))
                guard previous.bundleDigest == journal.previousDigest else { throw CreatorTemplate.Failure.invalidTransaction }
            }
        } else if journal.previousBinding != nil { throw CreatorTemplate.Failure.invalidTransaction }
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
