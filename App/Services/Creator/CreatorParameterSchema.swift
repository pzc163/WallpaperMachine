import Foundation

/// A closed, bounded declaration. Values are scalars; definitions never become executable code.
struct CreatorParameterSchema: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case number, boolean, color }
    struct Parameter: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let label: String
        let type: Kind
        let defaultValue: CreatorTemplateCatalog.Value
        var min: Double? = nil
        var max: Double? = nil
        var step: Double? = nil
        enum CodingKeys: String, CodingKey { case id, label, type, defaultValue = "default", min, max, step }
        func accepts(_ value: CreatorTemplateCatalog.Value) -> Bool {
            switch (type, value) {
            case (.number, .number(let value)):
                return value.isFinite && value >= (min ?? 0) && value <= (max ?? 0)
            case (.boolean, .bool): return true
            case (.color, .choice(let value)): return value.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil
            default: return false
            }
        }
    }
    var version = 1
    var parameters: [Parameter]
    var values: [String: CreatorTemplateCatalog.Value]
    static let pattern = #"(?is)<script\s+id="wm-params"\s+type="application/json"\s*>(.*?)</script\s*>"#
    static func read(_ html: String) throws -> Self? {
        let regex = try NSRegularExpression(pattern: pattern), string = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: string.length))
        guard matches.count <= 1 else { throw CreatorRepairIssue.field("properties", .unexpected, policy: true) }
        guard let match = matches.first else { return nil }
        return try parse(string.substring(with: match.range(at: 1)))
    }
    static func parse(_ json: String) throws -> Self {
        guard case .object(let root) = try CreatorJSON.parse(json), Set(root.keys) == ["version", "parameters", "values"],
              case .array(let list) = root["parameters"], list.count <= 16 else { throw CreatorRepairIssue.field("properties", .unexpected, policy: true) }
        for item in list {
            guard case .object(let object) = item, Set(object.keys).isSubset(of: ["id", "label", "type", "default", "min", "max", "step"]),
                  Set(["id", "label", "type", "default"]).isSubset(of: Set(object.keys)) else { throw CreatorRepairIssue.field("properties", .unexpected, policy: true) }
        }
        let schema: Self
        do { schema = try JSONDecoder().decode(Self.self, from: Data(json.utf8)); try schema.validate() }
        catch { throw CreatorRepairIssue.field("properties", .range, policy: true) }
        return schema
    }
    func validate(_ next: [String: CreatorTemplateCatalog.Value]? = nil) throws {
        guard version == 1, parameters.count <= 16, Set(parameters.map(\.id)).count == parameters.count else { throw CreatorPersistence.Failure.invalidRecord }
        for p in parameters {
            guard p.id.range(of: #"^[a-zA-Z][a-zA-Z0-9_]{0,31}$"#, options: .regularExpression) != nil,
                  !["constructor", "prototype", "__proto__"].contains(p.id), !p.label.isEmpty, p.label.count <= 60,
                  !p.label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  LLMStreamText.sanitize(p.label) == p.label else { throw CreatorPersistence.Failure.invalidRecord }
            if p.type == .number {
                guard let lower = p.min, let upper = p.max, let step = p.step, lower.isFinite, upper.isFinite, step.isFinite,
                      lower >= -10_000, upper <= 10_000, lower < upper, step > 0, step <= upper-lower,
                      (upper-lower)/step <= 100_000 else { throw CreatorPersistence.Failure.invalidRecord }
            } else if p.min != nil || p.max != nil || p.step != nil { throw CreatorPersistence.Failure.invalidRecord }
            guard p.accepts(p.defaultValue) else { throw CreatorPersistence.Failure.invalidRecord }
        }
        let values = next ?? values
        guard Set(values.keys) == Set(parameters.map(\.id)), parameters.allSatisfy({ $0.accepts(values[$0.id]!) }) else { throw CreatorPersistence.Failure.invalidRecord }
    }
    func replacing(in html: String, with values: [String: CreatorTemplateCatalog.Value]) throws -> String {
        try validate(values)
        var next = self; next.values = values
        let regex = try NSRegularExpression(pattern: Self.pattern), text = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: text.length)),
              let range = Range(match.range(at: 1), in: html) else { throw CreatorPersistence.Failure.invalidRecord }
        return html.replacingCharacters(in: range, with: try next.json())
    }
    func json() throws -> String { String(decoding: try CreatorPersistence.encode(self), as: UTF8.self).replacingOccurrences(of: "<", with: #"\u003c"#) }
    var properties: [String: Any] {
        Dictionary(uniqueKeysWithValues: parameters.enumerated().map { index, p in
            var entry: [String: Any] = ["type": p.type == .number ? "slider" : p.type == .boolean ? "bool" : "color", "text": p.label, "value": values[p.id]!.json, "order": index]
            if p.type == .number { entry["min"] = p.min; entry["max"] = p.max; entry["step"] = p.step }
            if p.type == .color, case .choice(let hex) = values[p.id] { entry["value"] = Self.rgb(hex).map { String($0) }.joined(separator: " ") }
            return (p.id, entry)
        })
    }
    static func rgb(_ hex: String) -> [Double] {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return [Double((value >> 16) & 255)/255, Double((value >> 8) & 255)/255, Double(value & 255)/255]
    }
}
