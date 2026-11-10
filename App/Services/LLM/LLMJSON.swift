import CoreFoundation
import Foundation

/// Parser failures are deliberately collapsed before any untrusted error text can escape.
enum LLMJSON {
    static func object(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data),
              let result = value as? [String: Any] else { throw LLMFailure.protocolViolation }
        return result
    }
    static func integer(_ value: Any?) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, (0...100_000_000).contains(number.doubleValue),
              number.doubleValue.rounded(.down) == number.doubleValue else { throw LLMFailure.protocolViolation }
        return number.intValue
    }
    static func dictionary(_ value: Any?) throws -> [String: Any]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let result = value as? [String: Any] else { throw LLMFailure.protocolViolation }
        return result
    }
    static func string(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let result = value as? String else { throw LLMFailure.protocolViolation }
        return result
    }
}
