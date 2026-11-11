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
        do { return try detailed(text) }
        catch let issue as CreatorRepairIssue {
            throw issue.category == .policyViolation ? CreatorGenerationFailure.policyViolation : CreatorGenerationFailure.malformedOutput
        }
    }
    static func detailed(_ text: String) throws -> Output {
        try Task.checkCancellation()
        let unwrapped: String
        do { unwrapped = try LLMJSONEnvelope.unwrap(text) }
        catch { throw CreatorRepairIssue.field("$", .syntax) }
        let object: CreatorJSON.Value
        do { object = try CreatorJSON.parse(unwrapped) }
        catch is CancellationError { throw CancellationError() }
        catch { throw CreatorRepairIssue.field("$", .syntax) }
        guard let root = object.object else { throw CreatorRepairIssue.field("$", .type) }
        let keys: Set<String> = ["schemaVersion", "templateID", "title", "summary", "parameters", "properties"]
        guard Set(root.keys).isSubset(of: keys) else { throw CreatorRepairIssue.field("$", .unexpected, policy: true) }
        guard Set(root.keys) == keys else {
            throw CreatorRepairIssue(category: .malformedOutput, fields: keys.subtracting(root.keys).sorted().map { .init(path: $0, rule: .missing) })
        }
        guard root["schemaVersion"] == .number(1) else { throw CreatorRepairIssue.field("schemaVersion", .choice, policy: true) }
        guard let id = root["templateID"]?.string, let definition = CreatorTemplateCatalog.all.first(where: { $0.id == id })
        else { throw CreatorRepairIssue.field("templateID", .choice, policy: true) }
        guard let title = root["title"]?.string, CreatorBundlePresentation.validText(title, limit: CreatorBundlePresentation.titleLimit)
        else { throw CreatorRepairIssue.field("title", .text) }
        guard let summary = root["summary"]?.string, CreatorBundlePresentation.validText(summary, limit: CreatorBundlePresentation.summaryLimit)
        else { throw CreatorRepairIssue.field("summary", .text) }
        guard let parameters = root["parameters"]?.object else { throw CreatorRepairIssue.field("parameters", .type) }
        guard let properties = root["properties"]?.object else { throw CreatorRepairIssue.field("properties", .type) }
        let presentation = CreatorBundlePresentation(title: title, summary: summary)
        try presentation.validate()
        let allowed = Set(definition.parameters.map(\.id))
        guard Set(parameters.keys).isSubset(of: allowed) else { throw CreatorRepairIssue.field("parameters", .unexpected, policy: true) }
        guard Set(properties.keys).isSubset(of: allowed) else { throw CreatorRepairIssue.field("properties", .unexpected, policy: true) }
        guard Set(parameters.keys) == allowed else {
            throw CreatorRepairIssue(category: .malformedOutput, fields: allowed.subtracting(parameters.keys).sorted().map { .init(path: "parameters." + $0, rule: .missing) })
        }
        var values: [String: CreatorTemplateCatalog.Value] = [:]
        for parameter in definition.parameters {
            try Task.checkCancellation()
            guard let value = parameters[parameter.id]?.parameter else { throw CreatorRepairIssue.field("parameters." + parameter.id, .type) }
            guard parameter.domain.accepts(value) else {
                let rule: CreatorRepairIssue.Rule
                switch (parameter.domain, value) {
                case (.number, .number): rule = .range
                case (.choice, .choice): rule = .choice
                default: rule = .type
                }
                throw CreatorRepairIssue.field("parameters." + parameter.id, rule)
            }
            values[parameter.id] = value
        }
        for (key, property) in properties {
            guard let fields = property.object else { throw CreatorRepairIssue.field("properties." + key, .type) }
            guard Set(fields.keys).isSubset(of: ["default"]) else { throw CreatorRepairIssue.field("properties." + key, .unexpected, policy: true) }
            guard fields.count == 1, fields["default"]?.parameter == values[key] else { throw CreatorRepairIssue.field("properties." + key + ".default", .defaultMismatch) }
        }
        try definition.validate(values)
        let allocation = try definition.allocation(for: values)
        guard allocation.particles <= definition.budget.maxParticles, allocation.trailSegments <= definition.budget.maxTrailSegments
        else { throw CreatorRepairIssue.field("parameters", .resourceBudget, policy: true) }
        return Output(templateID: id, presentation: presentation, parameters: values)
    }
}
