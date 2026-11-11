import AppKit
import SwiftUI

struct CreatorPreviewContent: View {
    let preview: CreatorPreviewWindow
    @Environment(PanelController.self) private var controller
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                if preview.failure { Text("Preview failed. Close the window and try again.").padding() }
                else if let view = preview.contentView {
                    CreatorPreviewHost(content: view)
                        .frame(width: min(geometry.size.width, geometry.size.height * preview.aspect.ratio),
                               height: min(geometry.size.height, geometry.size.width / preview.aspect.ratio))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Button {
                    controller.launch(PanelActionCoordinator.key("creator.preview.pause")) {
                        try controller.pauseCreatorPreview(!preview.paused)
                    }
                } label: { Text(verbatim: preview.paused ? L("Resume preview") : L("Pause preview")) }
                .accessibilityIdentifier("creator-preview-pause")
                Label("Muted", systemImage: "speaker.slash").font(.caption)
                Spacer(minLength: 8)
                Picker("Aspect ratio", selection: Binding(get: { preview.aspect }, set: { controller.setCreatorPreviewAspect($0) })) {
                    ForEach(CreatorPreviewWindow.Aspect.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
                }.frame(maxWidth: 180).accessibilityIdentifier("creator-preview-aspect")
            }.padding(10)
        }
    }
}
private struct CreatorPreviewHost: NSViewRepresentable {
    let content: NSView
    func makeNSView(context: Context) -> NSView { content }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
