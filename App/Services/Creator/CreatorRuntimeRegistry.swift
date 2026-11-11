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
        var report: ValidationReport? = nil
    }
    struct Document: Codable, Equatable, Sendable {
        var schemaVersion = 1
        var entries: [String: Binding] = [:]
    }
    nonisolated let url: URL
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

    /// Compare-and-swap lets publication restore exactly the prior binding without overwriting another writer.
    func replace(_ id: String, expected: Binding?, with replacement: Binding?) throws {
        try CreatorPersistence.directory(url.deletingLastPathComponent(), create: true)
        let lock = try CreatorPersistence.Lease(url.appendingPathExtension("lock"))
        defer { withExtendedLifetime(lock) {} }
        var document = try Self.read(at: url)
        guard document.entries[id] == expected else { throw CreatorPersistence.Failure.staleValidation }
        document.entries[id] = replacement
        try Self.validate(document)
        try CreatorPersistence.write(document, to: url)
    }

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
            guard key == binding.wallpaperID, binding.schemaVersion == 1, [1, 2, 3].contains(binding.bundleVersion),
                  key == (binding.bundleVersion == 1 ? CreatorTemplate.idPrefix : "ai-") + CreatorPersistence.uuidName(binding.projectID),
                  ["trustedTemplateV1", "generatedOfflineV1"].contains(binding.runtimePolicy),
                  binding.bundleVersion != 1 || binding.runtimePolicy == "trustedTemplateV1", CreatorPersistence.validDigest(binding.bundleDigest)
            else { throw CreatorPersistence.Failure.unsupportedVersion }
            if binding.bundleVersion == 1 {
                guard binding.report == nil else { throw CreatorPersistence.Failure.invalidRecord }
            } else {
                guard let report = binding.report, report.schemaVersion == 1, report.allowsPublication,
                      report.projectID == binding.projectID, report.revisionID == binding.revisionID,
                      report.bundleDigest == binding.bundleDigest, report.context == binding.context,
                      report.context.testProfile == (binding.runtimePolicy == "generatedOfflineV1" ? "code-runtime-v1" : "template-runtime-v1"),
                      CreatorPersistence.validDigest(report.projectIdentityDigest), CreatorPersistence.validDigest(report.revisionDigest),
                      CreatorPersistence.validDigest(report.renderDigest), report.validatedAt >= 0
                else { throw CreatorPersistence.Failure.staleValidation }
            }
        }
    }

    nonisolated static func validateBinding(_ binding: Binding, snapshot: CreatorDraftStore.Snapshot,
                                            context: ValidationReport.Context = .current) throws {
        try validate(Document(entries: [binding.wallpaperID: binding]))
        guard binding.wallpaperID == snapshot.wallpaperID, binding.bundleDigest == snapshot.digest,
              binding.projectID == snapshot.specification.projectID, binding.bundleVersion == snapshot.bundleVersion,
              binding.context.sameHost(as: context), binding.runtimePolicy == snapshot.specification.runtimePolicy else { throw CreatorPersistence.Failure.staleValidation }
        if [2, 3].contains(snapshot.bundleVersion) {
            guard snapshot.manifest?.packaging == .sealed, let report = binding.report,
                  report.renderDigest == (try snapshot.renderDigest), report.posterDigest == snapshot.manifest?.posterDigest,
                  report.templateRevision == CreatorBundleManifest.templateIdentity(snapshot.specification).revision,
                  report.measuredMetrics["bundleBytes"] == Double(snapshot.files.values.reduce(0) { $0 + $1.count }),
                  let jpeg = snapshot.files["preview.jpg"] else { throw CreatorPersistence.Failure.staleValidation }
            var metrics = report.measuredMetrics; metrics.removeValue(forKey: "bundleBytes")
            try CreatorPosterMetadata.validate(jpeg: jpeg, metrics: metrics, context: binding.context)
        } else {
            guard binding.context == context else { throw CreatorPersistence.Failure.staleValidation }
        }
    }
    nonisolated static func readForPlayback(_ directory: URL, expectedDigest: String? = nil) throws -> CreatorDraftStore.Snapshot {
        try readForPlayback(directory, expectedDigest: expectedDigest, registryURL: ClientPaths.creatorRuntimeRegistryURL,
            publicationRoot: ClientPaths.storageURL.appendingPathComponent("Creator/Publication"))
    }

    /// An injected registry must supply its matching journal root, never the user's default storage.
    nonisolated static func readForPlayback(_ directory: URL, expectedDigest: String? = nil,
                                           registryURL: URL, context: ValidationReport.Context = .current,
                                           publicationRoot: URL) throws -> CreatorDraftStore.Snapshot {
        let lease = try CreatorPublisher.playbackLease(root: publicationRoot)
        defer { withExtendedLifetime(lease) {} }
        let document = try read(at: registryURL)
        let snapshot = try CreatorBundleManifest.read(directory, expectedDigest: expectedDigest)
        if [2, 3].contains(snapshot.bundleVersion), document.entries[directory.lastPathComponent] == nil {
            throw CreatorPersistence.Failure.incompleteBundle
        }
        if let binding = document.entries[directory.lastPathComponent] {
            try validateBinding(binding, snapshot: snapshot, context: context)
        }
        return snapshot
    }
}
