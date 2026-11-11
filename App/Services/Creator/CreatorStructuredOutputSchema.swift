import Foundation

/// Conservative request grammar, not a replacement for CreatorOutputSchema/Validator.
/// No draft/refs/conditionals, root unions, or provider-specific numeric/text bounds.
enum CreatorStructuredOutputSchema {
    static func make() throws -> LLMRequest.StructuredOutput {
        let branches: [[String: Any]] = CreatorTemplateCatalog.all.map { template in
            let parameters = Dictionary(uniqueKeysWithValues: template.parameters.map { item in
                // The native catalog owns types/enums. Ranges and resource limits stay
                // in the prompt and mandatory native validation for every provider.
                (item.id, CreatorOutputSchema.parameter(item).filter { ["type", "enum"].contains($0.key) })
            })
            var branch = object(parameters)
            branch["description"] = "Complete parameters for " + template.id + " only."
            return branch
        }
        let schema = object([
            "schemaVersion": ["type": "integer", "enum": [1]],
            "templateID": ["type": "string", "enum": CreatorTemplateCatalog.all.map(\.id)],
            "title": ["type": "string"], "summary": ["type": "string"],
            // Nested anyOf is portable; native validation binds its selected branch
            // to templateID. Never move this union to the root or add if/then/allOf.
            "parameters": ["anyOf": branches],
            "properties": object([:]),
        ])
        return .init(name: "template_parameter_output_v1", schema: try CreatorOutputSchema.encode(schema))
    }

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }
}
