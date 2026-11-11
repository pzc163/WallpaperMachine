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
    var mode = CreatorCreationMode.code
    var engine = CreatorEngine.shaderGLSL
    var masters: [CreatorMasterCatalog.Master] = []
    var masterPosters: [String: PanelImageSource] = [:]
    var showsGallery = true
    var autoRepair = false
    var maxRepairs = 1
    var phase = Phase.idle
    var streamProgress = LLMStreamProgress()
    var activeTranscript: CreatorTranscript?
    var transcripts: [UUID: CreatorTranscript] = [:]
    @ObservationIgnored private var transcriptOrder: [UUID] = []
    enum ArtifactTab: String { case render, source }
    var artifactTab = ArtifactTab.render
    var artifactVisible = false
    var sourceDraft: String? = nil
    var stageAspect = CreatorPreviewWindow.Aspect.wide
    var conversationExpanded = false
    let embedded = CreatorEmbeddedPreview()
    var artifactSource: String {
        if let activeTranscript { return Self.displaySource(activeTranscript.progress.content) }
        if let sourceDraft { return sourceDraft }
        if let turn = detail?.conversation.turns.last, turn.state != .completed,
           let text = transcripts[turn.id]?.progress.content, !text.isEmpty { return Self.displaySource(text) }
        return detail?.authorSource ?? detail?.source ?? ""
    }
    var artifactUsage: LLMResponse.Usage? {
        if let activeTranscript { return activeTranscript.progress.usage }
        if artifactTab == .source, let turn = detail?.conversation.turns.last, turn.state != .completed {
            return transcripts[turn.id]?.progress.usage ?? turn.attempts.last?.usage
        }
        return selectedRevision?.generation?.usage
    }
    static func displaySource(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["```html", "```glsl", "```javascript"].contains(where: text.hasPrefix), let line = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: line)...])
            if text.hasSuffix("\n```") { text.removeLast(4) }
        }
        return text
    }
    func receiveStream(_ value: LLMStreamProgress) {
        streamProgress = value; activeTranscript?.receive(value)
    }
    func archiveTranscript(for turn: UUID) {
        guard var value = activeTranscript else { return }
        value.finish(); transcripts[turn] = value; transcriptOrder.removeAll { $0 == turn }; transcriptOrder.append(turn)
        activeTranscript = nil
        while transcriptOrder.count > 8 || transcripts.values.reduce(0, { $0 + $1.byteCount }) > 8 * 1024 * 1024 {
            transcripts[transcriptOrder.removeFirst()] = nil
        }
    }
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
    var providerAdvancedExpanded = false
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
    var hasSourceChanges: Bool { sourceDraft.map { $0 != (detail?.authorSource ?? detail?.source ?? "") } ?? false }
    var isMasterOutput: Bool { selectedRevision?.generation == nil && detail?.engine != nil && detail?.conversation.turns.isEmpty == true }
    var canSave: Bool {
        guard !isBusy, !hasSourceChanges, let revision = selectedRevision else { return false }
        if let schema = detail?.parameterSchema, (try? schema.validate(parameters)) == nil { return false }
        if let id = detail?.specification?.templateID, let definition = try? CreatorTemplateCatalog.definition(id), (try? definition.validate(parameters)) == nil { return false }
        return detail?.reports[revision.id]?.allowsPublication == true
    }
    var canApply: Bool { canSave }
    var profile: ProviderProfile? { configuration.profiles.first { $0.id == configuration.selectedProfileID } }
    var canGenerate: Bool { (mode != .code || CreatorCodeProcess.supported) && recovered && !isBusy && profile != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && prompt.utf8.count <= 2048 }
    func cancel() { operation?.cancel(); connection?.cancel() }
    func close() { cancel(); preview?.close(); preview = nil; embedded.close(); activeTranscript = nil; transcripts = [:]; transcriptOrder = [] }
}
