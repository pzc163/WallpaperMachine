import AppKit

extension PanelController {
    func revealCreatorDiagnostic(_ diagnostic: CreatorSourceDiagnostic) {
        guard !creator.isBusy, let line = CreatorDiagnosticPresentation.displayLine(diagnostic, in: creator.diagnosticSource) else { return }
        creator.artifactTab = .source; creator.sourceFocus = .init(line: line); creator.embedded.close()
    }
    func copyCreatorDiagnostic(to pasteboard: NSPasteboard = .general) {
        guard let issue = creator.issue else { return }
        pasteboard.clearContents(); pasteboard.setString(CreatorDiagnosticPresentation.copiedReport(issue), forType: .string)
    }
    func refreshCreatorArtifact() async throws {
        if creator.isBusy && creator.phase == .saving && creator.artifactVisible { return }
        guard creator.artifactVisible, presentation.isVisible, !creator.isBusy, creator.artifactTab == .render,
              let project = creator.selectedProjectID, let revision = creator.selectedRevision,
              creator.detail?.reports[revision.id]?.allowsPublication == true else { creator.embedded.close(); return }
        guard creator.embedded.revisionID != revision.id else { return }
        let target = creator.embedded
        do {
            try await target.open(project: project, revision: revision.id, store: creatorWorkspace.store)
            guard creator.artifactVisible, presentation.isVisible, !creator.isBusy, creator.artifactTab == .render,
                  creator.selectedProjectID == project, creator.selectedRevision?.id == revision.id else { target.close(); return }
            try target.properties(creator.parameters)
        } catch is CancellationError { /* The surface generation owns its own cleanup. */ }
        catch { throw CreatorPanelFailure(message: L("Preview failed. Close the window and try again.")) }
    }
    func setCreatorArtifactTab(_ tab: CreatorModel.ArtifactTab) async throws {
        creator.artifactTab = tab
        try await refreshCreatorArtifact()
    }
    func hideCreatorArtifact() { creator.artifactVisible = false; creator.embedded.close() }
    func pauseCreatorArtifact() throws { try creator.embedded.pause(!creator.embedded.paused) }
    func muteCreatorArtifact() throws { try creator.embedded.mute(!creator.embedded.muted) }
    func copyCreatorSource(to pasteboard: NSPasteboard = .general) {
        let source = creator.artifactSource
        guard !source.isEmpty else { return }
        pasteboard.clearContents(); pasteboard.setString(source, forType: .string)
    }
}
