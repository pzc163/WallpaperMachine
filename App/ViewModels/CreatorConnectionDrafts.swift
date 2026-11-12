import Foundation
import Observation

/// Unsaved form values belong to one connection only. No credentials are loaded by the editor.
@MainActor @Observable
final class CreatorConnectionDraft: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var profile: ProviderProfile
    var key = ""
    var tokenBudgetText: String
    var contextText: String
    var models: [String] = []
    private(set) var baseline: ProviderProfile
    var id: UUID { profile.id }
    var isModified: Bool { profile != baseline || !key.isEmpty }
    var keyIsOptional: Bool { profile.localMode && profile.protocolKind == .openaiCompatible }
    nonisolated var description: String { "CreatorConnectionDraft(<redacted>)" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }

    init(_ profile: ProviderProfile) {
        self.profile = profile; baseline = profile
        tokenBudgetText = profile.limits.nativeOutputLimit == true ? "" : String(profile.limits.outputTokensPerRequest)
        contextText = profile.limits.contextWindow.map(String.init) ?? "131072"
    }
    func accept(_ saved: ProviderProfile) {
        guard saved.id == id, saved.connectionKind == profile.connectionKind else { return }
        profile = saved; baseline = saved; key = ""; models = []
        tokenBudgetText = saved.limits.nativeOutputLimit == true ? "" : String(saved.limits.outputTokensPerRequest)
        contextText = saved.limits.contextWindow.map(String.init) ?? "131072"
    }
    func targetChanged() { key = ""; models = [] }
    func changeProtocol(to kind: ProviderProfile.ProtocolKind) {
        key = ""; models = []
        profile.protocolKind = kind; profile.capabilities = .init()
    }
}

/// Separate form instances and preset identities for cloud providers and local services.
@MainActor @Observable
final class CreatorConnectionDrafts {
    private var cloud: [UUID: CreatorConnectionDraft] = [:]
    private var local: [UUID: CreatorConnectionDraft] = [:]
    private var presetIDs: [String: UUID] = [:]
    private(set) var selected: CreatorConnectionDraft

    init() {
        let draft = CreatorConnectionDraft(CreatorProviderCatalog.entry("custom-cloud")!.profile())
        selected = draft; cloud[draft.id] = draft
        presetIDs["custom-cloud"] = draft.id
    }
    func select(_ profile: ProviderProfile) {
        let cached = profile.localMode ? local[profile.id] : cloud[profile.id]
        if let cached {
            if !cached.isModified, cached.baseline != profile { cached.accept(profile) }
            selected = cached
        } else {
            let draft = CreatorConnectionDraft(profile)
            if profile.localMode { local[profile.id] = draft } else { cloud[profile.id] = draft }
            selected = draft
        }
    }
    func select(_ entry: CreatorProviderCatalog.Entry, profiles: [ProviderProfile]) {
        if !entry.custom, let saved = profiles.first(where: { $0.providerID == entry.id && $0.localMode == entry.local }) {
            select(saved); return
        }
        if let id = presetIDs[entry.id], let draft = entry.local ? local[id] : cloud[id],
           !entry.custom || !profiles.contains(where: { $0.id == id }) {
            selected = draft; return
        }
        let profile = entry.profile()
        presetIDs[entry.id] = profile.id
        select(profile)
    }
    func refresh(_ settings: CreatorSettings) {
        for saved in settings.profiles {
            let draft = saved.localMode ? local[saved.id] : cloud[saved.id]
            if let draft, !draft.isModified, draft.baseline != saved { draft.accept(saved) }
        }
    }
    func saved(_ profile: ProviderProfile, submitted: ProviderProfile) {
        let draft = profile.localMode ? local[profile.id] : cloud[profile.id]
        if let draft, draft.profile == submitted { draft.accept(profile) }
    }
    func remove(_ id: UUID) {
        cloud[id]?.key = ""; local[id]?.key = ""
        cloud.removeValue(forKey: id); local.removeValue(forKey: id)
        presetIDs = presetIDs.filter { $0.value != id }
        if selected.id == id {
            let entry = CreatorProviderCatalog.entry(selected.profile.localMode ? "custom-local" : "custom-cloud")!
            select(entry, profiles: [])
        }
    }
    func clearKeys() {
        for draft in cloud.values { draft.key = "" }
        for draft in local.values { draft.key = "" }
    }
}
