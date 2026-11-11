import SwiftUI

struct CreatorInspiration: View {
    @Environment(PanelController.self) private var controller
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Describe a scene. Preview it before saving.").font(.subheadline).foregroundStyle(.secondary)
            suggestion("Interactive violet ink", prompt: "Create violet fluid ink on a pure black background that softly follows the pointer.", icon: "drop", mode: .code)
            suggestion("Silky shader aurora", prompt: "Create a smooth teal and violet aurora with subtle grain and slow flowing light.", icon: "waveform.path", mode: .template)
            suggestion("Deep-space particles", prompt: "Create a black deep-space starfield with layered parallax, soft nebulae and occasional meteors.", icon: "sparkles", mode: .template)
            suggestion("Quiet midnight clock", prompt: "Create a minimal midnight clock at the bottom right with a soft blue glow and generous margins.", icon: "clock", mode: .template)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("creator-inspiration")
    }
    private func suggestion(_ title: String, prompt: String, icon: String, mode: CreatorCreationMode) -> some View {
        Button {
            controller.launch { try await controller.useCreatorInspiration(PanelLocale.shared.catalogString(prompt), mode: mode) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: PanelLocale.shared.catalogString(title)).font(.system(size: 13, weight: .medium))
                    Text(verbatim: PanelLocale.shared.catalogString(prompt)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left").foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(controller.creator.isBusy)
    }
}
