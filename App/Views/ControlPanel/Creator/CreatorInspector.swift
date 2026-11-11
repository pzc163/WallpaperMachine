import SwiftUI

struct CreatorInspector: View {
    @Environment(PanelController.self) private var controller
    @Environment(\.panelTheme) private var theme
    var body: some View {
        let model = controller.creator
        Group {
            if let detail = model.detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let revision = model.selectedRevision, revision.posterDigest != nil {
                            PanelImage(source: controller.creatorSelectedPoster, pointSize: 420)
                                .aspectRatio(16.0 / 9, contentMode: .fit)
                        }
                        Button("Open preview") { controller.launch { try await controller.openCreatorPreview() } }
                            .disabled(model.selectedRevision == nil || model.isBusy).accessibilityIdentifier("creator-preview-open")
                        Text("Preview starts muted and never changes the desktop.").font(.caption).foregroundStyle(.secondary)
                        Text("Revision history").font(.system(size: 13, weight: .semibold))
                        ForEach(detail.revisions.filter { detail.reports[$0.id]?.allowsPublication == true || $0.bundleVersion == 1 }, id: \.id) { revision in
                            Button {
                                controller.launch(PanelActionCoordinator.key("creator.rollback")) { try await controller.rollbackCreator(revision.id) }
                            } label: {
                                HStack {
                                    Text("Version \(String((detail.project.revisionIDs.firstIndex(of: revision.id) ?? 0) + 1))").font(.system(size: 12))
                                    Spacer(minLength: 4)
                                    if revision.id == detail.project.selectedRevisionID { Image(systemName: "checkmark").accessibilityLabel(Text("Selected")) }
                                }
                            }.buttonStyle(.plain).disabled(model.isBusy).accessibilityLabel(Text("Switch revision")).accessibilityValue(Text("Version \(String((detail.project.revisionIDs.firstIndex(of: revision.id) ?? 0) + 1))"))
                        }
                        if let template = detail.specification?.templateID,
                           let definition = try? CreatorTemplateCatalog.definition(template) {
                            Divider()
                            Text("Template properties").font(.system(size: 13, weight: .semibold))
                            Menu("Presets") {
                                ForEach(definition.presets, id: \.id) { preset in
                                    Button {
                                        controller.launch(PanelActionCoordinator.key("creator.parameters"), policy: .latestWins) {
                                            try controller.applyCreatorPreset(preset.id, templateID: definition.id)
                                        }
                                    } label: {
                                        HStack {
                                            Text(verbatim: PanelLocale.shared.catalogString(preset.label))
                                            if model.parameters == preset.parameters { Image(systemName: "checkmark") }
                                        }
                                    }.accessibilityIdentifier("creator-preset-" + preset.id)
                                }
                            }.disabled(model.isBusy).accessibilityIdentifier("creator-presets")
                            Text("Presets replace all parameters. Validate changes before saving.").font(.caption).foregroundStyle(.secondary)
                            ForEach(definition.parameters, id: \.id) { parameter in CreatorParameterControl(parameter: parameter) }
                            Button("Validate changes") { controller.launch { try await controller.validateCreatorParameters() } }
                                .disabled(!model.hasParameterChanges || model.isBusy).accessibilityIdentifier("creator-validate-parameters")
                        }
                        if let schema = detail.parameterSchema { Divider(); CreatorDynamicParameters(schema: schema) }
                        if detail.specification?.kind == .code {
                            Text("Free code · HTML5 / Canvas / WebGL").font(.caption).foregroundStyle(.secondary)
                            Text("Use conversation to revise the code; validated history stays available.").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        if let elapsed = model.elapsed { LabeledContent("Elapsed time", value: Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond))) }
                        LabeledContent("Tokens", value: usageText)
                        if let modelID = model.selectedRevision?.modelID { Text(verbatim: modelID).font(.caption).foregroundStyle(.secondary) }
                        Button("Save to wallpaper library") { controller.launch(PanelActionCoordinator.key("creator.publish")) { try await controller.saveCreatorToLibrary() } }
                            .buttonStyle(.panelPrimary).disabled(!model.canSave).accessibilityIdentifier("creator-save-library")
                        Button("Apply to display") { controller.launch(PanelActionCoordinator.key("creator.apply")) { try await controller.applyCreatorToDisplay() } }
                            .buttonStyle(.panelSecondary).disabled(!model.canApply).accessibilityIdentifier("creator-apply-display")
                        Text("Saving keeps the current desktop. Apply is a separate action for the selected display.").font(.caption).foregroundStyle(.secondary)
                    }.padding(16)
                }
            } else { PanelEmptyState("Select a project", systemImage: "sparkles", description: "History, preview and template properties appear here.") }
        }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity).background(theme.surface.background.color)
         .accessibilityIdentifier("creator-inspector")
    }
    private var usageText: String {
        guard let usage = controller.creator.detail?.conversation.turns.last?.attempts.last?.usage,
              let total = usage.totalTokens ?? usage.inputTokens.flatMap({ input in usage.outputTokens.map { input + $0 } }) else { return L("Unknown") }
        return String(total)
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
                Toggle(isOn: Binding(get: { controller.creator.parameters[parameter.id] == .bool(true) }, set: { set(.bool($0)) })) { Text(verbatim: PanelLocale.shared.catalogString(parameter.label)) }.toggleStyle(.switch)
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
