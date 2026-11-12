import SwiftUI

struct CreatorGenerationOptions: View {
    @Binding var profile: ProviderProfile
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if profile.supportsReasoningEffort {
                Picker("Kimi reasoning effort", selection: Binding(get: { profile.reasoningEffort ?? .low }, set: { profile.reasoningEffort = $0 })) {
                    Text("Low · faster response").tag(LLMReasoningEffort.low)
                    Text("High · more reasoning").tag(LLMReasoningEffort.high)
                    Text("Maximum · longest reasoning").tag(LLMReasoningEffort.max)
                }.accessibilityIdentifier("creator-reasoning-effort")
                Text("Kimi K3 always reasons. Low is the default; higher effort can take much longer.").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Generation time limits") {
                Toggle("Custom time limits", isOn: Binding(get: { profile.timeoutPolicy != nil }, set: { profile.timeoutPolicy = $0 ? profile.effectiveTimeoutPolicy : nil }))
                    .toggleStyle(.checkbox).accessibilityIdentifier("creator-custom-timeouts")
                if profile.timeoutPolicy != nil {
                    seconds("First response (seconds)", \.firstResponse)
                    seconds("First content (seconds)", \.firstContent)
                    seconds("Stream idle (seconds)", \.idle)
                    seconds("Total request (seconds)", \.total)
                } else {
                    Text(verbatim: String(format: L("Automatic limits · first response %lld s · first content %lld s · idle %lld s · total %lld min"),
                        Int(profile.effectiveTimeoutPolicy.firstResponse), Int(profile.effectiveTimeoutPolicy.firstContent),
                        Int(profile.effectiveTimeoutPolicy.idle), Int(profile.effectiveTimeoutPolicy.total / 60)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Thinking and output keep the stream alive. Heartbeats do not replace the first content. You can stop at any time. Maximum total: 120 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }.accessibilityIdentifier("creator-timeout-options")
        }
    }
    private func seconds(_ label: String, _ key: WritableKeyPath<LLMTimeoutPolicy, TimeInterval>) -> some View {
        LabeledContent {
            TextField("Seconds", value: Binding(get: { profile.effectiveTimeoutPolicy[keyPath: key] }, set: { value in
                var policy = profile.effectiveTimeoutPolicy; policy[keyPath: key] = value; profile.timeoutPolicy = policy
            }), format: .number).frame(maxWidth: 130)
        } label: { Text(verbatim: PanelLocale.shared.catalogString(label)) }
    }
}
