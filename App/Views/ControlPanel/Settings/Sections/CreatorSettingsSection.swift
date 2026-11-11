import SwiftUI

struct CreatorSettingsSection: View {
    private static let connections = SettingsItem.Group("connections", title: "Model connections")
    static let profiles = SettingsItem(id: "models.profiles", section: .models, group: connections,
        title: "Provider profiles", note: "Keys are stored separately in Keychain. Changing a connection requires a new key approval.",
        keywords: ["API key", "Endpoint", "Model", "JSON output mode", "Request budget", "Token budget", "Test connection"])
    static let items = [profiles]
    @Environment(PanelController.self) private var controller
    @State private var draft = ProviderProfile(name: "", protocolKind: .openaiCompatible, baseURL: "", model: "")
    @State private var key = ""
    @State private var expectedRevision = 0
    @State private var loaded = false
    @State private var tokenBudgetText = ""
    @State private var models: [String] = []
    @State private var discovery: Task<Void, Never>?
    @State private var discovering = false

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
                        Text("Native maximum depends on the server context window. Token accounting is an estimate, not a spending cap.").font(.caption).foregroundStyle(.secondary)
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
        .onChange(of: draft.baseURL) { _, _ in key = ""; models = []; discovery?.cancel() }
        .onChange(of: draft) { _, _ in controller.creator.connectionNotice = nil; discovery?.cancel() }
        .onDisappear { key = ""; discovery?.cancel() }
        .accessibilityElement(children: .contain)
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
                key = ""; tokenBudgetText = ""; draft = ProviderProfile(name: "", protocolKind: .openaiCompatible, baseURL: "", model: "")
                expectedRevision = controller.creator.configuration.revision; loaded = true
            }.accessibilityIdentifier("creator-profile-add")
        }
    }
    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Connection name") { TextField("Connection name", text: $draft.name).accessibilityIdentifier("creator-profile-name") }
            field("Protocol") {
                Picker("Protocol", selection: Binding(get: { draft.protocolKind }, set: {
                    key = ""; draft.protocolKind = $0; draft.localMode = false; draft.capabilities = .init()
                })) {
                    Text("OpenAI compatible").tag(ProviderProfile.ProtocolKind.openaiCompatible)
                    Text(verbatim: "Anthropic Messages").tag(ProviderProfile.ProtocolKind.anthropicMessages)
                    Text(verbatim: "Gemini GenerateContent").tag(ProviderProfile.ProtocolKind.geminiGenerateContent)
                }.labelsHidden().accessibilityIdentifier("creator-profile-protocol")
            }
            field("JSON output mode") {
                if draft.protocolKind == .openaiCompatible {
                    Picker("JSON output mode", selection: Binding(get: { draft.capabilities.jsonMode ?? .automatic }, set: { draft.capabilities.jsonMode = $0 })) {
                        Text("Automatic (with fallback)").tag(ProviderProfile.Capabilities.JSONMode.automatic)
                        Text("JSON Schema (strict)").tag(ProviderProfile.Capabilities.JSONMode.schema)
                        Text("JSON object (required)").tag(ProviderProfile.Capabilities.JSONMode.required)
                        Text("Prompt only").tag(ProviderProfile.Capabilities.JSONMode.disabled)
                    }.labelsHidden().accessibilityIdentifier("creator-json-mode")
                } else {
                    Text(verbatim: draft.protocolKind == .geminiGenerateContent ? L("Gemini uses its native JSON response format.") : L("Anthropic uses the prompt's JSON contract."))
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("creator-json-mode-native")
                }
            }
            field("Base URL") {
                TextField("Base URL", text: $draft.baseURL, prompt: Text(verbatim: draft.localMode ? "http://192.168.90.9:1234/v1" : "https://api.example.com/v1"))
                    .accessibilityIdentifier("creator-profile-endpoint")
            }
            field("Model ID") {
                VStack(alignment: .leading) {
                    TextField("Model ID", text: $draft.model).accessibilityIdentifier("creator-profile-model")
                    if !models.isEmpty {
                        Picker("Available models", selection: $draft.model) {
                            Text("Choose a model").tag("")
                            if !draft.model.isEmpty && !models.contains(draft.model) { Text(verbatim: draft.model).tag(draft.model) }
                            ForEach(models, id: \.self) { Text(verbatim: $0).tag($0) }
                        }.accessibilityIdentifier("creator-model-list")
                    }
                }
            }
            if draft.protocolKind == .openaiCompatible {
                Toggle("Local server mode", isOn: $draft.localMode).toggleStyle(.checkbox)
                Text("Local mode allows HTTP and an empty key on loopback, private LAN addresses and .local hosts only. Use a trusted network; public endpoints require HTTPS.").font(.caption).foregroundStyle(.secondary)
                if draft.localMode {
                    HStack {
                        Button("Fetch models") {
                            let profile = draft, secret = key
                            discovering = true
                            discovery = controller.launch {
                                defer { discovering = false; discovery = nil }
                                    let result = try await controller.creatorModels(profile, key: secret)
                                    try Task.checkCancellation()
                                    if draft == profile { models = result }
                            }
                        }.disabled(discovering || (try? LLMModelCatalog.target(for: draft)) == nil).accessibilityIdentifier("creator-fetch-models")
                        if discovering { Button("Cancel") { discovery?.cancel() } }
                    }
                }
            }
            field("API key") { SecureField("API key", text: $key).privacySensitive().accessibilityIdentifier("creator-profile-key") }
            if draft.localMode {
                Text("API key is optional in local mode. Enter one if your LAN server requires authentication.").font(.caption).foregroundStyle(.secondary)
                Text("Allow Local Network access in System Settings → Privacy & Security when prompted.").font(.caption).foregroundStyle(.secondary)
            }
            field("Request budget") {
                Picker("Request budget", selection: $draft.limits.requestBudget) { ForEach(1...3, id: \.self) { Text(verbatim: String($0)).tag($0) } }
                    .labelsHidden().accessibilityIdentifier("creator-request-budget")
            }
            field("Token budget") {
                TextField("Token budget", text: Binding(get: { tokenBudgetText }, set: { value in
                    tokenBudgetText = value
                    draft.limits.tokenBudget = ProviderProfile.Limits.tokenBudget(from: value) ?? 0
                    draft.limits.nativeOutputLimit = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }), prompt: Text("Model maximum (automatic)"))
                    .accessibilityIdentifier("creator-token-budget")
            }
            Text("Blank uses the model maximum. Or set 1–131,072 output tokens per request. Every fallback and repair counts toward the request budget.").font(.caption).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder)
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: PanelLocale.shared.catalogString(label)).frame(width: 132, alignment: .trailing)
                content().frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 5) { Text(verbatim: PanelLocale.shared.catalogString(label)); content() }
        }
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
        key = ""; draft = profile; tokenBudgetText = profile.limits.nativeOutputLimit == true ? "" : String(profile.limits.tokenBudget)
        expectedRevision = controller.creator.configuration.revision; loaded = true
    }
    private func loadSelected() {
        if let profile = controller.creator.profile { edit(profile) }
        else { expectedRevision = controller.creator.configuration.revision }
    }
}
