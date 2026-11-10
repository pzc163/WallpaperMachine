import Foundation

enum CreatorOutputValidator {
    struct Output: Equatable, Sendable {
        let templateID: String
        let presentation: CreatorBundlePresentation
        let parameters: [String: CreatorTemplateCatalog.Value]
        fileprivate init(templateID: String, presentation: CreatorBundlePresentation, parameters: [String: CreatorTemplateCatalog.Value]) {
            self.templateID = templateID; self.presentation = presentation; self.parameters = parameters
        }
    }
    static func parse(_ text: String) throws -> Output {
        try Task.checkCancellation()
        let unwrapped: String
        do { unwrapped = try LLMJSONEnvelope.unwrap(text) }
        catch { throw CreatorGenerationFailure.malformedOutput }
        guard let root = try CreatorJSON.parse(unwrapped).object else { throw CreatorGenerationFailure.malformedOutput }
        let keys: Set<String> = ["schemaVersion", "templateID", "title", "summary", "parameters", "properties"]
        guard Set(root.keys).isSubset(of: keys) else { throw CreatorGenerationFailure.policyViolation }
        guard Set(root.keys) == keys else { throw CreatorGenerationFailure.malformedOutput }
        guard root["schemaVersion"] == .number(1) else { throw CreatorGenerationFailure.policyViolation }
        guard let id = root["templateID"]?.string, let definition = CreatorTemplateCatalog.all.first(where: { $0.id == id })
        else { throw CreatorGenerationFailure.policyViolation }
        guard let title = root["title"]?.string, let summary = root["summary"]?.string,
              let parameters = root["parameters"]?.object, let properties = root["properties"]?.object
        else { throw CreatorGenerationFailure.malformedOutput }
        let presentation = CreatorBundlePresentation(title: title, summary: summary)
        try presentation.validate()
        let allowed = Set(definition.parameters.map(\.id))
        guard Set(parameters.keys).isSubset(of: allowed), Set(properties.keys).isSubset(of: allowed)
        else { throw CreatorGenerationFailure.policyViolation }
        guard Set(parameters.keys) == allowed else { throw CreatorGenerationFailure.malformedOutput }
        var values: [String: CreatorTemplateCatalog.Value] = [:]
        for parameter in definition.parameters {
            try Task.checkCancellation()
            guard let value = parameters[parameter.id]?.parameter, parameter.domain.accepts(value)
            else { throw CreatorGenerationFailure.malformedOutput }
            values[parameter.id] = value
        }
        for (key, property) in properties {
            guard let fields = property.object else { throw CreatorGenerationFailure.malformedOutput }
            guard Set(fields.keys).isSubset(of: ["default"]) else { throw CreatorGenerationFailure.policyViolation }
            guard fields.count == 1, fields["default"]?.parameter == values[key] else { throw CreatorGenerationFailure.malformedOutput }
        }
        try definition.validate(values)
        let allocation = try definition.allocation(for: values)
        guard allocation.particles <= definition.budget.maxParticles, allocation.trailSegments <= definition.budget.maxTrailSegments
        else { throw CreatorGenerationFailure.policyViolation }
        return Output(templateID: id, presentation: presentation, parameters: values)
    }
}
