import Foundation

extension CreatorRevisionStore {
    func generationBase(projectID: UUID, revisionID: UUID) throws -> CreatorPromptBuilder.Base {
        try locked {
            try Task.checkCancellation()
            let project = try readProject(projectID)
            let pair = try readRevision(projectID: projectID, revisionID: revisionID)
            guard CreatorTemplateCatalog.all.contains(where: { $0.id == pair.revision.templateID })
            else { throw CreatorGenerationFailure.policyViolation }
            return CreatorPromptBuilder.Base(revisionID: revisionID, revisionDigest: pair.metadataDigest,
                templateID: pair.revision.templateID, parameters: pair.revision.normalizedParameters,
                title: pair.snapshot.manifest?.presentation?.title ?? project.title,
                summary: pair.snapshot.manifest?.presentation?.summary ?? pair.revision.promptSummary)
        }
    }
    func checkBase(_ job: GenerationJob) throws {
        if let digest = job.baseRevisionDigest {
            guard let id = job.baseRevisionID,
                  try readRevision(projectID: job.projectID, revisionID: id).metadataDigest == digest
            else { throw CreatorPersistence.Failure.staleJob }
        }
    }
    func makeReport(project: CreatorProject, revision: CreatorRevision, snapshot: CreatorDraftStore.Snapshot,
                    metadataDigest: String) -> ValidationReport {
        ValidationReport(schemaVersion: 1, id: UUID(), projectID: project.id, revisionID: revision.id,
            projectIdentityDigest: project.identityDigest, revisionDigest: metadataDigest,
            renderDigest: revision.renderDigest, posterDigest: revision.posterDigest,
            bundleDigest: snapshot.digest, templateRevision: revision.templateRevision, context: context,
            results: ["structure": .passed, "sourceReconstruction": .passed, "policy": .passed,
                      "runtime": .notChecked, "posterCapture": .notChecked],
            measuredMetrics: ["bundleBytes": Double(snapshot.files.values.reduce(0) { $0 + $1.count })],
            validatedAt: CreatorPersistence.timestamp())
    }
}
