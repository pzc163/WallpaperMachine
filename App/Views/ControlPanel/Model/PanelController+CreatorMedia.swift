import AppKit
import UniformTypeIdentifiers

extension PanelController {
    func chooseCreatorMedia() async throws {
        guard !creator.isBusy else { throw CreatorGenerationFailure.busy }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Array(CreatorMediaAnalysis.imageExtensions.union(CreatorMediaAnalysis.videoExtensions)).sorted().compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if let url = await dialogs.choose(panel) { try await importCreatorMedia(url) }
    }
    func importCreatorMedia(_ url: URL) async throws {
        guard url.isFileURL else { throw CreatorGenerationFailure.invalidRequest }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        try await creatorOperation(.runtime) {
            self.creator.selectedProjectID = try await self.creatorWorkspace.importMedia(url, projectID: self.creator.selectedProjectID)
            self.creator.showsGallery = false; self.creator.artifactTab = .render; self.creator.sendsThumbnail = false
        }
    }
    func pasteCreatorMediaIfAvailable() -> Bool {
        guard !creator.isBusy, NSPasteboard.general.availableType(from: [.png, .tiff]) != nil else { return false }
        launch { try await self.pasteCreatorMedia() }; return true
    }
    func pasteCreatorMedia(_ pasteboard: NSPasteboard = .general) async throws {
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return }
        try await creatorOperation(.runtime) {
            self.creator.selectedProjectID = try await self.creatorWorkspace.pasteImage(data, projectID: self.creator.selectedProjectID)
            self.creator.showsGallery = false; self.creator.artifactTab = .render; self.creator.sendsThumbnail = false
        }
    }
    func prepareCreatorLibraryMedia() async throws { creator.libraryMedia = try await creatorWorkspace.libraryMedia(); creator.showsMediaLibrary = true }
    func importCreatorLibraryMedia(_ id: String) async throws {
        creator.showsMediaLibrary = false
        try await creatorOperation(.runtime) {
            self.creator.selectedProjectID = try await self.creatorWorkspace.importLibraryMedia(id, projectID: self.creator.selectedProjectID)
            self.creator.showsGallery = false; self.creator.artifactTab = .render; self.creator.sendsThumbnail = false
        }
    }
    /// The view passes drag providers; URL decoding and import remain controller operations.
    func dropCreatorMedia(_ providers: [NSItemProvider]) -> Bool {
        guard !creator.isBusy, let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return }
            Task { @MainActor in self?.launch { [weak self] in try await self?.importCreatorMedia(url) } }
        }
        return true
    }
    func exportCreatorProject() async throws {
        guard let project = creator.selectedProjectID, let revision = creator.selectedRevision, !creator.isBusy, !creator.hasSourceChanges else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Wallpaper.wmpkg"
        panel.allowedContentTypes = [UTType(filenameExtension: "wmpkg") ?? .data]
        guard let url = await dialogs.choose(panel) else { return }
        let values = creator.parameters, changed = creator.hasParameterChanges
        try await creatorOperation(.saving) {
            let target: UUID
            if changed { target = try await self.creatorWorkspace.edit(project: project, revision: revision.id, parameters: values).id }
            else { target = revision.id }
            try await self.creatorWorkspace.exportProject(project, revision: target, to: url)
        }
    }
    func importCreatorProject() async throws {
        guard !creator.isBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "wmpkg") ?? .data]; panel.allowsMultipleSelection = false
        guard let url = await dialogs.choose(panel) else { return }
        try await creatorOperation(.runtime) {
            self.creator.selectedProjectID = try await self.creatorWorkspace.importProject(url)
            self.creator.showsGallery = false; self.creator.artifactTab = .render; self.creator.sendsThumbnail = false
        }
    }
}
