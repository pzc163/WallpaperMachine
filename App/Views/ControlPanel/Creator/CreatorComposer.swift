import SwiftUI

struct CreatorComposer: View {
    @Environment(PanelController.self) private var controller
    var body: some View {
        @Bindable var model = controller.creator
        VStack(alignment: .leading, spacing: 8) {
            PanelCard {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        CreatorPromptEditor(text: $model.prompt, focusID: model.composerFocusID, submit: send)
                            .disabled(model.isBusy)
                        if model.prompt.isEmpty {
                            Text("Describe your wallpaper or the changes you want").font(.system(size: 14)).foregroundStyle(.tertiary)
                                .padding(.top, 8).padding(.leading, 4).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    Divider()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { profiles; Spacer(minLength: 4); modes }
                        VStack(alignment: .leading, spacing: 8) { profiles; modes }
                    }.disabled(model.isBusy)
                    HStack(spacing: 6) {
                        Toggle("Auto repair", isOn: $model.autoRepair).toggleStyle(.checkbox).disabled(model.isBusy).accessibilityIdentifier("creator-auto-repair")
                        if model.autoRepair {
                            Picker("Repair limit", selection: $model.maxRepairs) { Text(verbatim: "1").tag(1); Text(verbatim: "2").tag(2) }
                                .labelsHidden().frame(width: 48).disabled(model.isBusy).accessibilityLabel(Text("Repair limit"))
                        }
                        if model.attempt > 0 { Text(verbatim: "\(model.attempt)/\(model.attemptLimit)").font(.caption.monospacedDigit()).accessibilityLabel(Text("Attempts")) }
                        Spacer(minLength: 4)
                        if model.isBusy {
                            Button { controller.cancelCreator() } label: { Image(systemName: "stop.fill").frame(width: 26, height: 22) }
                                .buttonStyle(.borderedProminent).clipShape(Capsule()).help(L("Stop")).accessibilityLabel(Text("Stop")).accessibilityIdentifier("creator-stop")
                        } else {
                            Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).frame(width: 26, height: 22) }
                                .buttonStyle(.borderedProminent).clipShape(Capsule()).disabled(!model.canGenerate)
                                .help(L("Generate")).accessibilityLabel(Text("Generate")).accessibilityIdentifier("creator-generate")
                        }
                    }.font(.system(size: 12))
                }.padding(12)
            }
            ViewThatFits(in: .horizontal) {
                HStack { shortcut; Spacer(minLength: 8); status }
                VStack(alignment: .leading, spacing: 4) { shortcut; status }
            }
            if model.prompt.utf8.count > 2048 { Text("Shorten the prompt to continue.").font(.caption).foregroundStyle(.secondary) }
            if model.profile == nil { Button("Configure a model connection") { controller.launch { try await controller.openSettings(.models) } } }
        }.padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 8)
    }
    private var shortcut: some View { Text("Enter to send · Shift + Enter for a new line").font(.caption).foregroundStyle(.secondary) }
    private var status: some View {
        Text(verbatim: CreatorLabels.status(controller.creator)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("creator-status")
    }
    private var profiles: some View {
        Picker("Current model", selection: Binding(get: { controller.creator.configuration.selectedProfileID }, set: { id in
            if let id { controller.launch { try await controller.selectCreatorProfile(id) } }
        })) {
            if controller.creator.profile == nil { Text("Choose a model").tag(UUID?.none) }
            ForEach(controller.creator.configuration.profiles, id: \.id) { Text(verbatim: $0.name).tag(Optional($0.id)) }
        }.labelsHidden().fixedSize(horizontal: false, vertical: true).accessibilityLabel(Text("Current model")).accessibilityIdentifier("creator-model-picker")
    }
    private var modes: some View {
        Picker("Creation engine", selection: Binding(get: {
            controller.creator.mode == .template ? "template" : controller.creator.engine.rawValue
        }, set: { value in
            controller.launch {
                if value == "template" { try await controller.setCreatorMode(.template) }
                else if let engine = CreatorEngine(rawValue: value) { try await controller.setCreatorEngine(engine) }
            }
        })) {
            ForEach(CreatorEngine.allCases.filter(\.available), id: \.self) { engine in
                Text(verbatim: CreatorEngineLabels.title(engine)).tag(engine.rawValue)
            }
            Text("Fine-tune template").tag("template")
        }.labelsHidden().accessibilityLabel(Text("Creation engine")).accessibilityIdentifier("creator-mode")
    }
    private func send() {
        guard controller.creator.canGenerate else { return }
        controller.launch(PanelActionCoordinator.key("creator.generate")) { try await controller.generateCreator() }
    }
}
