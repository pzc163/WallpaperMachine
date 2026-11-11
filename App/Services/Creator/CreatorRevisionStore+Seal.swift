import Foundation

extension CreatorRevisionStore {
    func recordPublished(_ binding: CreatorRuntimeRegistry.Binding) throws {
        try locked {
            var project = try readProject(binding.projectID)
            let pair = try readRevision(projectID: project.id, revisionID: binding.revisionID)
            guard pair.metadataDigest == binding.report?.revisionDigest else { throw CreatorPersistence.Failure.staleValidation }
            try CreatorRuntimeRegistry.validateBinding(binding, snapshot: pair.snapshot, context: context)
            project.publishedWallpaperID = binding.wallpaperID
            try save(project)
        }
    }

    func seal(_ capture: CreatorRuntimeCapture, iteration: CreatorConversation.Ticket? = nil) throws -> CreatorRevision {
        try capture.validate()
        let source = capture.sourceReport
        let ticket = try beginJob(projectID: source.projectID, baseRevisionID: source.revisionID,
                                  expectedBaseDigest: source.revisionDigest, sealingLatest: true, iteration: iteration)
        do {
            try locked {
                try Task.checkCancellation()
                var job = try activeJob(ticket)
                let checked = try validatedSnapshot(projectID: source.projectID, revisionID: source.revisionID)
                let original = try readRevision(projectID: source.projectID, revisionID: source.revisionID).revision
                guard checked.report == source, [2, 3].contains(checked.snapshot.bundleVersion),
                      checked.snapshot.manifest?.packaging == .renderDraft else { throw CreatorPersistence.Failure.staleValidation }
                let files = try CreatorBundleManifest.files(for: checked.snapshot.specification, poster: capture.jpeg,
                                                            presentation: checked.snapshot.manifest?.presentation,
                                                            source: checked.snapshot.specification.kind == .code ? checked.snapshot.files["index.html"] : nil, assets: checked.snapshot.assets)
                let candidate = jobURL(job.id).appendingPathComponent("candidate", isDirectory: true)
                let bundle = candidate.appendingPathComponent("bundle", isDirectory: true)
                try CreatorPersistence.directory(bundle, create: true)
                try CreatorBundleManifest.write(files, to: bundle)
                let snapshot = try CreatorBundleManifest.read(bundle, scopedRevision: true)
                guard try snapshot.renderDigest == source.renderDigest else { throw CreatorPersistence.Failure.staleValidation }
                let sealed = CreatorRevision(schemaVersion: 1, id: UUID(), projectID: source.projectID, parentID: source.revisionID,
                    promptSummary: original.promptSummary, providerID: original.providerID, modelID: original.modelID,
                    outputSchemaVersion: original.outputSchemaVersion, bundleVersion: snapshot.bundleVersion, sdkVersion: original.sdkVersion,
                    policyVersion: original.policyVersion, templateID: original.templateID, templateRevision: original.templateRevision,
                    normalizedParameters: original.normalizedParameters, renderDigest: source.renderDigest,
                    posterDigest: CreatorPersistence.hash(capture.jpeg), bundleDigest: snapshot.digest,
                    createdAt: CreatorPersistence.timestamp(), generation: original.generation,
                    seal: CreatorSeal(schemaVersion: 1, sourceRevisionID: source.revisionID, sourceRevisionDigest: source.revisionDigest,
                                      renderDigest: source.renderDigest, context: source.context.runtime, metrics: capture.metrics))
                try sealed.validate(against: snapshot)
                try CreatorPersistence.write(sealed, to: candidate.appendingPathComponent("revision.json"))
                job.candidateRevisionID = sealed.id; job.candidateDigest = snapshot.digest; job.state = .staged
                try save(job)
                try checkpoint(.afterStaging)
            }
            return try commit(ticket, runtimeEvidence: capture)
        } catch {
            let failure = error
            try cancel(ticket)
            throw failure
        }
    }

    func publication(projectID: UUID, revisionID: UUID) throws -> (snapshot: CreatorDraftStore.Snapshot, binding: CreatorRuntimeRegistry.Binding) {
        try locked {
            try Task.checkCancellation()
            let pair = try validatedSnapshot(projectID: projectID, revisionID: revisionID)
            guard pair.report.allowsPublication, pair.snapshot.manifest?.packaging == .sealed else { throw CreatorPersistence.Failure.incompleteBundle }
            let binding = CreatorRuntimeRegistry.Binding(schemaVersion: 1, wallpaperID: pair.snapshot.wallpaperID,
                projectID: projectID, revisionID: revisionID, bundleVersion: pair.snapshot.bundleVersion, bundleDigest: pair.snapshot.digest,
                runtimePolicy: pair.snapshot.specification.runtimePolicy, context: pair.report.context, report: pair.report)
            try CreatorRuntimeRegistry.validateBinding(binding, snapshot: pair.snapshot, context: context)
            return (pair.snapshot, binding)
        }
    }

    func runtimeReport(project: CreatorProject, revision: CreatorRevision, snapshot: CreatorDraftStore.Snapshot,
                       metadataDigest: String, evidence: CreatorRuntimeCapture) throws -> ValidationReport {
        try evidence.validate()
        let source = evidence.sourceReport
        guard try validReport(projectID: project.id, revisionID: source.revisionID) == source,
              revision.parentID == source.revisionID, revision.seal?.sourceRevisionDigest == source.revisionDigest,
              revision.renderDigest == source.renderDigest, revision.posterDigest == CreatorPersistence.hash(evidence.jpeg),
              revision.seal?.metrics == evidence.metrics else { throw CreatorPersistence.Failure.staleValidation }
        var metrics = evidence.metrics
        metrics["bundleBytes"] = Double(snapshot.files.values.reduce(0) { $0 + $1.count })
        return ValidationReport(schemaVersion: 1, id: UUID(), projectID: project.id, revisionID: revision.id,
            projectIdentityDigest: project.identityDigest, revisionDigest: metadataDigest,
            renderDigest: revision.renderDigest, posterDigest: revision.posterDigest, bundleDigest: snapshot.digest,
            templateRevision: revision.templateRevision, context: context.forMode(snapshot.specification.creationMode).runtime,
            results: ["structure": .passed, "sourceReconstruction": .passed, "policy": .passed, "runtime": .passed, "posterCapture": .passed],
            measuredMetrics: metrics, validatedAt: CreatorPersistence.timestamp())
    }

    func expectedMetrics(report: ValidationReport, revision: CreatorRevision, snapshot: CreatorDraftStore.Snapshot) throws -> [String: Double] {
        var metrics: [String: Double] = [:]
        if report.allowsPublication {
            guard let seal = revision.seal, seal.context == report.context else { throw CreatorPersistence.Failure.staleValidation }
            try seal.validate(snapshot: snapshot)
            metrics = seal.metrics
        }
        metrics["bundleBytes"] = Double(snapshot.files.values.reduce(0) { $0 + $1.count })
        return metrics
    }
}
