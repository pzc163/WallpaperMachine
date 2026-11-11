import SwiftUI

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
            PageSearchFieldView(field: .init(text: Binding(get: { model.search }, set: { model.search = $0 }),
                prompt: L("Search projects"), name: L("Search projects"), submit: {})).padding(.horizontal, 12)
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
                                    .onSubmit { saveName(row.id) }
                                HStack {
                                    Button("Save name") {
                                        saveName(row.id)
                                    }.disabled(!CreatorBundlePresentation.validText(title, limit: 60) || model.isBusy)
                                    Button("Cancel") { renaming = nil }
                                }
                            }
                        }
                    }
                }.padding(8)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("creator-projects")
    }
    private func saveName(_ id: UUID) {
        guard CreatorBundlePresentation.validText(title, limit: 60), !controller.creator.isBusy else { return }
        let value = title
        controller.launch { try await controller.renameCreatorProject(id, title: value); renaming = nil }
    }
    private func poster(_ row: CreatorRevisionStore.WorkspaceProject) -> PanelImageSource? {
        guard let url = row.poster, let digest = row.posterBundleDigest else { return nil }
        return .creatorPoster(bundle: url, digest: digest)
    }
}

