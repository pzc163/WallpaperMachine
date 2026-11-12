import SwiftUI

struct CreatorSettingsSection: View {
    private static let connections = SettingsItem.Group("connections", title: "Model connections")
    static let profiles = SettingsItem(id: "models.profiles", section: .models, group: connections,
        title: "Provider profiles", note: "Cloud providers and local services have independent addresses and credentials.",
        keywords: ["API key", "Endpoint", "Model", "JSON output mode", "Request budget", "Token budget", "Test connection"])
    static let items = [profiles]
    @Environment(PanelController.self) private var controller
    @State private var drafts = CreatorConnectionDrafts()
    @State private var loaded = false

    var body: some View {
        SettingsPage(.models) {
            SettingsGroup(Self.connections, in: .models) {
                SettingsRow(Self.profiles, stacked: true) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 20) {
                            directory.frame(width: 178)
                            Divider()
                            detail.frame(minWidth: 310, maxWidth: .infinity, alignment: .leading)
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            Menu("Provider directory") { directoryItems }
                            detail
                        }
                    }
                }
            }
        }
        .onAppear {
            loadSelected()
            controller.launch(PanelActionCoordinator.key("creator.settings.load")) {
                try await controller.recoverCreator()
                if !loaded { loadSelected() }
            }
        }
        .onChange(of: controller.creator.configuration.revision) { _, _ in
            drafts.refresh(controller.creator.configuration)
            if !loaded { loadSelected() }
        }
        .onChange(of: drafts.selected.id) { _, _ in
            controller.cancelCreatorConnection()
            controller.creator.connectionNotice = nil
            controller.creator.connectionStatus = nil
        }
        .onDisappear { drafts.clearKeys() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("creator-model-settings")
    }
    private var detail: some View {
        CreatorProviderConnectionForm(form: drafts.selected,
            didSave: { saved, submitted in drafts.saved(saved, submitted: submitted) },
            didDelete: { id in drafts.remove(id) })
            .id(drafts.selected.id)
    }
    private var directory: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) { directoryItems }
        }.frame(maxHeight: 680).accessibilityIdentifier("creator-provider-directory")
    }
    @ViewBuilder private var directoryItems: some View {
        Text("Cloud providers").font(.caption).foregroundStyle(.secondary)
        savedConnections(local: false)
        ForEach(entries(local: false)) { entry in providerButton(entry) }
        Divider()
        Text("Local and LAN models").font(.caption).foregroundStyle(.secondary)
        savedConnections(local: true)
        ForEach(entries(local: true)) { entry in providerButton(entry) }
    }
    private func entries(local: Bool) -> [CreatorProviderCatalog.Entry] {
        CreatorProviderCatalog.entries.filter { entry in
            entry.local == local && (entry.custom || !controller.creator.configuration.profiles.contains { $0.providerID == entry.id && $0.localMode == local })
        }
    }
    @ViewBuilder private func savedConnections(local: Bool) -> some View {
        ForEach(controller.creator.configuration.profiles.filter { $0.localMode == local }, id: \.id) { profile in
            Button { loaded = true; drafts.select(profile) } label: {
                HStack(spacing: 8) {
                    CreatorProviderIcon(name: CreatorProviderCatalog.icon(profile: profile))
                    Text(verbatim: profile.name).lineLimit(1)
                    Spacer(minLength: 2)
                    if drafts.selected.id == profile.id { Image(systemName: "checkmark").accessibilityLabel(Text("Selected")) }
                }.padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("creator-saved-" + profile.id.uuidString)
        }
    }
    private func providerButton(_ entry: CreatorProviderCatalog.Entry) -> some View {
        Button {
            loaded = true
            drafts.select(entry, profiles: controller.creator.configuration.profiles)
        } label: {
            HStack(spacing: 8) {
                if entry.custom { Image(systemName: "plus").frame(width: 20) }
                else { CreatorProviderIcon(name: entry.icon) }
                Text(verbatim: entry.custom ? PanelLocale.shared.catalogString(entry.name) : entry.name)
                Spacer(minLength: 0)
            }.padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("creator-provider-" + entry.id)
    }
    private func loadSelected() {
        if let profile = controller.creator.profile { drafts.select(profile); loaded = true }
    }
}
