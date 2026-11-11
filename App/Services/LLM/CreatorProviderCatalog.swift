import Foundation

/// Offline connection presets, not a remotely maintained model list or an authorization grant.
enum CreatorProviderCatalog {
    struct Entry: Identifiable, Sendable {
        let id: String
        let name: String
        let protocolKind: ProviderProfile.ProtocolKind
        let endpoints: [String]
        let icon: String?
        var local = false
        var custom = false
        func profile() -> ProviderProfile {
            ProviderProfile(name: custom ? "" : name, protocolKind: protocolKind, baseURL: endpoints.first ?? "", model: "",
                providerID: id, localMode: local)
        }
    }
    static let entries: [Entry] = [
        .init(id: "openai", name: "OpenAI", protocolKind: .openaiCompatible, endpoints: ["https://api.openai.com/v1"], icon: "openai"),
        .init(id: "anthropic", name: "Anthropic", protocolKind: .anthropicMessages, endpoints: ["https://api.anthropic.com/v1"], icon: "anthropic"),
        .init(id: "google", name: "Google (Gemini)", protocolKind: .geminiGenerateContent, endpoints: ["https://generativelanguage.googleapis.com/v1beta"], icon: "gemini"),
        .init(id: "xai", name: "xAI (Grok)", protocolKind: .openaiCompatible, endpoints: ["https://api.x.ai/v1"], icon: "xai"),
        .init(id: "zai", name: "Z.ai", protocolKind: .openaiCompatible, endpoints: ["https://api.z.ai/api/paas/v4", "https://open.bigmodel.cn/api/paas/v4"], icon: "zai"),
        .init(id: "kimi", name: "Kimi", protocolKind: .openaiCompatible, endpoints: ["https://api.moonshot.cn/v1", "https://api.moonshot.ai/v1"], icon: "kimi"),
        .init(id: "qwen", name: "Qwen", protocolKind: .openaiCompatible, endpoints: ["https://dashscope.aliyuncs.com/compatible-mode/v1", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"], icon: "qwen"),
        .init(id: "minimax", name: "MiniMax", protocolKind: .openaiCompatible, endpoints: ["https://api.minimaxi.com/v1", "https://api.minimax.io/v1"], icon: "minimax"),
        .init(id: "hunyuan", name: "Hunyuan", protocolKind: .openaiCompatible, endpoints: ["https://api.hunyuan.cloud.tencent.com/v1"], icon: "hunyuan"),
        .init(id: "deepseek", name: "DeepSeek", protocolKind: .openaiCompatible, endpoints: ["https://api.deepseek.com/v1"], icon: "deepseek"),
        .init(id: "minicpm", name: "MiniCPM", protocolKind: .openaiCompatible, endpoints: ["https://api.modelbest.cn/v1"], icon: nil),
        .init(id: "custom-cloud", name: "Custom cloud service", protocolKind: .openaiCompatible, endpoints: [], icon: nil, custom: true),
        .init(id: "lmstudio", name: "LM Studio", protocolKind: .openaiCompatible, endpoints: ["http://127.0.0.1:1234/v1"], icon: "lmstudio", local: true),
        .init(id: "ollama", name: "Ollama", protocolKind: .openaiCompatible, endpoints: ["http://127.0.0.1:11434/v1"], icon: "ollama", local: true),
        .init(id: "custom-local", name: "Custom local service", protocolKind: .openaiCompatible, endpoints: [], icon: nil, local: true, custom: true)
    ]
    static func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }
    static func icon(profile: ProviderProfile, model: String? = nil) -> String? {
        if let model = model?.lowercased() {
            for (prefix, icon) in [("claude", "claude"), ("gemini", "gemini"), ("grok", "grok"), ("qwen", "qwen"), ("deepseek", "deepseek"), ("kimi", "kimi"), ("glm", "zhipu")] where model.hasPrefix(prefix) { return icon }
        }
        if profile.providerID == "minicpm" { return "minicpm" }
        return profile.providerID.flatMap(entry)?.icon
    }
}
