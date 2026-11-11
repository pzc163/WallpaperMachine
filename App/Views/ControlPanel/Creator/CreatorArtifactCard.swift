import SwiftUI

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
                if model.artifactTab == .source {
                    if model.artifactSource.isEmpty {
                        Text("Source will appear as the model writes.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        CreatorStreamTextView(text: model.artifactSource).frame(height: 340)
                            .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityIdentifier("creator-source")
                    }
                } else if model.embedded.state == .failed {
                    Text("Preview failed. Close the window and try again.").foregroundStyle(.secondary)
                    Button("Retry") { model.embedded.close(); refresh() }
                } else if let view = model.embedded.view {
                    CreatorArtifactHost(content: view).id(model.embedded.revisionID).frame(height: 300).clipped()
                        .accessibilityIdentifier("creator-embedded-preview")
                } else {
                    Text("Rendering starts after static and sandbox checks pass.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
                ViewThatFits(in: .horizontal) { HStack { footer }; VStack(alignment: .leading, spacing: 8) { footer } }
            }.padding(14)
        }
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
        Text(verbatim: String(format: L("%lld lines · %lld bytes"), model.artifactSource.isEmpty ? 0 : model.artifactSource.utf8.filter { $0 == 10 }.count + 1, model.artifactSource.utf8.count))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        Button { controller.copyCreatorSource() } label: { Label("Copy code", systemImage: "doc.on.doc") }
            .disabled(model.artifactSource.isEmpty).accessibilityIdentifier("creator-copy-source")
    }
    @ViewBuilder private var footer: some View {
        let model = controller.creator
        if model.artifactTab == .render && model.embedded.view != nil {
            Button { controller.launch { try controller.pauseCreatorArtifact() } } label: {
                Text(verbatim: model.embedded.paused ? L("Resume preview") : L("Pause preview"))
            }.accessibilityIdentifier("creator-artifact-pause")
            Label("Muted", systemImage: "speaker.slash").font(.caption).foregroundStyle(.secondary)
        }
        let usage = model.artifactUsage
        Text(verbatim: L("Tokens") + ": " + ((usage?.totalTokens ?? usage?.inputTokens.flatMap { input in usage?.outputTokens.map { input + $0 } }).map(String.init) ?? L("Unknown")))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        Spacer(minLength: 4)
        Button("Open separate preview") { controller.launch { try await controller.openCreatorPreview() } }
            .disabled(model.isBusy || model.selectedRevision == nil).accessibilityIdentifier("creator-artifact-window")
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
