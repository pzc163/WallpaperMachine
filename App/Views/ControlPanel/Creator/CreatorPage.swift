import SwiftUI

struct CreatorPage: View {
    @Environment(PanelController.self) private var controller
    @State private var renaming = false
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        let model = controller.creator
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !controller.shell.areFiltersShown {
                    Button { controller.shell.setFiltersShown(true) } label: { Image(systemName: "sidebar.leading") }
                        .buttonStyle(.plain).accessibilityLabel(Text("Recent projects")).accessibilityIdentifier("creator-projects-toggle")
                }
                if let selected = model.projects.first(where: { $0.id == model.selectedProjectID }) {
                    if renaming {
                        TextField("Project name", text: $title).textFieldStyle(.roundedBorder).focused($titleFocused)
                            .onSubmit { saveName(selected.id) }.onExitCommand { renaming = false }
                            .accessibilityIdentifier("creator-title-editor")
                        Button("Save name") { saveName(selected.id) }.disabled(!CreatorBundlePresentation.validText(title, limit: 60) || model.isBusy)
                        Button("Cancel") { renaming = false }
                    } else {
                        Button { beginRename(selected.title) } label: { Text(verbatim: selected.title).font(.system(size: 18, weight: .semibold)).lineLimit(1) }
                            .buttonStyle(.plain).accessibilityIdentifier("creator-project-title")
                        Button { beginRename(selected.title) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain).help(L("Rename")).accessibilityLabel(Text("Rename")).accessibilityIdentifier("creator-rename")
                    }
                } else { Text("Your next wallpaper starts here").font(.headline) }
                Spacer(minLength: 0)
            }.disabled(model.isBusy).padding(.horizontal, 20).padding(.vertical, 12)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.detail?.conversation.turns.isEmpty != false { CreatorInspiration() }
                        ForEach(model.detail?.conversation.turns ?? [], id: \.id) { turn in
                            PanelCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(verbatim: turn.userMessage).textSelection(.enabled)
                                    if let issue = turn.failure { Text(verbatim: CreatorLabels.issue(issue.category)).foregroundStyle(.secondary) }
                                    else if turn.state == .completed { Label("Validated · ready to save", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                                    HStack {
                                        Text(verbatim: "\(turn.requestCount)/\(turn.requestBudget)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityLabel(Text("Attempts"))
                                        Spacer(minLength: 4)
                                        if [.failed, .cancelled, .interrupted].contains(turn.state) {
                                            Button("Edit and resend") { controller.launch { try controller.editCreatorTurn(turn.id) } }
                                                .accessibilityIdentifier("creator-edit-" + turn.id.uuidString)
                                            Button("Retry") { controller.launch { try await controller.retryCreatorTurn(turn.id) } }
                                                .buttonStyle(.borderedProminent).accessibilityIdentifier("creator-retry-" + turn.id.uuidString)
                                        }
                                    }.disabled(model.isBusy)
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            }.id(turn.id)
                        }
                        if model.isBusy {
                            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(verbatim: CreatorLabels.status(model)) }
                                .accessibilityIdentifier("creator-stream-progress")
                        }
                        CreatorFailureActions()
                        if model.selectedRevision != nil || model.issue != nil {
                            DisclosureGroup("Validation report", isExpanded: Binding(get: { model.showsReport }, set: { model.showsReport = $0 })) { CreatorReport() }
                                .accessibilityIdentifier("creator-report")
                        }
                        Color.clear.frame(height: 1).id("creator-bottom")
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: model.detail?.conversation.turns.last?.id) { _, _ in scroll.scrollTo("creator-bottom", anchor: .bottom) }
            }
            CreatorComposer()
        }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.selectedProjectID) { _, _ in renaming = false }
            .accessibilityElement(children: .contain).accessibilityIdentifier("creator-page")
    }
    private func beginRename(_ value: String) { title = value; renaming = true; titleFocused = true }
    private func saveName(_ id: UUID) {
        guard CreatorBundlePresentation.validText(title, limit: 60), !controller.creator.isBusy else { return }
        let value = title
        controller.launch { try await controller.renameCreatorProject(id, title: value); renaming = false }
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
