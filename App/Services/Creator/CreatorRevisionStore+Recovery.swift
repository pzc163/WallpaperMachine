import Foundation

extension CreatorRevisionStore {
    struct Recovery: Equatable, Sendable {
        var interruptedJobs: [UUID] = []
        var completedJobs: [UUID] = []
        var liveJobs: [UUID] = []
        var invalidJobs: [UUID] = []
        var invalidProjects: [UUID] = []
        var invalidRevisions: [UUID] = []
        var restoredProjects: [UUID] = []
        var discardedAtomicWrites = 0
        var interruptedIterations: [UUID] = []
        var liveIterations: [UUID] = []
        var invalidConversations: [UUID] = []
    }

    /// Call on opening the creator workspace. A held lease belongs to another live owner.
    func recover() throws -> Recovery {
        try locked {
            var result = Recovery()
            if CreatorPersistence.exists(jobsURL) {
                for directory in try CreatorPersistence.directories(jobsURL) {
                    guard CreatorPersistence.isUUIDName(directory.lastPathComponent), let id = UUID(uuidString: directory.lastPathComponent) else { continue }
                    do {
                        result.discardedAtomicWrites += try discardAtomicWrites(in: directory)
                        var job = try readJob(id)
                        if job.isTerminal {
                            // Finishing cleanup is safe even if the terminal journal was the last durable write.
                            try cleanJobFiles(job)
                            continue
                        }
                        if leases[id] != nil { result.liveJobs.append(id); continue }
                        let lease: CreatorPersistence.Lease
                        do { lease = try CreatorPersistence.Lease(directory.appendingPathComponent(".lease")) }
                        catch CreatorPersistence.Failure.busy { result.liveJobs.append(id); continue }
                        defer { withExtendedLifetime(lease) {} }
                        var project = try readProject(job.projectID)
                        if let candidate = job.candidateRevisionID, project.revisionIDs.contains(candidate) {
                            let pair = try readRevision(projectID: project.id, revisionID: candidate)
                            guard pair.snapshot.digest == job.candidateDigest, pair.revision.parentID == job.baseRevisionID,
                                  job.state == .committing else { throw CreatorPersistence.Failure.invalidRecord }
                            job.state = .completed
                            result.completedJobs.append(id)
                        } else {
                            try removeUncommittedRevision(job, project: project)
                            job.state = .interrupted
                            result.interruptedJobs.append(id)
                        }
                        if project.activeJobID == id { project.activeJobID = nil; try save(project) }
                        try save(job)
                        try cleanJobFiles(job)
                    } catch { result.invalidJobs.append(id) }
                }
            }
            if CreatorPersistence.exists(projectsURL) {
                for directory in try CreatorPersistence.directories(projectsURL) {
                    if directory.lastPathComponent.hasPrefix(".deleted-"),
                       let id = UUID(uuidString: String(directory.lastPathComponent.dropFirst(9))) {
                        try CreatorPersistence.directory(directory)
                        let retired = try CreatorPersistence.read(CreatorProject.self, at: directory.appendingPathComponent("project-meta.json"))
                        try retired.validate()
                        guard retired.id == id else { throw CreatorPersistence.Failure.invalidRecord }
                        try FileManager.default.removeItem(at: directory)
                        continue
                    }
                    guard CreatorPersistence.isUUIDName(directory.lastPathComponent), let id = UUID(uuidString: directory.lastPathComponent) else { continue }
                    do {
                        result.discardedAtomicWrites += try discardAtomicWrites(in: directory)
                        let hasConversation = CreatorPersistence.exists(conversationURL(id))
                        if hasConversation { try recoverConversation(id, result: &result) }
                        var project = try readProject(id)
                        let original = project
                        var intact: [UUID] = []
                        var validated: [UUID] = []
                        var usable: [UUID] = []
                        for revisionID in project.revisionIDs {
                            let revisionDirectory = revisionURL(projectID: id, revisionID: revisionID)
                            if CreatorPersistence.exists(revisionDirectory) {
                                result.discardedAtomicWrites += try discardAtomicWrites(in: revisionDirectory)
                            }
                            if (try? readRevision(projectID: id, revisionID: revisionID)) != nil { intact.append(revisionID) }
                            else { result.invalidRevisions.append(revisionID) }
                            if let report = try? validReport(projectID: id, revisionID: revisionID) {
                                validated.append(revisionID)
                                if !hasConversation || report.allowsPublication || (try? readRevision(projectID: id, revisionID: revisionID).revision.bundleVersion) == 1 {
                                    usable.append(revisionID)
                                }
                            }
                        }
                        project.latestRevisionID = intact.last
                        project.lastValidatedRevisionID = usable.last
                        if project.selectedRevisionID.map({ validated.contains($0) }) != true { project.selectedRevisionID = usable.last }
                        if let active = project.activeJobID {
                            if let job = try? readJob(active), job.projectID == id {
                                if job.isTerminal { project.activeJobID = nil }
                            } else { project.activeJobID = nil }
                        }
                        if original != project { try save(project); result.restoredProjects.append(id) }
                    } catch { result.invalidProjects.append(id) }
                }
            }
            return result
        }
    }

