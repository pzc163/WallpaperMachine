import SwiftUI

struct CreatorSettingsSection: View {
    private static let connections = SettingsItem.Group("connections", title: "Model connections")
    static let profiles = SettingsItem(id: "models.profiles", section: .models, group: connections,
        title: "Provider profiles", note: "Keys are stored separately in Keychain. Changing a connection requires a new key approval.",
        keywords: ["API key", "Endpoint", "Model", "Request budget", "Token budget", "Test connection"])
    static let items = [profiles]
    @Environment(PanelController.self) private var controller
    @State private var draft = ProviderProfile(name: "", protocolKind: .openaiCompatible, baseURL: "", model: "")
    @State private var key = ""
    @State private var expectedRevision = 0
    @State private var loaded = false

    var body: some View {
        SettingsPage(.models) {
            SettingsGroup(Self.connections, in: .models) {
                SettingsRow(Self.profiles, stacked: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        profileList
                        Divider()
                        fields
                        Text("Changing the target address clears the entered key. Previously saved credentials are never carried to a different host or configuration.")
                            .font(.caption).foregroundStyle(.secondary)
                        buttons
                        if let status = controller.creator.connectionStatus { Text(verbatim: status).font(.caption).accessibilityIdentifier("creator-connection-status") }
                        Text("Request and token budgets limit attempts and reserved output. They are not a monetary spending cap.").font(.caption).foregroundStyle(.secondary)
                        Text("AI projects and policies cannot be moved or backed up in this version. Keep the current storage location.").font(.caption).foregroundStyle(.secondary)
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
            if let saved = savedProfile { edit(saved) }
            else { expectedRevision = controller.creator.configuration.revision; if !loaded { loadSelected() } }
        }
        .onChange(of: draft.baseURL) { _, _ in key = "" }
        .onChange(of: draft.protocolKind) { _, kind in
            key = ""; draft.localMode = false; draft.capabilities = .init()
            if kind != .openaiCompatible { draft.localMode = false }
        }
        .onDisappear { key = "" }
        .accessibilityIdentifier("creator-model-settings")
    }
    private var profileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controller.creator.configuration.profiles, id: \.id) { profile in
                HStack {
                    Button { edit(profile) } label: { Text(verbatim: profile.name).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                    if profile.id == controller.creator.configuration.selectedProfileID { Image(systemName: "checkmark").accessibilityLabel(Text("Selected")) }
                    else { Button("Use this model") { controller.launch { try await controller.selectCreatorProfile(profile.id) } } }
                }
            }
            Button("Add connection") {
                key = ""; draft = ProviderProfile(name: "", protocolKind: .openaiCompatible, baseURL: "", model: "")
                expectedRevision = controller.creator.configuration.revision; loaded = true
            }.accessibilityIdentifier("creator-profile-add")
        }
    }
    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Connection name", text: $draft.name).accessibilityIdentifier("creator-profile-name")
            Picker("Protocol", selection: $draft.protocolKind) {
                Text("OpenAI compatible").tag(ProviderProfile.ProtocolKind.openaiCompatible)
                Text(verbatim: "Anthropic Messages").tag(ProviderProfile.ProtocolKind.anthropicMessages)
                Text(verbatim: "Gemini GenerateContent").tag(ProviderProfile.ProtocolKind.geminiGenerateContent)
            }.accessibilityIdentifier("creator-profile-protocol")
            TextField("Endpoint", text: $draft.baseURL).accessibilityIdentifier("creator-profile-endpoint")
            TextField("Model", text: $draft.model).accessibilityIdentifier("creator-profile-model")
            if draft.protocolKind == .openaiCompatible {
                Toggle("Local server mode", isOn: $draft.localMode).toggleStyle(.checkbox)
                Text("HTTP and an empty key are allowed only for localhost, 127.0.0.1 or ::1.").font(.caption).foregroundStyle(.secondary)
            }
            SecureField("API key", text: $key).privacySensitive().accessibilityIdentifier("creator-profile-key")
            Picker("Request budget", selection: $draft.limits.requestBudget) {
                ForEach(1...3, id: \.self) { Text(verbatim: String($0)).tag($0) }
            }.accessibilityIdentifier("creator-request-budget")
            HStack {
                Text("Token budget")
                TextField("Token budget", value: $draft.limits.tokenBudget, format: .number).accessibilityIdentifier("creator-token-budget")
            }
        }.textFieldStyle(.roundedBorder)
    }
    private var buttons: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Save connection") {
                    let profile = draft, secret = key, revision = expectedRevision
                    key = ""
                    controller.launch(PanelActionCoordinator.key("creator.profile.save")) {
                        try await controller.saveCreatorProfile(profile, key: secret, expectedRevision: revision)
                        if let saved = controller.creator.configuration.profiles.first(where: { $0.id == profile.id }) { edit(saved) }
                    }
                }.buttonStyle(.panelPrimary).disabled((try? draft.validate()) == nil).accessibilityIdentifier("creator-profile-save")
                if let saved = savedProfile {
                    Button("Delete") { controller.launch { try await controller.deleteCreatorProfile(saved.id); loaded = false; loadSelected() } }
                        .accessibilityIdentifier("creator-profile-delete")
                }
            }
            if let saved = savedProfile, saved == draft {
                HStack {
                    Button("Test connection") { controller.launch(PanelActionCoordinator.key("creator.connection.test")) { try await controller.testCreatorConnection(saved) } }
                        .disabled(controller.creator.isTestingConnection).accessibilityIdentifier("creator-test-connection")
                    if controller.creator.isTestingConnection {
                        Button("Cancel") { controller.cancelCreatorConnection() }.accessibilityIdentifier("creator-test-cancel")
                    }
                }
                Text(verbatim: saved.baseURL + " · " + saved.model).font(.caption).textSelection(.enabled)
            }
        }
    }
    private var savedProfile: ProviderProfile? { controller.creator.configuration.profiles.first { $0.id == draft.id } }
    private func edit(_ profile: ProviderProfile) {
        key = ""; draft = profile; expectedRevision = controller.creator.configuration.revision; loaded = true
    }
    private func loadSelected() {
        if let profile = controller.creator.profile { edit(profile) }
        else { expectedRevision = controller.creator.configuration.revision }
    }
}
