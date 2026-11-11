import Foundation
@testable import WallpaperMachine

enum CreatorS14Fixtures {
    static func draft(store: CreatorRevisionStore, projectID: UUID? = nil, template: String = "stars-v2") async throws -> CreatorRevision {
        let id: UUID
        if let projectID { id = projectID } else { id = try await store.createProject(title: "Snapshot fixture").id }
        let job = try await store.beginJob(projectID: id)
        _ = try await store.stage(CreatorTemplateCatalog.definition(template).specification(projectID: id), for: job)
        return try await store.commit(job, validatingStructure: true)
    }
    static func context(width: Int, height: Int) -> ValidationReport.Context {
        .init(policyVersion: 1, sdkVersion: 1, hostVersion: ValidationReport.Context.current.hostVersion,
              testProfile: "template-structure-v1", width: width, height: height)
    }
    @MainActor static func sealed(store: CreatorRevisionStore, projectID: UUID? = nil, template: String = "stars-v2") async throws -> CreatorRevision {
        let draft = try await draft(store: store, projectID: projectID, template: template)
        let capture = try await CreatorPosterService().capture(projectID: draft.projectID, revisionID: draft.id, store: store)
        return try await store.seal(capture)
    }
}
