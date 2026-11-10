import Foundation

/// Immutable revisions; only project pointers, job journals and validation evidence are mutable.
actor CreatorRevisionStore {
    enum Checkpoint: Sendable { case afterStaging, afterRevisionMove, afterProjectCommit, afterIterationReservation }
    nonisolated let root: URL
    let context: ValidationReport.Context
    let checkpoint: @Sendable (Checkpoint) throws -> Void
    let checkStorage: @Sendable () throws -> Void
    var leases: [UUID: CreatorPersistence.Lease] = [:]
    var iterationLeases: [UUID: CreatorPersistence.Lease] = [:]

    init(root: URL? = nil, context: ValidationReport.Context = .current,
         checkpoint: @escaping @Sendable (Checkpoint) throws -> Void = { _ in },
         checkStorage: (@Sendable () throws -> Void)? = nil) {
        let resolved = root ?? ClientPaths.creatorURL
        self.root = resolved
        self.context = context
        self.checkpoint = checkpoint
        if let checkStorage { self.checkStorage = checkStorage }
        else if root != nil { self.checkStorage = {} }
        else {
            self.checkStorage = {
                if case .unavailable(let location) = ClientPaths.storageResolution { throw StorageUnavailableError(location: location) }
                guard ClientPaths.creatorURL.standardizedFileURL == resolved.standardizedFileURL else { throw CreatorPersistence.Failure.invalidPath }
            }
        }
    }

    nonisolated var projectsURL: URL { root.appendingPathComponent("Projects", isDirectory: true) }
    nonisolated var jobsURL: URL { root.appendingPathComponent("Jobs", isDirectory: true) }
    nonisolated func projectURL(_ id: UUID) -> URL { projectsURL.appendingPathComponent(CreatorPersistence.uuidName(id), isDirectory: true) }
    nonisolated func revisionURL(projectID: UUID, revisionID: UUID) -> URL {
        projectURL(projectID).appendingPathComponent("Revisions/" + CreatorPersistence.uuidName(revisionID), isDirectory: true)
    }
    nonisolated func bundleURL(projectID: UUID, revisionID: UUID) -> URL {
        revisionURL(projectID: projectID, revisionID: revisionID).appendingPathComponent("bundle", isDirectory: true)
    }
    nonisolated func jobURL(_ id: UUID) -> URL { jobsURL.appendingPathComponent(CreatorPersistence.uuidName(id), isDirectory: true) }

    func locked<T>(_ body: () throws -> T) throws -> T {
        try checkStorage()
        try CreatorPersistence.directory(root, create: true)
        let lock = try CreatorPersistence.Lease(root.appendingPathComponent(".lock"))
        defer { withExtendedLifetime(lock) {} }
        try context.validate()
        return try body()
    }

    func createProject(title: String, id: UUID = UUID()) throws -> CreatorProject {
        try locked {
            try Task.checkCancellation()
            let project = CreatorProject(schemaVersion: 1, id: id, title: title, createdAt: CreatorPersistence.timestamp(),
                                         revisionIDs: [], latestRevisionID: nil, lastValidatedRevisionID: nil,
                                         selectedRevisionID: nil, publishedWallpaperID: nil, activeJobID: nil)
            try project.validate()
            try CreatorPersistence.directory(projectsURL, create: true)
            guard !CreatorPersistence.exists(projectURL(id)) else { throw CreatorPersistence.Failure.busy }
            let pending = projectsURL.appendingPathComponent(".pending-" + CreatorPersistence.uuidName(id))
            guard !CreatorPersistence.exists(pending) else { throw CreatorPersistence.Failure.busy }
            defer { try? FileManager.default.removeItem(at: pending) }
            try CreatorPersistence.directory(pending.appendingPathComponent("Revisions"), create: true)
            try CreatorPersistence.write(project, to: pending.appendingPathComponent("project-meta.json"))
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: pending, to: projectURL(id))
            return project
        }
    }

    func project(_ id: UUID) throws -> CreatorProject { try locked { try readProject(id) } }
    func revision(projectID: UUID, revisionID: UUID) throws -> CreatorRevision {
        try locked { try readRevision(projectID: projectID, revisionID: revisionID).revision }
    }
    func job(_ id: UUID) throws -> GenerationJob { try locked { try readJob(id) } }

    func renameProject(_ id: UUID, title: String) throws {
        try locked {
            var project = try readProject(id)
            project.title = title
            project.lastValidatedRevisionID = nil
            project.selectedRevisionID = nil
            try save(project)
        }
    }

    /// Starts a new generation and durably fences callbacks from an older request.
    func beginJob(projectID: UUID, baseRevisionID: UUID? = nil, requestBudget: Int = 1, tokenBudget: Int = 4096,
                  expectedBaseDigest: String? = nil, sealingLatest: Bool = false,
                  iteration: CreatorConversation.Ticket? = nil) throws -> GenerationJob.Ticket {
        try locked {
            try Task.checkCancellation()
            if let iteration {
                let turn = try activeIteration(iteration)
                guard iteration.projectID == projectID,
                      sealingLatest ? turn.state == .sealing && turn.attempts.last?.draftRevisionID == baseRevisionID
                        : turn.state == .generating && turn.baseRevisionID == baseRevisionID && turn.baseRevisionDigest == expectedBaseDigest
                else { throw CreatorPersistence.Failure.staleJob }
            } else if !sealingLatest { try cancelActiveIteration(projectID) }
            else if let turn = try readConversation(projectID).turns.last, !turn.state.terminal { throw CreatorPersistence.Failure.busy }
            var project = try readProject(projectID)
            if sealingLatest {
                guard project.activeJobID == nil, project.latestRevisionID == baseRevisionID else { throw CreatorPersistence.Failure.staleJob }
            }
            if let baseRevisionID {
                let base = try readRevision(projectID: projectID, revisionID: baseRevisionID)
                if let expectedBaseDigest, base.metadataDigest != expectedBaseDigest { throw CreatorPersistence.Failure.staleJob }
            } else if expectedBaseDigest != nil { throw CreatorPersistence.Failure.invalidRecord }
            let job = GenerationJob(schemaVersion: 1, id: UUID(), projectID: projectID, baseRevisionID: baseRevisionID,
                                    state: .generating, attemptCount: 0, requestBudget: requestBudget, tokenBudget: tokenBudget,
                                    cancellationToken: UUID(), createdAt: CreatorPersistence.timestamp(), candidateRevisionID: nil, candidateDigest: nil,
                                    baseRevisionDigest: expectedBaseDigest, iterationID: iteration?.id)
            try job.validate()
            if let previous = project.activeJobID {
                let old = try readJob(previous)
                guard old.projectID == projectID else { throw CreatorPersistence.Failure.invalidRecord }
                try cancelUnlocked(old.ticket)
                project = try readProject(projectID)
            }
            try CreatorPersistence.directory(jobURL(job.id), create: true)
            let lease = try CreatorPersistence.Lease(jobURL(job.id).appendingPathComponent(".lease"))
            try save(job)
            leases[job.id] = lease
            if let iteration { try updateIteration(iteration) { $0.currentJobID = job.id } }
            project.activeJobID = job.id
            try save(project)
            return job.ticket
        }
    }

    func recordAttempt(_ ticket: GenerationJob.Ticket) throws {
        try locked {
            var job = try activeJob(ticket)
            guard job.state == .generating, job.iterationID == nil, job.attemptCount < job.requestBudget else { throw CreatorPersistence.Failure.staleJob }
            job.attemptCount += 1
            try save(job)
        }
    }

    func generatingJob(_ ticket: GenerationJob.Ticket) throws -> GenerationJob {
        try locked {
            try Task.checkCancellation()
            let job = try activeJob(ticket)
            guard job.state == .generating else { throw CreatorPersistence.Failure.staleJob }
            return job
        }
    }

    /// Reserve a request's maximum output before sending; failed requests keep their reservation.
    func reserveLLMAttempt(_ ticket: GenerationJob.Ticket, profile: ProviderProfile, outputTokens: Int) throws -> GenerationJob {
        try locked {
            try Task.checkCancellation()
            var job = try activeJob(ticket)
            let total = min(job.tokenBudget, profile.limits.tokenBudget)
            guard job.state == .generating, job.attemptCount < min(job.requestBudget, profile.limits.requestBudget),
                  job.reservedOutputTokens != nil || job.attemptCount == 0,
                  outputTokens > 0, outputTokens <= total - (job.reservedOutputTokens ?? 0)
            else { throw LLMFailure.budgetExhausted }
            try reserveIterationAttempt(job, profile: profile, outputTokens: outputTokens)
            if job.iterationID != nil { try checkpoint(.afterIterationReservation) }
            job.attemptCount += 1
            job.reservedOutputTokens = (job.reservedOutputTokens ?? 0) + outputTokens
            try save(job)
            return job
        }
    }

    /// Opaque partial data is bounded, never placed in a bundle and never interpreted as code.
    func savePartial(_ data: Data, for ticket: GenerationJob.Ticket) throws {
        try locked {
            let job = try activeJob(ticket)
            guard job.state == .generating, data.count <= 16 * 1024 else { throw CreatorPersistence.Failure.tooLarge }
            try Task.checkCancellation()
            try CreatorPersistence.atomicWrite(data, to: jobURL(job.id).appendingPathComponent("partial.bin"))
        }
    }

    func stage(_ specification: CreatorTemplate.Specification, for ticket: GenerationJob.Ticket,
               summary: String = "", legacy: Bool = false, presentation: CreatorBundlePresentation? = nil,
               generation: CreatorGenerationMetadata? = nil, providerID: String? = nil, modelID: String? = nil) throws -> CreatorRevision {
        try locked {
            try Task.checkCancellation()
            var job = try activeJob(ticket)
            guard job.state == .generating, specification.projectID == job.projectID,
                  summary.unicodeScalars.count <= 240 else { throw CreatorPersistence.Failure.invalidRecord }
            if let generation {
                try generation.validate()
                guard !legacy, generation.jobID == job.id, generation.attemptCount == job.attemptCount,
                      generation.reservedOutputTokens == job.reservedOutputTokens,
                      generation.baseRevisionDigest == job.baseRevisionDigest, generation.iterationID == job.iterationID
                else { throw CreatorPersistence.Failure.invalidRecord }
                if let turn = try iterationForJob(job), generation.repairIndex != turn.repairCount { throw CreatorPersistence.Failure.invalidRecord }
                try checkBase(job)
            } else if providerID != nil || modelID != nil || (legacy && presentation != nil) {
                throw CreatorPersistence.Failure.invalidRecord
            }
            let files = try legacy ? CreatorTemplate.files(for: specification) : CreatorBundleManifest.files(for: specification, presentation: presentation)
            let candidate = jobURL(job.id).appendingPathComponent("candidate", isDirectory: true)
            guard !CreatorPersistence.exists(candidate) else { throw CreatorPersistence.Failure.busy }
            let bundle = candidate.appendingPathComponent("bundle", isDirectory: true)
            try CreatorPersistence.directory(bundle, create: true)
            for (name, data) in files {
                try Task.checkCancellation()
                try CreatorPersistence.atomicWrite(data, to: bundle.appendingPathComponent(name))
            }
            let snapshot = try CreatorBundleManifest.read(bundle, scopedRevision: true)
            let identity = CreatorBundleManifest.templateIdentity(specification)
            let revision = CreatorRevision(schemaVersion: 1, id: UUID(), projectID: job.projectID, parentID: job.baseRevisionID,
                                           promptSummary: summary, providerID: providerID, modelID: modelID, outputSchemaVersion: generation == nil ? nil : 1,
                                           bundleVersion: snapshot.bundleVersion, sdkVersion: 1, policyVersion: 1,
                                           templateID: identity.0, templateRevision: identity.1,
                                           normalizedParameters: CreatorBundleManifest.parameters(specification),
                                           renderDigest: try snapshot.renderDigest, posterDigest: nil, bundleDigest: snapshot.digest,
                                           createdAt: CreatorPersistence.timestamp(), generation: generation)
            try revision.validate(against: snapshot)
            try CreatorPersistence.write(revision, to: candidate.appendingPathComponent("revision.json"))
            job.candidateRevisionID = revision.id
            job.candidateDigest = snapshot.digest
            job.state = .staged
            try save(job)
            try checkpoint(.afterStaging)
            try Task.checkCancellation()
            return revision
        }
    }

    /// The atomic project index replacement is the commit point. A revision folder alone is not visible history.
    func commit(_ ticket: GenerationJob.Ticket, validatingStructure: Bool = false,
                runtimeEvidence: CreatorRuntimeCapture? = nil) throws -> CreatorRevision {
        try locked {
            try Task.checkCancellation()
            var job = try activeJob(ticket)
            guard job.state == .staged, let id = job.candidateRevisionID else { throw CreatorPersistence.Failure.staleJob }
            var project = try readProject(job.projectID)
            let candidate = jobURL(job.id).appendingPathComponent("candidate", isDirectory: true)
            let pair = try readRevisionDirectory(candidate)
            guard pair.revision.id == id, pair.revision.projectID == project.id,
                  pair.revision.parentID == job.baseRevisionID, pair.snapshot.digest == job.candidateDigest else { throw CreatorPersistence.Failure.invalidRecord }
            if let parent = job.baseRevisionID { _ = try readRevision(projectID: project.id, revisionID: parent) }
            try checkBase(job)
            guard project.revisionIDs.count < 1000 else { throw CreatorPersistence.Failure.tooLarge }
            let destination = revisionURL(projectID: project.id, revisionID: id)
            guard !CreatorPersistence.exists(destination) else { throw CreatorPersistence.Failure.busy }
            // A revision and its matching structure/runtime evidence cross the same commit point.
            // Runtime evidence is supplied only by the native sealing flow.
            if validatingStructure || runtimeEvidence != nil {
                let report: ValidationReport
                if let runtimeEvidence {
                    report = try runtimeReport(project: project, revision: pair.revision, snapshot: pair.snapshot,
                                               metadataDigest: pair.metadataDigest, evidence: runtimeEvidence)
                } else {
                    report = makeReport(project: project, revision: pair.revision, snapshot: pair.snapshot, metadataDigest: pair.metadataDigest)
                }
                try CreatorPersistence.write(report, to: candidate.appendingPathComponent("validation.json"))
            }
            job.state = .committing
            try save(job)
            try FileManager.default.moveItem(at: candidate, to: destination)
            try checkpoint(.afterRevisionMove)
            try Task.checkCancellation()
            project.revisionIDs.append(id)
            project.latestRevisionID = id
            project.activeJobID = nil
            if runtimeEvidence != nil || (validatingStructure && job.iterationID == nil) {
                project.lastValidatedRevisionID = id
                project.selectedRevisionID = id
            }
            // Keep the last validated selection until this candidate has its own evidence.
            try save(project)
            try checkpoint(.afterProjectCommit)
            job.state = .completed
            try save(job)
            try cleanJobFiles(job)
            leases[job.id] = nil
            return pair.revision
        }
    }

    func cancel(_ ticket: GenerationJob.Ticket) throws { try locked { try cancelUnlocked(ticket) } }

    func validate(projectID: UUID, revisionID: UUID) throws -> ValidationReport {
        try locked {
            try Task.checkCancellation()
            var project = try readProject(projectID)
            let pair = try readRevision(projectID: projectID, revisionID: revisionID)
            let report = makeReport(project: project, revision: pair.revision, snapshot: pair.snapshot, metadataDigest: pair.metadataDigest)
            try CreatorPersistence.write(report, to: reportURL(projectID, revisionID))
            project.lastValidatedRevisionID = revisionID
            project.selectedRevisionID = revisionID
            try save(project)
            return report
        }
    }

    func report(projectID: UUID, revisionID: UUID) throws -> ValidationReport {
        try locked { try validReport(projectID: projectID, revisionID: revisionID) }
    }

    /// This is the only v2 draft preview entry. It rechecks persisted evidence on every load/reload.
    func snapshot(projectID: UUID, revisionID: UUID) throws -> CreatorDraftStore.Snapshot {
        try locked {
            try validatedSnapshot(projectID: projectID, revisionID: revisionID).snapshot
        }
    }

    func select(projectID: UUID, revisionID: UUID) throws {
        try locked {
            try Task.checkCancellation()
            _ = try validReport(projectID: projectID, revisionID: revisionID)
            try cancelActiveIteration(projectID)
            var project = try readProject(projectID)
            project.selectedRevisionID = revisionID
            try save(project)
        }
    }

    func readProject(_ id: UUID) throws -> CreatorProject {
        let value = try CreatorPersistence.read(CreatorProject.self, at: projectURL(id).appendingPathComponent("project-meta.json"))
        try value.validate()
        guard value.id == id else { throw CreatorPersistence.Failure.invalidRecord }
        return value
    }
    func save(_ project: CreatorProject) throws {
        try project.validate()
        try CreatorPersistence.write(project, to: projectURL(project.id).appendingPathComponent("project-meta.json"))
    }
    func readJob(_ id: UUID) throws -> GenerationJob {
        let value = try CreatorPersistence.read(GenerationJob.self, at: jobURL(id).appendingPathComponent("job.json"))
        try value.validate()
        guard value.id == id else { throw CreatorPersistence.Failure.invalidRecord }
        return value
    }
    func save(_ job: GenerationJob) throws {
        try job.validate()
        try CreatorPersistence.write(job, to: jobURL(job.id).appendingPathComponent("job.json"))
    }
    func activeJob(_ ticket: GenerationJob.Ticket) throws -> GenerationJob {
        let job = try readJob(ticket.id)
        guard job.ticket == ticket, !job.isTerminal, leases[job.id] != nil,
              try readProject(job.projectID).activeJobID == job.id else { throw CreatorPersistence.Failure.staleJob }
        _ = try iterationForJob(job)
        return job
    }
    func readRevisionDirectory(_ directory: URL) throws -> (revision: CreatorRevision, snapshot: CreatorDraftStore.Snapshot, metadataDigest: String) {
        let names = Set(try CreatorPersistence.directories(directory).map(\.lastPathComponent))
        guard names == ["revision.json", "bundle"] || names == ["revision.json", "bundle", "validation.json"] else { throw CreatorPersistence.Failure.invalidRecord }
        let metadata = try CreatorPersistence.bytes(directory.appendingPathComponent("revision.json"), limit: 256 * 1024)
        let revision = try CreatorPersistence.decode(CreatorRevision.self, from: metadata)
        let snapshot = try CreatorBundleManifest.read(directory.appendingPathComponent("bundle"), scopedRevision: true)
        try revision.validate(against: snapshot)
        return (revision, snapshot, CreatorPersistence.hash(metadata))
    }
    func readRevision(projectID: UUID, revisionID: UUID) throws -> (revision: CreatorRevision, snapshot: CreatorDraftStore.Snapshot, metadataDigest: String) {
        let project = try readProject(projectID)
        guard project.revisionIDs.contains(revisionID) else { throw CreatorPersistence.Failure.missing }
        let pair = try readRevisionDirectory(revisionURL(projectID: projectID, revisionID: revisionID))
        guard pair.revision.id == revisionID, pair.revision.projectID == projectID,
              pair.revision.parentID == nil || project.revisionIDs.prefix(while: { $0 != revisionID }).contains(pair.revision.parentID!)
        else { throw CreatorPersistence.Failure.invalidRecord }
        return pair
    }
    func reportURL(_ projectID: UUID, _ revisionID: UUID) -> URL {
        revisionURL(projectID: projectID, revisionID: revisionID).appendingPathComponent("validation.json")
    }
    func validReport(projectID: UUID, revisionID: UUID) throws -> ValidationReport {
        try validatedSnapshot(projectID: projectID, revisionID: revisionID).report
    }
    func validatedSnapshot(projectID: UUID, revisionID: UUID) throws -> (report: ValidationReport, snapshot: CreatorDraftStore.Snapshot) {
        let project = try readProject(projectID)
        let pair = try readRevision(projectID: projectID, revisionID: revisionID)
        let report = try CreatorPersistence.read(ValidationReport.self, at: reportURL(projectID, revisionID))
        guard report.schemaVersion == 1, report.projectID == projectID, report.revisionID == revisionID,
              report.projectIdentityDigest == project.identityDigest, report.revisionDigest == pair.metadataDigest,
              report.renderDigest == pair.revision.renderDigest, report.posterDigest == pair.revision.posterDigest,
              report.bundleDigest == pair.snapshot.digest, report.templateRevision == pair.revision.templateRevision,
              report.context == (report.allowsPublication ? context.runtime : context),
              report.allowsPreview, report.validatedAt >= pair.revision.createdAt,
              report.measuredMetrics == (try expectedMetrics(report: report, revision: pair.revision, snapshot: pair.snapshot))
        else { throw CreatorPersistence.Failure.staleValidation }
        return (report, pair.snapshot)
    }
}
