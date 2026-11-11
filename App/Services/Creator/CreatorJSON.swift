import Foundation

/// Bounded JSON grammar with duplicate-key rejection before Foundation can collapse an object.
enum CreatorJSON {
    indirect enum Value: Equatable, Sendable {
        case object([String: Value]), array([Value]), string(String), number(Double), bool(Bool), null
        var object: [String: Value]? { if case .object(let value) = self { value } else { nil } }
        var string: String? { if case .string(let value) = self { value } else { nil } }
        var parameter: CreatorTemplateCatalog.Value? {
            switch self {
            case .number(let value): .number(value)
            case .bool(let value): .bool(value)
            case .string(let value): .choice(value)
            default: nil
            }
        }
    }
    static func parse(_ text: String, maximumBytes: Int = LLMJSONEnvelope.maximumBytes) throws -> Value {
        guard text.utf8.count <= maximumBytes else { throw CreatorGenerationFailure.malformedOutput }
        var parser = Parser(bytes: Array(text.utf8))
        let result = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw CreatorGenerationFailure.malformedOutput }
        return result
    }
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var nodes = 0
        var current: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func whitespace() { while let byte = current, [9, 10, 13, 32].contains(byte) { index += 1 } }
        mutating func take(_ byte: UInt8) -> Bool {
            guard current == byte else { return false }
            index += 1; return true
        }
        mutating func require(_ byte: UInt8) throws {
            guard take(byte) else { throw CreatorGenerationFailure.malformedOutput }
        }
        mutating func value(depth: Int) throws -> Value {
            try Task.checkCancellation()
            nodes += 1
            guard depth <= 8, nodes <= 4096 else { throw CreatorGenerationFailure.malformedOutput }
            whitespace()
            guard let byte = current else { throw CreatorGenerationFailure.malformedOutput }
            switch byte {
            case 123:
                index += 1; whitespace()
                var object: [String: Value] = [:]
                if take(125) { return .object(object) }
                while true {
                    whitespace()
                    let key = try string()
                    guard object[key] == nil else { throw CreatorGenerationFailure.malformedOutput }
                    whitespace(); try require(58)
                    object[key] = try value(depth: depth + 1)
                    whitespace()
                    if take(125) { return .object(object) }
                    try require(44)
                }
            case 91:
                index += 1; whitespace()
                var array: [Value] = []
                if take(93) { return .array(array) }
                while true {
                    array.append(try value(depth: depth + 1)); whitespace()
                    if take(93) { return .array(array) }
                    try require(44)
                }
            case 34: return .string(try string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            case 45, 48...57: return try number()
            default: throw CreatorGenerationFailure.malformedOutput
            }
        }
        mutating func literal(_ text: String) throws {
            for byte in text.utf8 { try require(byte) }
        }
        mutating func string() throws -> String {
            let start = index
            try require(34)
            while let byte = current {
                if index % 256 == 0 { try Task.checkCancellation() }
                index += 1
                if byte == 34 {
                    guard let text = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                    else { throw CreatorGenerationFailure.malformedOutput }
                    return text
                }
                guard byte >= 32 else { throw CreatorGenerationFailure.malformedOutput }
                if byte == 92 {
                    guard current != nil else { throw CreatorGenerationFailure.malformedOutput }
                    index += 1
                }
            }
            throw CreatorGenerationFailure.malformedOutput
        }
        mutating func number() throws -> Value {
            let start = index
            _ = take(45)
            if !take(48) {
                guard let byte = current, (49...57).contains(byte) else { throw CreatorGenerationFailure.malformedOutput }
                index += 1
                while let byte = current, (48...57).contains(byte) { index += 1 }
            }
            if take(46) {
                let first = index
                while let byte = current, (48...57).contains(byte) { index += 1 }
                guard index > first else { throw CreatorGenerationFailure.malformedOutput }
            }
            if take(101) || take(69) {
                if !take(43) { _ = take(45) }
                let first = index
                while let byte = current, (48...57).contains(byte) { index += 1 }
                guard index > first else { throw CreatorGenerationFailure.malformedOutput }
            }
            guard let number = Double(String(decoding: bytes[start..<index], as: UTF8.self)), number.isFinite
            else { throw CreatorGenerationFailure.malformedOutput }
            return .number(number)
        }
    }
}
