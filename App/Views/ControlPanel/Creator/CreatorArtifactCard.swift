import SwiftUI
import UniformTypeIdentifiers

struct CreatorArtifactCard: View {
    @Environment(PanelController.self) private var controller
    private var identity: String {
        let model = controller.creator
        return (model.selectedRevision?.id.uuidString ?? "") + ":\(model.isBusy):\(controller.presentation.isVisible):\(model.artifactTab.rawValue)"
    }
    var body: some View {
        let model = controller.creator
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) { HStack { toolbar }; VStack(alignment: .leading, spacing: 8) { toolbar } }
                Group {
                    if model.artifactTab == .source {
                        CreatorStreamTextView(text: model.artifactSource, onEdit: !model.isBusy && model.detail?.specification?.kind == .code ? { model.sourceDraft = $0 } : nil)
                            .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityIdentifier("creator-source")
                    } else if model.embedded.state == .failed {
                        VStack { Text("Preview failed. Close the window and try again.").foregroundStyle(.secondary); Button("Retry") { model.embedded.close(); refresh() } }
                    } else if let view = model.embedded.view {
                        GeometryReader { geometry in
                            let width = min(geometry.size.width, geometry.size.height * model.stageAspect.ratio)
                            CreatorArtifactHost(content: view).id(model.embedded.revisionID)
                                .frame(width: width, height: width / model.stageAspect.ratio)
                                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                        }.accessibilityIdentifier("creator-embedded-preview")
                    } else {
                        Text("Rendering starts after static and sandbox checks pass.").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                ViewThatFits(in: .horizontal) { HStack { footer }; VStack(alignment: .leading, spacing: 8) { footer } }
            }.padding(14)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: controller.dropCreatorMedia)
        .onAppear { model.artifactVisible = true; refresh() }
        .onChange(of: identity) { _, _ in refresh() }
        .onDisappear { controller.hideCreatorArtifact() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("creator-artifact")
    }
    @ViewBuilder private var toolbar: some View {
        let model = controller.creator
        Picker("Wallpaper artifact", selection: Binding(get: { model.artifactTab }, set: { tab in
            controller.launch(PanelActionCoordinator.key("creator.artifact"), policy: .latestWins) { try await controller.setCreatorArtifactTab(tab) }
        })) {
            Text("Rendered result").tag(CreatorModel.ArtifactTab.render).disabled(model.isBusy || model.selectedRevision == nil)
            Text("Source code").tag(CreatorModel.ArtifactTab.source)
        }.pickerStyle(.segmented).frame(maxWidth: 280).accessibilityIdentifier("creator-artifact-tab")
        Spacer(minLength: 4)
        Picker("Preview aspect ratio", selection: Binding(get: { model.stageAspect }, set: { model.stageAspect = $0 })) {
            ForEach(CreatorPreviewWindow.Aspect.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
        }.labelsHidden().frame(width: 82).accessibilityLabel(Text("Preview aspect ratio"))
        Button { controller.launch { try controller.muteCreatorArtifact() } } label: {
            Image(systemName: model.embedded.muted ? "speaker.slash" : "speaker.wave.2")
        }.help(L("Mute preview")).accessibilityLabel(Text("Mute preview")).disabled(model.embedded.view == nil)
        Button("Open separate preview") { controller.launch { try await controller.openCreatorPreview() } }
            .disabled(model.isBusy || model.selectedRevision == nil).accessibilityIdentifier("creator-artifact-window")
    }
    @ViewBuilder private var footer: some View {
        let model = controller.creator
        if model.artifactTab == .render && model.embedded.view != nil {
            Button { controller.launch { try controller.pauseCreatorArtifact() } } label: {
                Text(verbatim: model.embedded.paused ? L("Resume preview") : L("Pause preview"))
            }.accessibilityIdentifier("creator-artifact-pause")
        }
        if model.artifactTab == .source {
            Text(verbatim: String(format: L("%lld lines · %lld bytes"), model.artifactSource.isEmpty ? 0 : model.artifactSource.utf8.filter { $0 == 10 }.count + 1, model.artifactSource.utf8.count))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { controller.copyCreatorSource() } label: { Label("Copy code", systemImage: "doc.on.doc") }
                .disabled(model.artifactSource.isEmpty).accessibilityIdentifier("creator-copy-source")
            Button("Run changes") { controller.launch { try await controller.runCreatorSource() } }
                .keyboardShortcut("r", modifiers: .command).disabled(model.isBusy || !model.hasSourceChanges)
                .accessibilityIdentifier("creator-run-source")
        }
        Spacer(minLength: 4)
        if model.isMasterOutput { Text("Master output · 0 tokens").font(.caption).foregroundStyle(.secondary) }
        else {
            let usage = model.artifactUsage
            Text(verbatim: L("Tokens") + ": " + ((usage?.totalTokens ?? usage?.inputTokens.flatMap { input in usage?.outputTokens.map { input + $0 } }).map(String.init) ?? L("Unknown")))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        controller.launch(PanelActionCoordinator.key("creator.artifact"), policy: .latestWins) { try await controller.refreshCreatorArtifact() }
    }
}

private struct CreatorArtifactHost: NSViewRepresentable {
    let content: NSView
    func makeNSView(context: Context) -> NSView { content }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