    func recoverConversation(_ projectID: UUID, result: inout Recovery) throws {
        do {
            guard let turn = try readConversation(projectID).turns.last, !turn.state.terminal else { return }
            if iterationLeases[turn.id] != nil { result.liveIterations.append(turn.id); return }
            let ticket = CreatorConversation.Ticket(id: turn.id, projectID: projectID, token: turn.token)
            let lease: CreatorPersistence.Lease
            do { lease = try CreatorPersistence.Lease(iterationLeaseURL(ticket)) }
            catch CreatorPersistence.Failure.busy { result.liveIterations.append(turn.id); return }
            defer { withExtendedLifetime(lease) {} }
            try closeIterationUnlocked(ticket, state: .interrupted, issue: .init(category: .interrupted))
            result.interruptedIterations.append(turn.id)
        } catch { result.invalidConversations.append(projectID); throw error }
    }

    /// A crashed atomic write can leave only a non-authoritative temporary sibling.
    func discardAtomicWrites(in directory: URL) throws -> Int {
        var count = 0
        for file in try CreatorPersistence.directories(directory) {
            let name = file.lastPathComponent
            guard name.hasPrefix(".pending-"), CreatorPersistence.isUUIDName(String(name.dropFirst(9))) else { continue }
            _ = try CreatorPersistence.bytes(file, limit: 1024 * 1024)
            try FileManager.default.removeItem(at: file)
            count += 1
        }
        return count
    }

    func cancelUnlocked(_ ticket: GenerationJob.Ticket) throws {
        var job = try readJob(ticket.id)
        guard job.ticket == ticket else { throw CreatorPersistence.Failure.staleJob }
        if job.isTerminal { return }
        LLMRequestCoordinator.shared.jobCancelled(at: jobURL(job.id), ticket: ticket)
        var project = try readProject(job.projectID)
        if let candidate = job.candidateRevisionID, project.revisionIDs.contains(candidate) {
            // The project commit already won the race; never remove a committed revision.
            job.state = .completed
        } else {
            try removeUncommittedRevision(job, project: project)
            job.state = .cancelled
        }
        if project.activeJobID == job.id { project.activeJobID = nil; try save(project) }
        try save(job)
        try cleanJobFiles(job)
        leases[job.id] = nil
    }

    func removeUncommittedRevision(_ job: GenerationJob, project: CreatorProject) throws {
        guard let id = job.candidateRevisionID else { return }
        let destination = revisionURL(projectID: project.id, revisionID: id)
        guard !project.revisionIDs.contains(id), CreatorPersistence.exists(destination) else { return }
        let pair = try readRevisionDirectory(destination)
        guard job.state == .committing, pair.revision.id == id, pair.revision.projectID == project.id,
              pair.revision.parentID == job.baseRevisionID, pair.snapshot.digest == job.candidateDigest else { throw CreatorPersistence.Failure.invalidRecord }
        try FileManager.default.removeItem(at: destination)
    }

    func cleanJobFiles(_ job: GenerationJob) throws {
        for file in try CreatorPersistence.directories(jobURL(job.id)) {
            let name = file.lastPathComponent
            guard name == "candidate" || name == "partial.bin" || name.hasPrefix(".pending-") else { continue }
            // removeItem removes a link itself; it never traverses it into another project.
            try FileManager.default.removeItem(at: file)
        }
    }
}
