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
    @State private var contextText = ""
    @State private var discovery: Task<Void, Never>?
    @State private var discovering = false

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
            if let saved = savedProfile { edit(saved) }
            else { expectedRevision = controller.creator.configuration.revision; if !loaded { loadSelected() } }
        }
        .onChange(of: draft.baseURL) { _, _ in key = ""; models = []; discovery?.cancel() }
        .onChange(of: draft) { _, _ in controller.creator.connectionNotice = nil; discovery?.cancel() }
        .onDisappear { key = ""; discovery?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("creator-model-settings")
    }
    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CreatorProviderIcon(name: CreatorProviderCatalog.icon(profile: draft))
                Text(verbatim: draft.name.isEmpty ? L("Add connection") : draft.name).font(.headline)
            }
            fields
            Text("Changing the target address clears the entered key. Previously saved credentials are never carried to a different host or configuration.").font(.caption).foregroundStyle(.secondary)
            buttons
            if let status = controller.creator.connectionStatus { Text(verbatim: status).font(.caption).accessibilityIdentifier("creator-connection-status") }
            Text("Native maximum depends on the server context window. Token accounting is an estimate, not a spending cap.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var directory: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) { directoryItems }
        }.frame(maxHeight: 680).accessibilityIdentifier("creator-provider-directory")
    }
    @ViewBuilder private var directoryItems: some View {
        if !controller.creator.configuration.profiles.isEmpty {
            Text("My connections").font(.caption).foregroundStyle(.secondary)
            ForEach(controller.creator.configuration.profiles, id: \.id) { profile in
                Button { edit(profile) } label: {
                    HStack(spacing: 8) {
                        CreatorProviderIcon(name: CreatorProviderCatalog.icon(profile: profile))
                        Text(verbatim: profile.name).lineLimit(1)
                        Spacer(minLength: 2)
                        if draft.id == profile.id { Image(systemName: "checkmark").accessibilityLabel(Text("Selected")) }
                    }.padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Divider()
        }
        Text("Cloud providers").font(.caption).foregroundStyle(.secondary)
        ForEach(CreatorProviderCatalog.entries.filter { !$0.local }) { entry in providerButton(entry) }
        Divider()
        Text("Local and LAN models").font(.caption).foregroundStyle(.secondary)
        ForEach(CreatorProviderCatalog.entries.filter(\.local)) { entry in providerButton(entry) }
    }
    private func providerButton(_ entry: CreatorProviderCatalog.Entry) -> some View {
        Button {
            if !entry.custom, let saved = controller.creator.configuration.profiles.first(where: { $0.providerID == entry.id }) { edit(saved) }
            else { edit(entry.profile()) }
        } label: {
            HStack(spacing: 8) {
                if entry.custom { Image(systemName: "plus").frame(width: 20) }
                else { CreatorProviderIcon(name: entry.id == "minicpm" ? "minicpm" : entry.icon) }
                Text(verbatim: entry.custom ? PanelLocale.shared.catalogString(entry.name) : entry.name)
                Spacer(minLength: 0)
            }.padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("creator-provider-" + entry.id)
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
            field("Base URL") {
                TextField("Base URL", text: $draft.baseURL, prompt: Text(verbatim: draft.localMode ? "http://192.168.90.9:1234/v1" : "https://api.example.com/v1"))
                    .accessibilityIdentifier("creator-profile-endpoint")
            }
            if let entry = draft.providerID.flatMap(CreatorProviderCatalog.entry), entry.endpoints.count > 1 {
                Menu("Endpoint presets") {
                    ForEach(entry.endpoints, id: \.self) { endpoint in Button { draft.baseURL = endpoint } label: { Text(verbatim: endpoint) } }
                }
            }
            field("Model ID") {
                HStack {
                    TextField("Model ID", text: $draft.model).accessibilityIdentifier("creator-profile-model")
                    Button("Enable model") { enable(draft.model) }.disabled(!ProviderProfile.validModel(draft.model, protocolKind: draft.protocolKind))
                }
            }
            if !models.isEmpty {
                Menu("Available models") {
                    ForEach(models, id: \.self) { id in Button { draft.model = id; enable(id) } label: { Text(verbatim: id) } }
                }.accessibilityIdentifier("creator-model-list")
            }
            if !enabledModels.isEmpty {
                Text("Enabled models · shared API key").font(.caption).foregroundStyle(.secondary)
                ForEach(enabledModels, id: \.self) { id in
                    HStack {
                        CreatorProviderIcon(name: CreatorProviderCatalog.icon(profile: draft, model: id))
                        Text(verbatim: id).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Toggle("Vision input", isOn: Binding(get: { draft.visionModelIDs?.contains(id) == true }, set: { enabled in
                            var ids = draft.visionModelIDs ?? []; ids.removeAll { $0 == id }; if enabled { ids.append(id) }; draft.visionModelIDs = ids.isEmpty ? nil : ids
                        })).toggleStyle(.checkbox).font(.caption)
                        Button { disable(id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help(L("Remove model"))
                    }
                }
                Text("Enable vision only for models that accept images. Sending a thumbnail is a separate opt-in.").font(.caption).foregroundStyle(.secondary)
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
            Toggle("Manual context and output limits", isOn: Binding(get: { draft.limits.nativeOutputLimit != true }, set: { manual in
                draft.limits.nativeOutputLimit = !manual
                draft.limits.contextWindow = manual ? 131_072 : nil
                draft.limits.tokenBudget = manual ? 32_768 : ProviderProfile.Limits.defaultTokenBudget
                contextText = manual ? "131072" : ""; tokenBudgetText = manual ? "32768" : ""
            })).toggleStyle(.checkbox).accessibilityIdentifier("creator-manual-limits")
            if draft.limits.nativeOutputLimit != true {
                field("Context window") {
                    TextField("Context window", text: Binding(get: { contextText }, set: { value in
                        contextText = value; draft.limits.contextWindow = Int(value) ?? 0
                    })).accessibilityIdentifier("creator-context-window")
                }
                field("Maximum output tokens") {
                    TextField("Maximum output tokens", text: Binding(get: { tokenBudgetText }, set: { value in
                        tokenBudgetText = value; draft.limits.tokenBudget = ProviderProfile.Limits.tokenBudget(from: value) ?? 0
                    })).accessibilityIdentifier("creator-token-budget")
                }
                Text("Manual context uses a conservative byte estimate and reserves room for output; it is not the provider's tokenizer.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Automatic · model context and output maximum").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: Binding(get: { controller.creator.providerAdvancedExpanded }, set: { controller.creator.providerAdvancedExpanded = $0 })) {
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
            } label: { Text("Advanced options").accessibilityIdentifier("creator-advanced-options") }
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
                    let profile = savingProfile, secret = key, revision = expectedRevision
                    key = ""
                    controller.launch(PanelActionCoordinator.key("creator.profile.save")) {
                        try await controller.saveCreatorProfile(profile, key: secret, expectedRevision: revision)
                        if let saved = controller.creator.configuration.profiles.first(where: { $0.id == profile.id }) { edit(saved) }
                    }
                }.buttonStyle(.panelPrimary).disabled((try? savingProfile.validate()) == nil).accessibilityIdentifier("creator-profile-save")
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
                Menu("Use this model") {
                    ForEach(saved.enabledModels, id: \.self) { id in
                        Button { controller.launch { try await controller.selectCreatorProfile(saved.id, modelID: id) } } label: { Text(verbatim: id) }
                    }
                }
                Text(verbatim: saved.baseURL + " · " + saved.model).font(.caption).textSelection(.enabled)
            }
        }
    }
    private var enabledModels: [String] { (draft.modelIDs ?? (draft.model.isEmpty ? [] : [draft.model])) }
    private var savingProfile: ProviderProfile {
        var value = draft
        if value.modelIDs != nil, !value.model.isEmpty, !value.enabledModels.contains(value.model) { value.modelIDs?.append(value.model) }
        return value
    }
    private func enable(_ id: String) {
        var ids = enabledModels
        if !ids.contains(id) && ids.count < 64 { ids.append(id) }
        draft.modelIDs = ids; if draft.model.isEmpty { draft.model = id }
    }
    private func disable(_ id: String) {
        draft.modelIDs = enabledModels.filter { $0 != id }
        draft.visionModelIDs?.removeAll { $0 == id }
        if draft.model == id { draft.model = draft.modelIDs?.first ?? "" }
    }
    private var savedProfile: ProviderProfile? { controller.creator.configuration.profiles.first { $0.id == draft.id } }
    private func edit(_ profile: ProviderProfile) {
        key = ""; draft = profile; tokenBudgetText = profile.limits.nativeOutputLimit == true ? "" : String(profile.limits.outputTokensPerRequest)
        contextText = profile.limits.contextWindow.map(String.init) ?? "131072"
        expectedRevision = controller.creator.configuration.revision; loaded = true
    }
    private func loadSelected() {
        if let profile = controller.creator.profile { edit(profile) }
        else { expectedRevision = controller.creator.configuration.revision }
    }
}
