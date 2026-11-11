import SwiftUI

struct CreatorPage: View {
    @Environment(PanelController.self) private var controller
    var body: some View {
        let model = controller.creator
        GeometryReader { _ in
            VStack(spacing: 0) {
                if model.selectedProjectID != nil {
                    HStack {
                        Button { controller.shell.toggleFilters() } label: { Label("Recent projects", systemImage: "sidebar.leading") }
                            .buttonStyle(.plain).accessibilityIdentifier("creator-projects-toggle")
                        Spacer(minLength: 0)
                        Button("New project") { controller.launch { try await controller.newCreatorProject() } }.disabled(model.isBusy)
                    }.padding(.horizontal, 20).padding(.vertical, 10)
                }
                if model.selectedProjectID == nil { CreatorProjectsList() }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let title = model.projects.first(where: { $0.id == model.selectedProjectID })?.title {
                                Text(verbatim: title).font(.system(size: 20, weight: .semibold))
                            }
                            ForEach(model.detail?.conversation.turns ?? [], id: \.id) { turn in
                                PanelCard {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(verbatim: turn.userMessage).textSelection(.enabled)
                                        if let issue = turn.failure { Text(verbatim: CreatorLabels.issue(issue.category)).foregroundStyle(.secondary) }
                                        else if turn.state == .completed { Text("Validated · ready to save").foregroundStyle(.secondary) }
                                        Text(verbatim: "\(turn.requestCount)/\(turn.requestBudget)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            CreatorFailureActions()
                            DisclosureGroup("Validation report", isExpanded: Binding(get: { model.showsReport }, set: { model.showsReport = $0 })) {
                                CreatorReport()
                            }.accessibilityIdentifier("creator-report")
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                CreatorComposer()
            }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityIdentifier("creator-page")
    }
}

struct CreatorProjectsList: View {
    @Environment(PanelController.self) private var controller
    @State private var renaming: UUID?
    @State private var title = ""
    var body: some View {
        let model = controller.creator
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent projects").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Button { controller.launch(PanelActionCoordinator.key("creator.new")) { try await controller.newCreatorProject() } }
                    label: { Image(systemName: "plus") }
                    .accessibilityLabel(Text("New project")).accessibilityIdentifier("creator-new")
                    .disabled(model.isBusy || !model.recovered)
            }.padding(.horizontal, 12).padding(.top, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.filteredProjects) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                controller.launch(PanelActionCoordinator.key("creator.select"), policy: .latestWins) { try await controller.selectCreatorProject(row.id) }
                            } label: {
                                HStack(spacing: 10) {
                                    PanelImage(source: poster(row), pointSize: 64).frame(width: 56, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
                                    Text(verbatim: row.title).font(.system(size: 13)).lineLimit(2)
                                    Spacer(minLength: 0)
                                    if row.id == model.selectedProjectID { Image(systemName: "checkmark").accessibilityLabel(Text("Selected")) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }.buttonStyle(.plain).disabled(model.isBusy).accessibilityIdentifier("creator-project-" + row.id.uuidString)
                            .contextMenu {
                                Button("Rename") { renaming = row.id; title = row.title }
                                Button("Duplicate") { controller.launch { try await controller.duplicateCreatorProject(row.id) } }
                                Button("Delete draft", role: .destructive) { controller.launch { try await controller.deleteCreatorProject(row.id) } }
                            }
                            if renaming == row.id {
                                TextField("Project name", text: $title).textFieldStyle(.roundedBorder).accessibilityIdentifier("creator-project-name")
                                HStack {
                                    Button("Save name") {
                                        let value = title
                                        controller.launch { try await controller.renameCreatorProject(row.id, title: value); renaming = nil }
                                    }.disabled(!CreatorBundlePresentation.validText(title, limit: 60) || model.isBusy)
                                    Button("Cancel") { renaming = nil }
                                }
                            }
                        }
                    }
                }.padding(8)
            }
        }.accessibilityIdentifier("creator-projects")
    }
    private func poster(_ row: CreatorRevisionStore.WorkspaceProject) -> PanelImageSource? {
        guard let url = row.poster, let digest = row.posterBundleDigest else { return nil }
        return .creatorPoster(bundle: url, digest: digest)
    }
}

