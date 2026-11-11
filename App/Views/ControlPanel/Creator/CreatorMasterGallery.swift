import SwiftUI

@MainActor enum CreatorEngineLabels {
    static func title(_ engine: CreatorEngine) -> String {
        switch engine {
        case .shaderGLSL: L("Pure Shader · GLSL")
        case .three3D: L("Three.js · 3D light")
        case .htmlCanvas: L("HTML5 · Canvas")
        case .hybridImage: L("Hybrid image animation")
        case .scene25D: L("2.5D scene")
        case .audioReactive: L("Audio reactive")
        }
    }
}

struct CreatorMasterGallery: View {
    @Environment(PanelController.self) private var controller
    var body: some View {
        let model = controller.creator
        VStack(alignment: .leading, spacing: 12) {
            Text("Start with a master").font(.headline)
            Text("Preview locally, adjust parameters, or describe a new direction. No model request is needed to open a master.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Creation engine", selection: Binding(get: { model.engine }, set: { engine in
                controller.launch { try await controller.setCreatorEngine(engine) }
            })) {
                ForEach(CreatorEngine.allCases.filter(\.available), id: \.self) { engine in
                    Text(verbatim: CreatorEngineLabels.title(engine)).tag(engine)
                }
            }.pickerStyle(.menu).accessibilityIdentifier("creator-gallery-engine")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(model.masters.filter { $0.engine == model.engine }) { master in
                    Button {
                        controller.launch(PanelActionCoordinator.key("creator.master")) { try await controller.openCreatorMaster(master.id) }
                    } label: {
                        PanelCard {
                            VStack(alignment: .leading, spacing: 8) {
                                PanelImage(source: model.masterPosters[master.id], pointSize: 280).aspectRatio(16/9, contentMode: .fit).clipped()
                                Text(verbatim: PanelLocale.shared.catalogString(master.title)).font(.system(size: 13, weight: .semibold)).lineLimit(2).padding(.horizontal, 10)
                                Text("Preview and customize").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 10)
                            }
                        }
                    }.buttonStyle(.plain).accessibilityLabel(Text(verbatim: PanelLocale.shared.catalogString(master.title)))
                        .accessibilityIdentifier("creator-master-" + master.id)
                }
            }
        }.disabled(model.isBusy).accessibilityElement(children: .contain).accessibilityIdentifier("creator-master-gallery")
    }
}
