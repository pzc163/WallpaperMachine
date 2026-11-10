import Foundation

/// Schema and prompt catalog derive domains from the same native definitions as rendering.
enum CreatorOutputSchema {
    static func parameter(_ parameter: CreatorTemplateCatalog.Parameter) -> [String: Any] {
        switch parameter.domain {
        case .number(let range, _, let integer):
            ["type": integer ? "integer" : "number", "minimum": range.lowerBound, "maximum": range.upperBound]
        case .bool: ["type": "boolean"]
        case .choice(let choices): ["type": "string", "enum": choices.map(\.value)]
        }
    }
    static func document() throws -> Data {
        var definitions: [String: Any] = [:]
        for template in CreatorTemplateCatalog.all {
            let parameters = Dictionary(uniqueKeysWithValues: template.parameters.map { ($0.id, parameter($0)) })
            let controls = Dictionary(uniqueKeysWithValues: template.parameters.map {
                ($0.id, object(properties: ["default": ["$ref": "#/$defs/\(template.id)/properties/parameters/properties/\($0.id)"]],
                               required: ["default"]))
            })
            definitions[template.id] = object(properties: [
                "schemaVersion": ["type": "integer", "const": 1],
                "templateID": ["type": "string", "const": template.id],
                "title": text(limit: CreatorBundlePresentation.titleLimit),
                "summary": text(limit: CreatorBundlePresentation.summaryLimit),
                "parameters": object(properties: parameters, required: template.parameters.map(\.id)),
                "properties": object(properties: controls, required: []),
            ], required: ["schemaVersion", "templateID", "title", "summary", "parameters", "properties"])
        }
        return try encode(["$schema": "https://json-schema.org/draft/2020-12/schema",
            "description": "TemplateParameterOutput v1. Each properties.default must equal the corresponding parameters value; native validation enforces this cross-field invariant.",
            "$defs": definitions, "oneOf": CreatorTemplateCatalog.all.map { ["$ref": "#/$defs/" + $0.id] }])
    }
    static func promptCatalog() throws -> Data {
        let templates: [[String: Any]] = try CreatorTemplateCatalog.all.map { template in
            let budget = try JSONSerialization.jsonObject(with: CreatorPersistence.encode(template.budget))
            return ["templateID": template.id, "label": template.label, "resourceLimits": budget,
                "parameters": template.parameters.map { item -> [String: Any] in
                    var result: [String: Any] = ["id": item.id, "unit": item.unit, "default": item.defaultValue.json,
                                                  "schema": parameter(item)]
                    if case .number(_, let step, _) = item.domain { result["uiStep"] = step }
                    return result
                },
                "presets": template.presets.map { ["id": $0.id, "parameters": $0.parameters.mapValues(\.json)] as [String: Any] }]
        }
        return try encode(["templates": templates])
    }
    static func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func object(properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "additionalProperties": false, "properties": properties, "required": required]
    }
    private static func text(limit: Int) -> [String: Any] {
        ["type": "string", "minLength": 1, "maxLength": limit,
         "allOf": [["pattern": CreatorBundlePresentation.textPattern], ["pattern": "\\S"]]]
    }
}
