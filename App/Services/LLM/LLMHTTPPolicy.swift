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
    static func unsupportedStream(_ data: Data) -> Bool {
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8),
              let object = try? LLMJSON.object(text), let error = object["error"] as? [String: Any] else { return false }
        let parameter = (error["param"] as? String ?? "").lowercased()
        let message = (error["message"] as? String ?? "").lowercased()
        return ["stream", "stream_options"].contains(parameter)
            || (parameter.isEmpty && (message.contains("streaming") || message.contains("stream"))
                && ["unsupported", "not supported", "does not support"].contains(where: message.contains))
    }
    static func unsupportedJSONMode(_ data: Data) -> Bool {
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8),
              let object = try? LLMJSON.object(text), let error = object["error"] as? [String: Any]
        else { return false }
        let parameter = (error["param"] as? String ?? "").lowercased()
        let message = (error["message"] as? String ?? "").lowercased()
        if !parameter.isEmpty && parameter != "response_format" && !parameter.hasPrefix("response_format.") { return false }
        return parameter == "response_format" || parameter.hasPrefix("response_format.")
            || ["response_format", "json_schema", "json_object", "structured output", "guided_json"].contains(where: message.contains)
    }
}
