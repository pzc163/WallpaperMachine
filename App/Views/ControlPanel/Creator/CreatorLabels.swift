import Foundation

@MainActor enum CreatorLabels {
    static func connection(_ result: CreatorWorkspace.ConnectionResult) -> String {
        let mode: String
        if result.protocolKind == .geminiGenerateContent { mode = L("Native JSON") }
        else if result.protocolKind == .anthropicMessages { mode = L("Prompt JSON") }
        else {
            switch result.mode {
            case .schema: mode = L("JSON Schema (strict)")
            case .required: mode = L("JSON object (required)")
            case .disabled: mode = L("Prompt JSON")
            case .automatic: mode = L("Automatic (with fallback)")
            }
        }
        return String(format: L("Connection verified: %@ · %@ · %@ s"), result.model, mode, result.elapsed.formatted(.number.precision(.fractionLength(1))))
    }
    static func phase(_ phase: CreatorModel.Phase) -> String {
        switch phase {
        case .idle: L("Ready to create")
        case .generating: L("Generating parameters")
        case .repairPending: L("Preparing a repair")
        case .runtime: L("Checking the preview")
        case .sealing: L("Capturing the cover")
        case .ready: L("Validated · ready to save")
        case .saving: L("Saving to the library")
        case .saved: L("Saved · desktop unchanged")
        case .editing: L("Updating project")
        case .failed: L("Creation failed")
        case .cancelled: L("Cancelled")
        }
    }
    static func issue(_ category: CreatorRepairIssue.Category) -> String {
        switch category {
        case .unauthorized: L("Authentication failed. Check the saved key.")
        case .rateLimited: L("The provider is rate limited. Try again later.")
        case .timeout: L("The request timed out.")
        case .network, .server: L("The model connection was interrupted.")
        case .cancelled: L("Cancelled. A sent request may still be billed.")
        case .interrupted: L("An unfinished task was recovered after restart.")
        case .budgetExhausted: L("The request budget is exhausted.")
        case .malformedOutput, .policyViolation, .jsonModeUnsupported: L("The generated parameters did not pass validation.")
        case .runtime: L("The preview did not pass validation.")
        case .staleInput, .refused: L("The connection or revision changed. Check the model settings and saved key.")
        case .storage: L("The project could not be read or saved. Check storage and the validation report.")
        case .invalidRequest: L("Check the prompt, connection and generation budgets.")
        }
    }
}
