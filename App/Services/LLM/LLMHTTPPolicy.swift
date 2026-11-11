import Foundation

enum LLMHTTPPolicy {
    static func failure(for response: HTTPURLResponse, now: Date = Date()) -> LLMFailure? {
        switch response.statusCode {
        case 200...299: return nil
        case 401, 403: return .unauthorized
        case 429: return .rateLimited(retryAfter: retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: now))
        case 500...599: return .server(response.statusCode)
        case 300...399: return .redirectRejected
        default: return .http(response.statusCode)
        }
    }
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value, value.utf8.count <= 128 else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
           let seconds = Double(trimmed), seconds.isFinite { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
    static func unsupportedJSONMode(_ data: Data) -> Bool {
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8),
              let object = try? LLMJSON.object(text), let error = object["error"] as? [String: Any],
              let parameter = error["param"] as? String,
              ["response_format", "response_format.type", "response_format.json_schema", "response_format.json_schema.schema"].contains(parameter),
              let code = error["code"] as? String
        else { return false }
        return ["unsupported_parameter", "unsupported_value", "unknown_parameter"].contains(code)
    }
}
