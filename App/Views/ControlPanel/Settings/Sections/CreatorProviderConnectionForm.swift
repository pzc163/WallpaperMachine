import SwiftUI

/// A form instance owns exactly one cloud or local connection draft.
struct CreatorProviderConnectionForm: View {
    @Environment(PanelController.self) private var controller
    @Bindable var form: CreatorConnectionDraft
    let didSave: (ProviderProfile, ProviderProfile) -> Void
    let didDelete: (UUID) -> Void
    @State private var discovery: Task<Void, Never>?
    @State private var discovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: L(form.profile.localMode ? "Local service configuration" : "Cloud provider configuration"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                CreatorProviderIcon(name: CreatorProviderCatalog.icon(profile: form.profile))
                Text(verbatim: form.profile.name.isEmpty ? L("Add connection") : form.profile.name).font(.headline)
            }
            fields
            Text("Changing the target address clears the entered key. Previously saved credentials are never carried to a different host or configuration.").font(.caption).foregroundStyle(.secondary)
            buttons
            if let status = controller.creator.connectionStatus { Text(verbatim: status).font(.caption).accessibilityIdentifier("creator-connection-status") }
            Text("Native maximum depends on the server context window. Token accounting is an estimate, not a spending cap.").font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: form.profile.baseURL) { _, _ in form.targetChanged(); discovery?.cancel() }
        .onChange(of: form.profile) { _, _ in controller.creator.connectionNotice = nil; discovery?.cancel() }
        .onDisappear { discovery?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(form.profile.localMode ? "creator-local-connection" : "creator-cloud-connection")
    }
    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Connection name") { TextField("Connection name", text: $form.profile.name).accessibilityIdentifier("creator-profile-name") }
            field("Protocol") {
                Picker("Protocol", selection: Binding(get: { form.profile.protocolKind }, set: { form.changeProtocol(to: $0) })) {
                    Text("OpenAI compatible").tag(ProviderProfile.ProtocolKind.openaiCompatible)
                    Text(verbatim: "Anthropic Messages").tag(ProviderProfile.ProtocolKind.anthropicMessages)
                    Text(verbatim: "Gemini GenerateContent").tag(ProviderProfile.ProtocolKind.geminiGenerateContent)
                }.labelsHidden().accessibilityIdentifier("creator-profile-protocol")
            }
            field(form.profile.localMode ? "Local Base URL" : "Base URL") {
                TextField("Base URL", text: $form.profile.baseURL, prompt: Text(verbatim: form.profile.localMode ? "http://192.168.90.9:1234/v1" : "https://api.example.com/v1"))
                    .accessibilityIdentifier("creator-profile-endpoint")
            }
            field(form.profile.localMode ? (form.keyIsOptional ? "Local API key (optional)" : "Local API key") : "Provider API key") { SecureField("API key", text: $form.key).privacySensitive().accessibilityIdentifier("creator-profile-key") }
            if form.profile.localMode {
                if form.keyIsOptional { Text("API key is optional in local mode. Enter one if your LAN server requires authentication.").font(.caption).foregroundStyle(.secondary) }
                Text("Allow Local Network access in System Settings → Privacy & Security when prompted.").font(.caption).foregroundStyle(.secondary)
            }
            if let entry = form.profile.providerID.flatMap(CreatorProviderCatalog.entry), entry.endpoints.count > 1 {
                Menu("Endpoint presets") {
                    ForEach(entry.endpoints, id: \.self) { endpoint in Button { form.profile.baseURL = endpoint } label: { Text(verbatim: endpoint) } }
                }
            }
            field("Model ID") {
                HStack {
                    TextField("Model ID", text: $form.profile.model).accessibilityIdentifier("creator-profile-model")
                    Button("Enable model") { enable(form.profile.model) }.disabled(!ProviderProfile.validModel(form.profile.model, protocolKind: form.profile.protocolKind))
                }
            }
            if !form.models.isEmpty {
                Menu("Available models") {
                    ForEach(form.models, id: \.self) { id in Button { form.profile.model = id; enable(id) } label: { Text(verbatim: id) } }
                }.accessibilityIdentifier("creator-model-list")
            }
            if !enabledModels.isEmpty {
                Text("Enabled models for this connection").font(.caption).foregroundStyle(.secondary)
                ForEach(enabledModels, id: \.self) { id in
                    HStack {
                        CreatorProviderIcon(name: CreatorProviderCatalog.icon(profile: form.profile, model: id))
                        Text(verbatim: id).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Toggle("Vision input", isOn: Binding(get: { form.profile.visionModelIDs?.contains(id) == true }, set: { enabled in
                            var ids = form.profile.visionModelIDs ?? []; ids.removeAll { $0 == id }; if enabled { ids.append(id) }; form.profile.visionModelIDs = ids.isEmpty ? nil : ids
                        })).toggleStyle(.checkbox).font(.caption)
                        Button { disable(id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help(L("Remove model"))
                    }
                }
                Text("Enable vision only for models that accept images. Sending a thumbnail is a separate opt-in.").font(.caption).foregroundStyle(.secondary)
            }
            if form.profile.localMode, form.profile.protocolKind == .openaiCompatible {
                Text("Local mode allows HTTP and an empty key on loopback, private LAN addresses and .local hosts only. Use a trusted network; public endpoints require HTTPS.").font(.caption).foregroundStyle(.secondary)
                if form.profile.localMode {
                    HStack {
                        Button("Fetch models") {
                            let profile = form.profile, secret = form.key
                            discovering = true
                            discovery = controller.launch {
                                defer { discovering = false; discovery = nil }
                                    let result = try await controller.creatorModels(profile, key: secret)
                                    try Task.checkCancellation()
                                    if form.profile == profile { form.models = result }
                            }
                        }.disabled(discovering || (try? LLMModelCatalog.target(for: form.profile)) == nil).accessibilityIdentifier("creator-fetch-models")
                        if discovering { Button("Cancel") { discovery?.cancel() } }
                    }
                }
            }
            field("Request budget") {
                Picker("Request budget", selection: $form.profile.limits.requestBudget) { ForEach(1...3, id: \.self) { Text(verbatim: String($0)).tag($0) } }
                    .labelsHidden().accessibilityIdentifier("creator-request-budget")
            }
            CreatorGenerationOptions(profile: $form.profile)
            Toggle("Manual context and output limits", isOn: Binding(get: { form.profile.limits.nativeOutputLimit != true }, set: { manual in
                form.profile.limits.nativeOutputLimit = !manual
                form.profile.limits.contextWindow = manual ? 131_072 : nil
                form.profile.limits.tokenBudget = manual ? 32_768 : ProviderProfile.Limits.defaultTokenBudget
                form.contextText = manual ? "131072" : ""; form.tokenBudgetText = manual ? "32768" : ""
            })).toggleStyle(.checkbox).accessibilityIdentifier("creator-manual-limits")
            if form.profile.limits.nativeOutputLimit != true {
                field("Context window") {
                    TextField("Context window", text: Binding(get: { form.contextText }, set: { value in
                        form.contextText = value; form.profile.limits.contextWindow = Int(value) ?? 0
                    })).accessibilityIdentifier("creator-context-window")
                }
                field("Maximum output tokens") {
                    TextField("Maximum output tokens", text: Binding(get: { form.tokenBudgetText }, set: { value in
                        form.tokenBudgetText = value; form.profile.limits.tokenBudget = ProviderProfile.Limits.tokenBudget(from: value) ?? 0
                    })).accessibilityIdentifier("creator-token-budget")
                }
                Text("Manual context uses a conservative byte estimate and reserves room for output; it is not the provider's tokenizer.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Automatic · model context and output maximum").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: Binding(get: { controller.creator.providerAdvancedExpanded }, set: { controller.creator.providerAdvancedExpanded = $0 })) {
            field("JSON output mode") {
                if form.profile.protocolKind == .openaiCompatible {
                    Picker("JSON output mode", selection: Binding(get: { form.profile.capabilities.jsonMode ?? .automatic }, set: { form.profile.capabilities.jsonMode = $0 })) {
                        Text("Automatic (with fallback)").tag(ProviderProfile.Capabilities.JSONMode.automatic)
                        Text("JSON Schema (strict)").tag(ProviderProfile.Capabilities.JSONMode.schema)
                        Text("JSON object (required)").tag(ProviderProfile.Capabilities.JSONMode.required)
                        Text("Prompt only").tag(ProviderProfile.Capabilities.JSONMode.disabled)
                    }.labelsHidden().accessibilityIdentifier("creator-json-mode")
                } else {
                    Text(verbatim: form.profile.protocolKind == .geminiGenerateContent ? L("Gemini uses its native JSON response format.") : L("Anthropic uses the prompt's JSON contract."))
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
                    let profile = savingProfile, original = form.profile, secret = form.key, revision = controller.creator.configuration.revision
                    form.key = ""
                    controller.launch(PanelActionCoordinator.key("creator.profile.save")) {
                        try await controller.saveCreatorProfile(profile, key: secret, expectedRevision: revision)
                        if let saved = controller.creator.configuration.profiles.first(where: { $0.id == profile.id }) { didSave(saved, original) }
                    }
                }.buttonStyle(.panelPrimary).disabled((try? savingProfile.validate()) == nil).accessibilityIdentifier("creator-profile-save")
                if let saved = savedProfile {
                    Button("Delete") { controller.launch {
                        try await controller.deleteCreatorProfile(saved.id)
                        if !controller.creator.configuration.profiles.contains(where: { $0.id == saved.id }) { didDelete(saved.id) }
                    } }
                        .accessibilityIdentifier("creator-profile-delete")
                }
            }
            if let saved = savedProfile, saved == form.profile {
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
    private var enabledModels: [String] { (form.profile.modelIDs ?? (form.profile.model.isEmpty ? [] : [form.profile.model])) }
    private var savingProfile: ProviderProfile {
        var value = form.profile
        if value.modelIDs != nil, !value.model.isEmpty, !value.enabledModels.contains(value.model) { value.modelIDs?.append(value.model) }
        return value
    }
    private func enable(_ id: String) {
        var ids = enabledModels
        if !ids.contains(id) && ids.count < 64 { ids.append(id) }
        form.profile.modelIDs = ids; if form.profile.model.isEmpty { form.profile.model = id }
    }
    private func disable(_ id: String) {
        form.profile.modelIDs = enabledModels.filter { $0 != id }
        form.profile.visionModelIDs?.removeAll { $0 == id }
        if form.profile.model == id { form.profile.model = form.profile.modelIDs?.first ?? "" }
    }
    private var savedProfile: ProviderProfile? { controller.creator.configuration.profiles.first { $0.id == form.id } }
}