private struct CreatorComposer: View {
    @Environment(PanelController.self) private var controller
    var body: some View {
        @Bindable var model = controller.creator
        VStack(alignment: .leading, spacing: 10) {
            Picker("Creation mode", selection: Binding(get: { model.mode }, set: { mode in
                controller.launch { try await controller.setCreatorMode(mode) }
            })) {
                Text("Template tuning").tag(CreatorCreationMode.template)
                Text("Free code · HTML5 / Canvas / WebGL").tag(CreatorCreationMode.code)
            }.disabled(model.isBusy).accessibilityIdentifier("creator-mode")
            if model.mode == .code {
                Text("Offline interactive code. Every revision must pass runtime validation before saving.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Describe your wallpaper or the changes you want", text: $model.prompt, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder).disabled(model.isBusy)
                .accessibilityIdentifier("creator-prompt")
            ViewThatFits(in: .horizontal) {
                HStack { options; Spacer(minLength: 4); actions }
                VStack(alignment: .leading, spacing: 8) { options; actions }
            }
            Text(verbatim: CreatorLabels.status(model)).font(.system(size: 12)).foregroundStyle(.secondary)
                .accessibilityIdentifier("creator-status")
            if model.profile == nil {
                Button("Configure a model connection") { controller.launch { try await controller.openSettings(.models) } }
            }
        }.padding(16)
    }
    private var options: some View {
        @Bindable var model = controller.creator
        return HStack(spacing: 6) {
            Toggle("Auto repair", isOn: $model.autoRepair).toggleStyle(.checkbox).disabled(model.isBusy).accessibilityIdentifier("creator-auto-repair")
            if model.autoRepair {
                Picker("Repair limit", selection: $model.maxRepairs) {
                    Text(verbatim: "1").tag(1); Text(verbatim: "2").tag(2)
                }.labelsHidden().frame(width: 48).disabled(model.isBusy).accessibilityLabel(Text("Repair limit"))
            }
            if model.attempt > 0 { Text(verbatim: "\(model.attempt)/\(model.attemptLimit)").font(.caption.monospacedDigit()).accessibilityLabel(Text("Attempts")) }
        }
    }
    private var actions: some View {
        HStack {
            if controller.creator.isBusy {
                Button("Stop") { controller.cancelCreator() }.accessibilityIdentifier("creator-stop")
            } else {
                Button("Generate") { controller.launch(PanelActionCoordinator.key("creator.generate")) { try await controller.generateCreator() } }
                    .buttonStyle(.panelPrimary).disabled(!controller.creator.canGenerate).accessibilityIdentifier("creator-generate")
            }
        }
    }
}

private struct CreatorFailureActions: View {
    @Environment(PanelController.self) private var controller
    var body: some View {
        if let issue = controller.creator.issue {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: CreatorLabels.issue(issue.category))
                ViewThatFits(in: .horizontal) { HStack { buttons }; VStack(alignment: .leading) { buttons } }
            }.accessibilityIdentifier("creator-failure")
        }
    }
    @ViewBuilder private var buttons: some View {
        Button("Retry") { controller.launch { try await controller.generateCreator() } }.disabled(!controller.creator.canGenerate)
        Button("Change model") { controller.launch { try await controller.openSettings(.models) } }
        Button("View report") { controller.creator.showsReport = true }
        if let revision = controller.creator.detail?.project.lastValidatedRevisionID {
            Button("Return to valid version") { controller.launch { try await controller.rollbackCreator(revision) } }.disabled(controller.creator.isBusy)
        }
    }
}

struct CreatorReport: View {
    @Environment(PanelController.self) private var controller
    var body: some View {
        let model = controller.creator
        VStack(alignment: .leading, spacing: 6) {
            if let revision = model.selectedRevision, let report = model.detail?.reports[revision.id] {
                Text(verbatim: report.bundleDigest).font(.caption.monospaced()).textSelection(.enabled)
                ForEach(report.measuredMetrics.keys.sorted(), id: \.self) { key in
                    Text(verbatim: "\(key): \(report.measuredMetrics[key] ?? 0)").font(.caption.monospaced())
                }
            }
            if let issue = model.issue {
                Text(verbatim: issue.category.rawValue).font(.caption.monospaced())
                ForEach(issue.fields.indices, id: \.self) { index in
                    Text(verbatim: issue.fields[index].path + ": " + issue.fields[index].rule.rawValue).font(.caption.monospaced())
                }
            }
            Text("Reports contain native validation details only. Keys, raw responses and system paths are excluded.").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }
}
