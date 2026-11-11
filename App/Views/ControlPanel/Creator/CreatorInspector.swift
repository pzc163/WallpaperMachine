import SwiftUI

struct CreatorInspector: View {
    @Environment(PanelController.self) private var controller
    @Environment(\.panelTheme) private var theme
    @State private var history = false
    var body: some View {
        let model = controller.creator
        VStack(spacing: 0) {
            if let detail = model.detail {
                Picker("Inspector content", selection: $history) {
                    Text("Parameters and assets").tag(false)
                    Text("Revision history").tag(true)
                }.pickerStyle(.segmented).padding(12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if history { revisions(detail) }
                        else {
                            if let template = detail.specification?.templateID, let definition = try? CreatorTemplateCatalog.definition(template) {
                                Text("Template properties").font(.headline)
                                Menu("Presets") {
                                    ForEach(definition.presets, id: \.id) { preset in
                                        Button { controller.launch { try controller.applyCreatorPreset(preset.id, templateID: definition.id) } } label: {
                                            Text(verbatim: PanelLocale.shared.catalogString(preset.label))
                                        }.accessibilityIdentifier("creator-preset-" + preset.id)
                                    }
                                }.disabled(model.isBusy).accessibilityIdentifier("creator-presets")
                                ForEach(definition.parameters, id: \.id) { parameter in CreatorParameterControl(parameter: parameter) }
                            }
                            if detail.media != nil { CreatorMediaControls() }
                            if let schema = detail.parameterSchema { CreatorDynamicParameters(schema: schema) }
                            if detail.parameterSchema != nil || detail.specification?.templateID != nil {
                                Button("Reset default parameters") { controller.launch { try controller.resetCreatorParameters() } }
                                    .disabled(model.isBusy).accessibilityIdentifier("creator-reset-parameters")
                                Text("Parameters update live. Saving seals a new version without another model request.").font(.caption).foregroundStyle(.secondary)
                            }
                            if let elapsed = model.elapsed { LabeledContent("Elapsed time", value: Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond))) }
                            if let modelID = model.selectedRevision?.modelID { Text(verbatim: modelID).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                VStack(spacing: 10) {
                    Button("Save to wallpaper library") { controller.launch(PanelActionCoordinator.key("creator.publish")) { try await controller.saveCreatorToLibrary() } }
                        .buttonStyle(.panelPrimary).disabled(!model.canSave).accessibilityIdentifier("creator-save-library")
                    Button("Apply to display") { controller.launch(PanelActionCoordinator.key("creator.apply")) { try await controller.applyCreatorToDisplay() } }
                        .buttonStyle(.panelSecondary).disabled(!model.canApply).accessibilityIdentifier("creator-apply-display")
                    Text("Saving keeps the current desktop. Apply is a separate action for the selected display.").font(.caption).foregroundStyle(.secondary)
                }.padding(16).accessibilityIdentifier("creator-publish-footer")
            } else { PanelEmptyState("Select a project", systemImage: "sparkles", description: "History, preview and template properties appear here.") }
        }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity).background(theme.surface.background.color)
         .accessibilityIdentifier("creator-inspector")
    }
    private func revisions(_ detail: CreatorWorkspace.Detail) -> some View {
        ForEach(detail.revisions.filter { detail.reports[$0.id]?.allowsPublication == true || $0.bundleVersion == 1 }, id: \.id) { revision in
            Button { controller.launch { try await controller.rollbackCreator(revision.id) } } label: {
                HStack {
                    Text("Version \(String((detail.project.revisionIDs.firstIndex(of: revision.id) ?? 0) + 1))").font(.system(size: 12))
                    Spacer(minLength: 4)
                    if revision.id == detail.project.selectedRevisionID { Image(systemName: "checkmark").accessibilityLabel(Text("Selected")) }
                }
            }.buttonStyle(.plain).disabled(controller.creator.isBusy).accessibilityLabel(Text("Switch revision"))
        }
    }
}

private struct CreatorParameterControl: View {
    let parameter: CreatorTemplateCatalog.Parameter
    @Environment(PanelController.self) private var controller
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: PanelLocale.shared.catalogString(parameter.label)).font(.system(size: 12))
            switch parameter.domain {
            case .number(let range, let step, _):
                HStack {
                    Slider(value: Binding(get: { if case .number(let value) = controller.creator.parameters[parameter.id] { return value }; return range.lowerBound },
                                          set: { set(.number($0)) }), in: range, step: step)
                    if case .number(let value) = controller.creator.parameters[parameter.id] {
                        Text(verbatim: value.formatted(.number.precision(.fractionLength(0...2)))).font(.caption.monospacedDigit()).frame(minWidth: 32)
                    }
                }
            case .bool:
                Toggle(isOn: Binding(get: { controller.creator.parameters[parameter.id] == .bool(true) }, set: { set(.bool($0)) })) { Text(verbatim: PanelLocale.shared.catalogString(parameter.label)) }.labelsHidden().toggleStyle(.switch)
            case .choice(let choices):
                Picker(selection: Binding(get: { if case .choice(let value) = controller.creator.parameters[parameter.id] { return value }; return "" }, set: { set(.choice($0)) })) {
                    ForEach(choices, id: \.value) { Text(verbatim: PanelLocale.shared.catalogString($0.label)).tag($0.value) }
                } label: { Text(verbatim: PanelLocale.shared.catalogString(parameter.label)) }.labelsHidden()
            }
        }.disabled(controller.creator.isBusy).accessibilityElement(children: .contain)
         .accessibilityLabel(Text(verbatim: PanelLocale.shared.catalogString(parameter.label))).accessibilityIdentifier("creator-parameter-" + parameter.id)
    }
    private func set(_ value: CreatorTemplateCatalog.Value) {
        controller.launch(PanelActionCoordinator.key("creator.parameters"), policy: .latestWins) { try controller.setCreatorParameter(parameter.id, value: value) }
    }
}
