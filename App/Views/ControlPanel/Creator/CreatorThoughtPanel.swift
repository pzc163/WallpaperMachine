import SwiftUI

struct CreatorThoughtPanel: View {
    let transcript: CreatorTranscript
    @State private var expanded = true
    var body: some View {
        if !transcript.progress.reasoning.isEmpty || transcript.isThinking {
            DisclosureGroup(isExpanded: $expanded) {
                if !transcript.progress.reasoning.isEmpty {
                    CreatorStreamTextView(text: transcript.progress.reasoning, monospaced: false)
                        .frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if transcript.progress.reasoningTruncated {
                    Text("The displayed thinking reached the session limit.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Model-provided thinking · session only").font(.caption).foregroundStyle(.tertiary)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: transcript.isThinking ? "sparkle" : "text.bubble")
                    if transcript.isThinking {
                        Text("Thinking deeply…")
                        Text(transcript.startedAt, style: .timer).monospacedDigit()
                    } else {
                        Text("Thinking process")
                        Text(verbatim: String(format: L("Thought for %lld s"), max(0, Int((transcript.thinkingEndedAt ?? transcript.startedAt).timeIntervalSince(transcript.startedAt)))))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.font(.caption)
            }
            .onAppear { expanded = transcript.isThinking }
            .onChange(of: transcript.completed) { _, done in if done { expanded = false } }
            .accessibilityIdentifier("creator-thinking")
        }
    }
}
