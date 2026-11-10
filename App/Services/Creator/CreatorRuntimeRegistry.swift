import Foundation

/// Native routing records live outside the wallpaper library, so a restore cannot silently downgrade policy.
actor CreatorRuntimeRegistry {
    struct Binding: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let wallpaperID: String
        let projectID: UUID
        let revisionID: UUID
        let bundleVersion: Int
        let bundleDigest: String
        let runtimePolicy: String
        let context: ValidationReport.Context
    }
    struct Document: Codable, Equatable, Sendable {
        var schemaVersion = 1
        var entries: [String: Binding] = [:]
    }
    let url: URL
    init(url: URL = ClientPaths.creatorRuntimeRegistryURL) { self.url = url }

    /// S1.1 can register an already installed legacy package. V2 publication needs S1.4's final evidence.
    func registerLegacy(projectID: UUID, revisionID: UUID, store: CreatorRevisionStore, installedDirectory: URL) async throws {
        let snapshot = try await store.snapshot(projectID: projectID, revisionID: revisionID)
        let report = try await store.report(projectID: projectID, revisionID: revisionID)
        guard snapshot.bundleVersion == 1, report.allowsPreview, report.bundleDigest == snapshot.digest else { throw CreatorPersistence.Failure.incompleteBundle }
        let installed = try CreatorBundleManifest.read(installedDirectory, expectedDigest: snapshot.digest)
        guard installed.wallpaperID == snapshot.wallpaperID else { throw CreatorPersistence.Failure.invalidRecord }
        try Task.checkCancellation()
        try CreatorPersistence.directory(url.deletingLastPathComponent(), create: true)
        let lock = try CreatorPersistence.Lease(url.appendingPathExtension("lock"))
        defer { withExtendedLifetime(lock) {} }
        var document = try Self.read(at: url)
        document.entries[snapshot.wallpaperID] = Binding(schemaVersion: 1, wallpaperID: snapshot.wallpaperID,
            projectID: projectID, revisionID: revisionID, bundleVersion: 1, bundleDigest: snapshot.digest,
            runtimePolicy: "trustedTemplateV1", context: report.context)
        try Self.validate(document)
        try CreatorPersistence.write(document, to: url)
    }

    func bindings() throws -> [String: Binding] { try Self.read(at: url).entries }

    nonisolated static func isCreatorID(_ id: String) -> Bool {
        // Even malformed reserved identifiers must never fall through to the compatibility host.
        id.hasPrefix(CreatorTemplate.idPrefix) || id.hasPrefix("ai-")
    }
    nonisolated static func isCandidate(_ directory: URL) -> Bool {
        isCreatorID(directory.lastPathComponent) || CreatorPersistence.exists(directory.appendingPathComponent(CreatorTemplate.metadataFile))
    }
    nonisolated static func read(at url: URL) throws -> Document {
        guard CreatorPersistence.exists(url) else { return Document() }
        let document = try CreatorPersistence.read(Document.self, at: url)
        try validate(document)
        return document
    }
    nonisolated static func validate(_ document: Document) throws {
        guard document.schemaVersion == 1, document.entries.count <= 1000 else { throw CreatorPersistence.Failure.unsupportedVersion }
        for (key, binding) in document.entries {
            try binding.context.validate()
            guard key == binding.wallpaperID, binding.schemaVersion == 1, binding.bundleVersion == 1,
                  key == CreatorTemplate.idPrefix + CreatorPersistence.uuidName(binding.projectID),
                  binding.runtimePolicy == "trustedTemplateV1", CreatorPersistence.validDigest(binding.bundleDigest)
            else { throw CreatorPersistence.Failure.unsupportedVersion }
        }
    }
    nonisolated static func readForPlayback(_ directory: URL, expectedDigest: String? = nil,
                                           registryURL: URL = ClientPaths.creatorRuntimeRegistryURL,
                                           context: ValidationReport.Context = .current) throws -> CreatorDraftStore.Snapshot {
        let document = try read(at: registryURL)
        let snapshot = try CreatorBundleManifest.read(directory, expectedDigest: expectedDigest)
        // A syntactically sealed v2 package still lacks S1.4's final publication validation.
        guard snapshot.bundleVersion == 1 else { throw CreatorPersistence.Failure.incompleteBundle }
        if let binding = document.entries[directory.lastPathComponent] {
            guard binding.bundleDigest == snapshot.digest, binding.projectID == snapshot.specification.projectID,
                  binding.context == context else { throw CreatorPersistence.Failure.staleValidation }
        }
        return snapshot
    }
}
