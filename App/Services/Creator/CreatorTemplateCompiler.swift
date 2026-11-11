import Foundation

enum CreatorTemplateCompiler {
    struct Compiled: Sendable {
        let specification: CreatorTemplate.Specification
        let presentation: CreatorBundlePresentation
    }
    static func compile(_ output: CreatorOutputValidator.Output, projectID: UUID) throws -> Compiled {
        try Task.checkCancellation()
        let definition = try CreatorTemplateCatalog.definition(output.templateID)
        try output.presentation.validate()
        return Compiled(specification: try definition.specification(projectID: projectID, parameters: output.parameters),
                        presentation: output.presentation)
    }
}
