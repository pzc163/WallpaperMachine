import Foundation

/// Versioned native definitions shared by compilation, controls and runtime limits.
enum CreatorTemplateCatalog {
    enum Value: Codable, Equatable, Sendable {
        case number(Double), bool(Bool), choice(String)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else { self = .choice(try container.decode(String.self)) }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .choice(let value): try container.encode(value)
            }
        }

        var json: Any {
            switch self {
            case .number(let value): value
            case .bool(let value): value
            case .choice(let value): value
            }
        }
    }

    struct Choice: Sendable {
        let value: String
        let label: String
    }

    enum Domain: Sendable {
        case number(ClosedRange<Double>, step: Double, integer: Bool = false)
        case bool
        case choice([Choice])

        func accepts(_ value: Value) -> Bool {
            switch (self, value) {
            case (.number(let range, _, let integer), .number(let number)):
                number.isFinite && range.contains(number) && (!integer || number.rounded() == number)
            case (.bool, .bool): true
            case (.choice(let choices), .choice(let text)): choices.contains { $0.value == text }
            default: false
            }
        }

        var runtimeRule: [String: Any] {
            switch self {
            case .number(let range, _, let integer):
                ["type": "number", "min": range.lowerBound, "max": range.upperBound, "integer": integer]
            case .bool: ["type": "boolean"]
            case .choice(let choices): ["type": "string", "choices": choices.map(\.value)]
            }
        }
    }

    struct Parameter: Sendable {
        let id: String
        let label: String
        let unit: String
        let domain: Domain
        let defaultValue: Value

        func property(value: Value, order: Int) -> [String: Any] {
            // Existing inspector token handling localizes these native labels without
            // making bundle bytes depend on the machine's selected language.
            var result: [String: Any] = ["text": "ui_" + label.lowercased().replacingOccurrences(of: " ", with: "_"),
                                         "value": value.json, "order": order]
            switch domain {
            case .number(let range, let step, _):
                result.merge(["type": "slider", "min": range.lowerBound, "max": range.upperBound,
                              "step": step]) { _, new in new }
            case .bool: result["type"] = "bool"
            case .choice(let choices):
                result["type"] = "combo"
                result["options"] = choices.map { ["value": $0.value, "label": $0.label] }
            }
            return result
        }
    }

    struct Budget: Encodable, Equatable, Sendable {
        let maxParticles = 384
        let maxTrailSegments = 1536
        let maxTrailSegmentsPerParticle = 8
        let maxMeteors = 2
        let maxPixels = 2_073_600
        let maxDimension = 4096
        let maxFPS = 30
        let maxGrain = 128
        let gradientBands = 12
        let maxDeviceScale = 2
        let seed: UInt32 = 0x51c0ffee
    }

    struct Allocation: Equatable, Sendable {
        let particles: Int
        let segmentsPerParticle: Int
        var trailSegments: Int { particles * segmentsPerParticle }
    }

    struct Preset: Sendable {
        let id: String
        let label: String
        let parameters: [String: Value]
    }

    struct Definition: Sendable {
        let id: String
        let kind: CreatorTemplate.Kind
        let label: String
        let parameters: [Parameter]
        let presetOverrides: [(String, String, [String: Value])]
        let budget = Budget()

        var defaults: [String: Value] { Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.defaultValue) }) }
        var presets: [Preset] {
            presetOverrides.map { Preset(id: $0.0, label: $0.1, parameters: defaults.merging($0.2) { _, new in new }) }
        }

        func validate(_ values: [String: Value]) throws {
            guard Set(values.keys) == Set(parameters.map(\.id)),
                  parameters.allSatisfy({ values[$0.id].map($0.domain.accepts) == true }) else {
                throw CreatorTemplate.Failure.invalidSpecification
            }
        }

        func allocation(for values: [String: Value]) throws -> Allocation {
            try validate(values)
            guard kind == .stars, case .number(let density) = values["starDensity"],
                  case .number(let trail) = values["trailLength"] else {
                return Allocation(particles: 0, segmentsPerParticle: 0)
            }
            let count = Int((density * Double(budget.maxParticles)).rounded(.down))
            let segments = min(Int((trail * Double(budget.maxTrailSegmentsPerParticle)).rounded(.down)),
                               budget.maxTrailSegments / max(1, count))
            return Allocation(particles: count, segmentsPerParticle: count == 0 ? 0 : segments)
        }

        func specification(projectID: UUID = UUID(), parameters values: [String: Value]? = nil) throws -> CreatorTemplate.Specification {
            let values = values ?? defaults
            try validate(values)
            return .init(projectID: projectID, kind: kind, templateID: id, parameters: values, rendererRevision: 3)
        }

        func properties(for values: [String: Value]) throws -> [String: Any] {
            try validate(values)
            return Dictionary(uniqueKeysWithValues: parameters.enumerated().map {
                ($0.element.id, $0.element.property(value: values[$0.element.id]!, order: $0.offset))
            })
        }
    }

    static func definition(_ id: String) throws -> Definition {
        guard let result = all.first(where: { $0.id == id }) else { throw CreatorTemplate.Failure.invalidSpecification }
        return result
    }

    private static func number(_ id: String, _ label: String, _ range: ClosedRange<Double>, _ value: Double,
                               step: Double = 0.01, unit: String = "ratio", integer: Bool = false) -> Parameter {
        Parameter(id: id, label: label, unit: unit, domain: .number(range, step: step, integer: integer), defaultValue: .number(value))
    }
    private static func boolean(_ id: String, _ label: String, _ value: Bool) -> Parameter {
        Parameter(id: id, label: label, unit: "", domain: .bool, defaultValue: .bool(value))
    }
    private static func choice(_ id: String, _ label: String, _ values: [(String, String)], _ value: String) -> Parameter {
        Parameter(id: id, label: label, unit: "", domain: .choice(values.map { Choice(value: $0.0, label: $0.1) }),
                  defaultValue: .choice(value))
    }
    private static let anchors = [
        ("topLeft", "Top left"), ("topCenter", "Top center"), ("topRight", "Top right"),
        ("middleLeft", "Middle left"), ("center", "Center"), ("middleRight", "Middle right"),
        ("bottomLeft", "Bottom left"), ("bottomCenter", "Bottom center"), ("bottomRight", "Bottom right"),
    ]
    private static let colors = [
        number("primaryHue", "Primary hue", 0...360, 220, step: 1, unit: "degrees"),
        number("secondaryHue", "Secondary hue", 0...360, 280, step: 1, unit: "degrees"),
    ]
    private static let clockPosition = [
        choice("clockAnchor", "Clock anchor", anchors, "center"),
        number("clockScale", "Clock scale", 0.5...1.5, 1),
    ]

    static let all: [Definition] = [
        Definition(id: "gradient-v2", kind: .gradient, label: "Flowing gradient", parameters: colors + [
            number("angle", "Gradient angle", 0...360, 35, step: 1, unit: "degrees"),
            number("contrast", "Contrast", 0...1, 0.5),
            number("motionSpeed", "Motion speed", 0...2, 0.5),
            number("waveScale", "Wave scale", 0.5...4, 1.5),
            number("waveStrength", "Wave strength", 0...1, 0.5),
            number("grainAmount", "Grain amount", 0...1, 0.3),
            number("breathingHz", "Breathing frequency", 0...2, 0.2, unit: "Hz"),
            number("vignette", "Vignette", 0...1, 0.3),
        ], presetOverrides: [
            ("aurora", "Aurora ribbons", ["primaryHue": .number(165), "secondaryHue": .number(275), "waveStrength": .number(0.8)]),
            ("ember", "Ember haze", ["primaryHue": .number(12), "secondaryHue": .number(45), "angle": .number(125), "contrast": .number(0.8), "waveScale": .number(3.5), "grainAmount": .number(0.8)]),
        ]),
        Definition(id: "stars-v2", kind: .stars, label: "Layered starfield", parameters: [
            number("starDensity", "Star density", 0...1, 0.55),
            number("starSizeSpread", "Star size spread", 0...1, 0.6),
            number("trailLength", "Trail length", 0...1, 0.4),
            number("parallaxLayers", "Parallax layers", 1...4, 3, step: 1, unit: "layers", integer: true),
            number("twinkleHz", "Twinkle frequency", 0...3, 0.7, unit: "Hz"),
            number("meteorRate", "Meteor frequency", 0...6, 2, step: 0.1, unit: "events/minute"),
        ] + colors + [
            number("motionSpeed", "Motion speed", 0...2, 0.5),
            boolean("clockVisible", "Show clock", true),
        ] + clockPosition, presetOverrides: [
            ("quiet", "Quiet orbit", ["starDensity": .number(0.3), "primaryHue": .number(225), "secondaryHue": .number(260), "trailLength": .number(0), "clockAnchor": .choice("bottomRight")]),
            ("voyage", "Meteor voyage", ["starDensity": .number(1), "primaryHue": .number(165), "secondaryHue": .number(310), "motionSpeed": .number(1.5), "trailLength": .number(1), "meteorRate": .number(6), "parallaxLayers": .number(4), "clockVisible": .bool(false)]),
        ]),
        Definition(id: "clock-v2", kind: .clock, label: "Ambient clock", parameters: colors + [
            number("backgroundMotion", "Background motion", 0...2, 0.4),
        ] + clockPosition + [
            choice("hourFormat", "Hour format", [("12h", "12-hour"), ("24h", "24-hour")], "24h"),
            boolean("showSeconds", "Show seconds", true),
            boolean("showDate", "Show date", true),
            choice("font", "Clock font", [("system", "System font"), ("serif", "Serif"), ("monospace", "Monospace")], "system"),
            number("glow", "Clock glow", 0...1, 0.4),
        ], presetOverrides: [
            ("dawn", "Dawn dial", ["primaryHue": .number(25), "secondaryHue": .number(315), "font": .choice("serif"), "clockAnchor": .choice("middleLeft"), "hourFormat": .choice("12h")]),
            ("terminal", "Night terminal", ["primaryHue": .number(155), "secondaryHue": .number(205), "font": .choice("monospace"), "clockAnchor": .choice("bottomRight"), "clockScale": .number(0.8), "glow": .number(0.9), "showDate": .bool(false)]),
        ]),
    ]
}
