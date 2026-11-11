import Foundation
import Observation

@MainActor @Observable
final class CreatorModel {
    enum Phase: Equatable { case idle, generating, repairPending, runtime, sealing, ready, saving, saved, editing, failed, cancelled }
    var projects: [CreatorRevisionStore.WorkspaceProject] = []
    var configuration = CreatorSettings()
    var selectedProjectID: UUID?
    var detail: CreatorWorkspace.Detail?
    var search = ""
    var prompt = ""
    var composerFocusID = UUID()
    var mode = CreatorCreationMode.template
    var autoRepair = false
    var maxRepairs = 1
    var phase = Phase.idle
    var streamProgress = LLMStreamProgress()
    var attempt = 0
    var attemptLimit = 1
    var elapsed: TimeInterval?
    var issue: CreatorRepairIssue?
    var showsReport = false
    var parameters: [String: CreatorTemplateCatalog.Value] = [:]
    var recovered = false
    var recovery: CreatorRevisionStore.Recovery?
    var connectionStatus: String?
    var connectionNotice: CreatorWorkspace.ConnectionResult?
    var isTestingConnection = false
    var isBusy = false
    @ObservationIgnored var recoveryTask: Task<CreatorRevisionStore.Recovery, Error>?
    @ObservationIgnored var operation: Task<Void, Error>?
    @ObservationIgnored var connection: Task<CreatorWorkspace.ConnectionResult, Error>?
    @ObservationIgnored var operationID = UUID()
    @ObservationIgnored var preview: CreatorPreviewWindow?
    var filteredProjects: [CreatorRevisionStore.WorkspaceProject] {
        projects.filter { search.isEmpty || $0.title.localizedStandardContains(search) }
    }
    var selectedRevision: CreatorRevision? {
        detail?.revisions.first { $0.id == detail?.project.selectedRevisionID }
    }
    var hasParameterChanges: Bool { parameters != (detail?.specification?.parameters ?? [:]) }
    var canSave: Bool {
        guard !isBusy, !hasParameterChanges, let revision = selectedRevision else { return false }
        return detail?.reports[revision.id]?.allowsPublication == true
    }
    var canApply: Bool { canSave && selectedRevision?.id == detail?.installedRevisionID }
    var profile: ProviderProfile? { configuration.profiles.first { $0.id == configuration.selectedProfileID } }
    var canGenerate: Bool { (mode != .code || CreatorCodeProcess.supported) && recovered && !isBusy && profile != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.utf8.count <= 2048 }
    func cancel() { operation?.cancel(); connection?.cancel() }
    func close() { cancel(); preview?.close(); preview = nil }
}
