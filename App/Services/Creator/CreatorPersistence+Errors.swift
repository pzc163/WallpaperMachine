import Foundation

/// Native categories only: never show a corrupt record, credential or filesystem path.
extension CreatorPersistence.Failure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            String(localized: "This AI wallpaper uses an unsupported policy or data version. Update the app or revalidate the project before playing it.")
        case .busy:
            String(localized: "Creator storage is busy or publication is unfinished. Wait for the current operation or reopen the app to recover it.")
        default:
            String(localized: "Creator data or validation evidence is missing or changed. Revalidate the project before playing it.")
        }
    }
}

extension CreatorTemplate.Failure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .busy: CreatorPersistence.Failure.busy.errorDescription
        default: CreatorPersistence.Failure.invalidRecord.errorDescription
        }
    }
}
