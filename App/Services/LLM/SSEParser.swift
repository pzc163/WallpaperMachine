import Foundation

/// Byte-oriented framing keeps UTF-8 sequences intact across arbitrary URLSession chunks.
struct SSEParser: Sendable {
    struct Event: Equatable, Sendable { let name: String; let data: String }
    let maximumBytes: Int
    let maximumEventBytes: Int
    private var total = 0
    private var eventBytes = 0
    private var line = Data()
    private var dataLines: [String] = []
    private var eventName: String?
    private var skipLF = false
    private var endedEventBytes: Int?
    private var firstLine = true

    init(maximumBytes: Int = 1024 * 1024, maximumEventBytes: Int = 64 * 1024) {
        self.maximumBytes = maximumBytes
        self.maximumEventBytes = maximumEventBytes
    }
    mutating func append(_ data: Data) throws -> [Event] {
        guard data.count <= maximumBytes - total else { throw LLMFailure.streamLimit }
        total += data.count
        var events: [Event] = []
        for byte in data {
            if skipLF {
                skipLF = false
                if byte == 10 {
                    // CR already ended the line, but the following LF still counts as a raw byte.
                    // Keep the ended frame's count across chunks, including its final blank line.
                    guard (endedEventBytes ?? eventBytes) < maximumEventBytes else { throw LLMFailure.streamLimit }
                    if endedEventBytes == nil { eventBytes += 1 }
                    endedEventBytes = nil
                    continue
                }
            }
            endedEventBytes = nil
            if byte == 10 || byte == 13 {
                if let event = try endLine() { events.append(event) }
                skipLF = byte == 13
            } else {
                guard line.count < maximumEventBytes - eventBytes else { throw LLMFailure.streamLimit }
                line.append(byte)
            }
        }
        return events
    }
    func finish() throws {
        guard line.isEmpty, dataLines.isEmpty, eventName == nil else { throw LLMFailure.truncated }
    }
    private mutating func endLine() throws -> Event? {
        guard var text = String(data: line, encoding: .utf8) else { throw LLMFailure.protocolViolation }
        eventBytes += line.count + 1
        line.removeAll(keepingCapacity: true)
        guard eventBytes <= maximumEventBytes else { throw LLMFailure.streamLimit }
        if firstLine { firstLine = false; if text.hasPrefix("\u{feff}") { text.removeFirst() } }
        if text.isEmpty {
            endedEventBytes = eventBytes
            defer { eventName = nil; dataLines.removeAll(keepingCapacity: true); eventBytes = 0 }
            return dataLines.isEmpty ? nil : Event(name: eventName ?? "message", data: dataLines.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }
        let pair = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(pair[0])
        var value = pair.count == 2 ? String(pair[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if field == "data" { dataLines.append(value) }
        if field == "event" { eventName = value.isEmpty ? "message" : value }
        return nil
    }
}
