import SwiftUI

struct CreatorDynamicParameters: View {
    let schema: CreatorParameterSchema
    @Environment(PanelController.self) private var controller
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wallpaper parameters").font(.system(size: 13, weight: .semibold))
            ForEach(schema.parameters.filter { controller.creator.detail?.media == nil || !["mediaFill", "mediaExposure", "mediaSpeed"].contains($0.id) }) { p in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: PanelLocale.shared.catalogString(p.label)).font(.system(size: 12))
                    switch p.type {
                    case .number:
                        HStack {
                            Slider(value: Binding(get: { if case .number(let value) = controller.creator.parameters[p.id] { return value }; return p.min ?? 0 },
                                set: { set(p.id, .number($0)) }), in: (p.min ?? 0)...(p.max ?? 1), step: p.step ?? 0.01)
                            if case .number(let value) = controller.creator.parameters[p.id] {
                                Text(verbatim: value.formatted(.number.precision(.fractionLength(0...2)))).font(.caption.monospacedDigit()).frame(minWidth: 38)
                            }
                        }
                    case .boolean:
                        Toggle(isOn: Binding(get: { controller.creator.parameters[p.id] == .bool(true) }, set: { set(p.id, .bool($0)) })) {
                            Text(verbatim: PanelLocale.shared.catalogString(p.label))
                        }.labelsHidden().toggleStyle(.switch)
                    case .color:
                        ColorPicker(selection: Binding(get: {
                            guard case .choice(let hex) = controller.creator.parameters[p.id] else { return .white }
                            let rgb = CreatorParameterSchema.rgb(hex); return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
                        }, set: { value in
                            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                            let hex = String(format: "#%02x%02x%02x", Int((rgb.redComponent*255).rounded()), Int((rgb.greenComponent*255).rounded()), Int((rgb.blueComponent*255).rounded()))
                            set(p.id, .choice(hex))
                        }), supportsOpacity: false) { Text(verbatim: PanelLocale.shared.catalogString(p.label)) }.labelsHidden()
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("creator-dynamic-" + p.id)
            }

        }.disabled(controller.creator.isBusy)
    }
    private func set(_ id: String, _ value: CreatorTemplateCatalog.Value) {
        controller.launch(PanelActionCoordinator.key("creator.parameters"), policy: .latestWins) { try controller.setCreatorParameter(id, value: value) }
    }
}
