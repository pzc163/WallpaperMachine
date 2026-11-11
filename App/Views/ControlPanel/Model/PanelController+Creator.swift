import Foundation

extension PanelController {
    func recoverCreator() async throws {
        guard !creator.recovered else { return }
        if let recovery = creator.recoveryTask { _ = try await recovery.value; try await loadCreator(); creator.recovered = true; return }
        let task = Task { try await creatorWorkspace.recover() }
        creator.recoveryTask = task
        defer { creator.recoveryTask = nil }
        try await run(.immediate) {
            creator.recovery = try await task.value
            try await loadCreator()
            creator.recovered = true
        }
    }
    func loadCreator() async throws {
        let projects = try await creatorWorkspace.projects()
        let configuration = try await creatorWorkspace.configuration()
        let selected = creator.selectedProjectID
        let detail: CreatorWorkspace.Detail?
        if let selected, projects.contains(where: { $0.id == selected }) { detail = try await creatorWorkspace.detail(selected) }
        else { detail = nil }
        try Task.checkCancellation()
        if creator.detail?.project.id != detail?.project.id || creator.detail?.project.selectedRevisionID != detail?.project.selectedRevisionID {
            creator.preview?.close(); creator.preview = nil
        }
        creator.projects = projects; creator.configuration = configuration; creator.detail = detail
        creator.selectedProjectID = detail?.project.id
        creator.parameters = detail?.specification?.parameters ?? [:]
        if let mode = detail?.specification?.creationMode ?? detail?.conversation.turns.last?.creationMode { creator.mode = mode }
        if !creator.isBusy {
            creator.issue = detail?.conversation.turns.last?.failure
            creator.phase = creator.issue == nil ? (creator.selectedRevision == nil ? .idle : .ready) : .failed
        }
    }
    func selectCreatorProject(_ id: UUID?) async throws {
        guard !creator.isBusy else { throw CreatorGenerationFailure.busy }
        creator.preview?.close(); creator.preview = nil
        creator.selectedProjectID = id
        try await run(.immediate) { try await loadCreator() }
    }
    func setCreatorMode(_ mode: CreatorCreationMode) async throws {
        guard !creator.isBusy else { throw CreatorGenerationFailure.busy }
        if mode == .code && !CreatorCodeProcess.supported { throw CreatorPanelFailure(message: L("Free code is unavailable on this WebKit version.")) }
        guard creator.mode != mode else { return }
        try await selectCreatorProject(nil)
        creator.mode = mode
    }
    func newCreatorProject() async throws {
        try await creatorOperation(.editing) {
            self.creator.selectedProjectID = try await self.creatorWorkspace.create(title: L("Untitled project"))
        }
    }
    func renameCreatorProject(_ id: UUID, title: String) async throws {
        try await creatorOperation(.editing) { try await self.creatorWorkspace.rename(id, title: title) }
    }
    func duplicateCreatorProject(_ id: UUID) async throws {
        guard let title = creator.projects.first(where: { $0.id == id })?.title else { return }
        try await creatorOperation(.editing) {
            self.creator.selectedProjectID = try await self.creatorWorkspace.duplicate(id, title: String(title.prefix(50)) + " · " + L("Copy"))
        }
    }
    func deleteCreatorProject(_ id: UUID) async throws {
        guard await dialogs.confirm(L("Delete this draft?"), detail: L("Published wallpapers stay in the library. Local conversation and revision history will be deleted."), button: L("Delete draft")) else { return }
        try await creatorOperation(.editing) {
            try await self.creatorWorkspace.delete(id)
            if self.creator.selectedProjectID == id { self.creator.preview?.close(); self.creator.preview = nil; self.creator.selectedProjectID = nil }
        }
    }
    func generateCreator() async throws {
        guard creator.canGenerate, let profile = creator.profile else { throw CreatorGenerationFailure.invalidRequest }
        let prompt = creator.prompt, base = creator.detail?.project.selectedRevisionID
        let repairs = creator.autoRepair ? creator.maxRepairs : 0
        try await creatorOperation(.generating) {
            if self.creator.selectedProjectID == nil { self.creator.selectedProjectID = try await self.creatorWorkspace.create(title: L("Untitled project")) }
            let token = self.creator.operationID
            var request = CreatorOrchestrator.Request(projectID: self.creator.selectedProjectID, baseRevisionID: base,
                profileID: profile.id, configurationID: profile.configurationID, prompt: prompt,
                maxOutputTokens: profile.limits.outputTokensPerRequest, maxRepairs: repairs, mode: self.creator.mode)
            request.progress = { [self] stage, attempt, limit in
                await MainActor.run {
                    guard self.creator.operationID == token else { return }
                    self.creator.attempt = attempt; self.creator.attemptLimit = limit
                    switch stage {
                    case .generating: self.creator.phase = .generating
                    case .repairPending: self.creator.phase = .repairPending
                    case .runtime: self.creator.phase = .runtime
                    case .sealing: self.creator.phase = .sealing
                    case .publishing: self.creator.phase = .saving
                    case .completed: self.creator.phase = .ready
                    }
                    self.shell.say(CreatorLabels.phase(self.creator.phase))
                }
            }
            _ = try await self.creatorWorkspace.generate(request)
        }
    }
    func cancelCreator() { creator.cancel() }
    func rollbackCreator(_ revision: UUID) async throws {
        guard let project = creator.selectedProjectID else { return }
        try await creatorOperation(.editing) {
            self.creator.preview?.close(); self.creator.preview = nil
            try await self.creatorWorkspace.select(project: project, revision: revision)
        }
    }
    func setCreatorParameter(_ id: String, value: CreatorTemplateCatalog.Value) throws {
        guard let template = creator.detail?.specification?.templateID else { throw CreatorGenerationFailure.invalidRequest }
        var values = creator.parameters; values[id] = value
        try setCreatorParameters(values, templateID: template)
    }
    func applyCreatorPreset(_ id: String, templateID: String) throws {
        guard let preset = try CreatorTemplateCatalog.definition(templateID).presets.first(where: { $0.id == id }) else {
            throw CreatorGenerationFailure.invalidRequest
        }
        try setCreatorParameters(preset.parameters, templateID: templateID)
    }
    private func setCreatorParameters(_ values: [String: CreatorTemplateCatalog.Value], templateID: String) throws {
        try Task.checkCancellation()
        guard !creator.isBusy, creator.detail?.specification?.templateID == templateID else { throw CreatorGenerationFailure.invalidRequest }
        try CreatorTemplateCatalog.definition(templateID).validate(values)
        creator.parameters = values
        try creator.preview?.properties(values)
    }
    func validateCreatorParameters() async throws {
        guard let project = creator.selectedProjectID, let revision = creator.selectedRevision else { return }
        let values = creator.parameters
        try await creatorOperation(.runtime) {
            self.creator.preview?.close(); self.creator.preview = nil
            _ = try await self.creatorWorkspace.edit(project: project, revision: revision.id, parameters: values)
        }
    }
    func saveCreatorToLibrary() async throws {
        guard creator.canSave, let project = creator.selectedProjectID, let revision = creator.selectedRevision else { throw CreatorGenerationFailure.invalidRequest }
        try await creatorOperation(.saving) { _ = try await self.creatorWorkspace.publish(project: project, revision: revision.id) }
        creator.phase = .saved
        try await refresh()
    }
    func applyCreatorToDisplay() async throws {
        guard creator.canApply, let project = creator.selectedProjectID, let revision = creator.selectedRevision else { throw CreatorGenerationFailure.invalidRequest }
        let id = try await creatorWorkspace.installedWallpaper(project: project, revision: revision.id)
        try await activate(id)
    }
    var creatorSelectedPoster: PanelImageSource? {
        guard let revision = creator.selectedRevision, revision.posterDigest != nil else { return nil }
        return .creatorPoster(bundle: creatorWorkspace.store.bundleURL(projectID: revision.projectID, revisionID: revision.id), digest: revision.bundleDigest)
    }
    func openCreatorPreview() async throws {
        guard !creator.isBusy, let project = creator.selectedProjectID, let revision = creator.selectedRevision,
              creator.detail?.reports[revision.id]?.allowsPreview == true else { return }
        try await run(.immediate) {
            guard dialogs.presentingWindow != nil else { return }
            creator.preview?.close()
            let preview = CreatorPreviewWindow()
            creator.preview = preview
            try await preview.open(project: project, revision: revision.id, store: creatorWorkspace.store, controller: self)
            try preview.properties(creator.parameters)
        }
    }
    func pauseCreatorPreview(_ paused: Bool) throws { try creator.preview?.pause(paused) }
    func setCreatorPreviewAspect(_ aspect: CreatorPreviewWindow.Aspect) { creator.preview?.setAspect(aspect) }
    func saveCreatorProfile(_ profile: ProviderProfile, key: String, expectedRevision: Int) async throws {
        creator.connectionNotice = nil
        creator.cancel()
        try await run(.immediate) {
            do { creator.configuration = try await creatorWorkspace.saveProfile(profile, key: key, expectedRevision: expectedRevision) }
            catch {
                creator.configuration = try await creatorWorkspace.configuration()
                throw CreatorPanelFailure(message: CreatorLabels.issue(.staleInput))
            }
        }
    }
    func selectCreatorProfile(_ id: UUID) async throws {
        creator.connectionNotice = nil
        creator.configuration = try await creatorWorkspace.selectProfile(id, expectedRevision: creator.configuration.revision)
    }
    func deleteCreatorProfile(_ id: UUID) async throws {
        creator.connectionNotice = nil
        guard await dialogs.confirm(L("Delete model connection?"), detail: L("Its saved key will also be removed."), button: L("Delete")) else { return }
        creator.cancel()
        creator.configuration = try await creatorWorkspace.removeProfile(id, expectedRevision: creator.configuration.revision)
    }
    func cancelCreatorConnection() { creator.connectionNotice = nil; creator.connection?.cancel() }
    func testCreatorConnection(_ profile: ProviderProfile) async throws {
        guard !creator.isTestingConnection else { return }
        let detail = profile.baseURL + "\n" + profile.model + "\n\n" + L("This tests the saved model and may negotiate output modes within your request and token budgets. Requests may incur charges. You can cancel at any time.")
        guard await dialogs.confirm(L("Test model connection?"), detail: detail, button: L("Test connection")) else { return }
        creator.isTestingConnection = true; creator.connectionStatus = nil; creator.connectionNotice = nil
        let task = Task { try await creatorWorkspace.testConnection(profile) }
        creator.connection = task
        defer { creator.connection = nil; creator.isTestingConnection = false }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            let latest = try await creatorWorkspace.configuration()
            guard !task.isCancelled, latest.profiles.contains(where: {
                $0.id == result.profileID && $0.configurationID == result.configurationID
            }) else { throw LLMFailure.staleProfile }
            creator.connectionStatus = L("Connection succeeded")
            creator.connectionNotice = result
        } catch {
            let issue = CreatorRepairIssue.from(error)
            creator.connectionStatus = CreatorLabels.issue(issue.category)
            throw CreatorPanelFailure(message: CreatorLabels.issue(issue.category))
        }
    }
    private func creatorOperation(_ phase: CreatorModel.Phase, operation: @escaping @MainActor () async throws -> Void) async throws {
        guard !creator.isBusy else { throw CreatorGenerationFailure.busy }
        creator.isBusy = true; creator.phase = phase; creator.issue = nil; creator.attempt = 0
        creator.operationID = UUID()
        let started = ContinuousClock.now
        let task = Task { try await operation() }
        creator.operation = task
        defer {
            creator.operation = nil; creator.isBusy = false
            creator.elapsed = Double(started.duration(to: .now).components.seconds) + Double(started.duration(to: .now).components.attoseconds) / 1e18
        }
        do {
            try await run(.immediate) {
                try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try await loadCreator()
                creator.phase = creator.selectedRevision == nil ? .idle : .ready
            }
        } catch {
            let issue = (error as? CreatorOrchestrator.Failure)?.issue ?? CreatorRepairIssue.from(error)
            creator.issue = issue; creator.phase = issue.category == .cancelled ? .cancelled : .failed
            // Reload the last usable selection without inheriting the operation's cancellation.
            let reload = Task { try await self.loadCreator() }
            do { try await reload.value } catch { creator.issue = .init(category: .storage) }
            throw CreatorPanelFailure(message: CreatorLabels.issue(creator.issue?.category ?? .storage))
        }
    }
}

struct CreatorPanelFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
