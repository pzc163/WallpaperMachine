import XCTest
@testable import WallpaperMachine

final class SSEParserTests: XCTestCase {
    func testEveryUTF8SplitPreservesMultilineAndEventPairing() throws {
        let bytes = Data("\u{feff}: heartbeat\r\nevent: text\r\ndata: 中文🌙\r\ndata: second\r\n\r\ndata: next\n\n".utf8)
        for cut in 0...bytes.count {
            var parser = SSEParser()
            let events = try parser.append(bytes.prefix(cut)) + parser.append(bytes.suffix(bytes.count - cut))
            try parser.finish()
            XCTAssertEqual(events, [.init(name: "text", data: "中文🌙\nsecond"), .init(name: "message", data: "next")])
        }
    }
    func testBytewiseCRLFAndLoneCRDoNotDispatchTwice() throws {
        var parser = SSEParser(); var events: [SSEParser.Event] = []
        for byte in Data("id: 1\rdata: a\r\rdata:\r\n\r\n".utf8) { events += try parser.append(Data([byte])) }
        try parser.finish()
        XCTAssertEqual(events, [.init(name: "message", data: "a"), .init(name: "message", data: "")])
    }
    func testIncompleteAndInvalidUTF8FramesAreRejected() throws {
        for bytes in [Data("data: missing blank\n".utf8), Data("data: tail".utf8), Data("event: orphan\n".utf8)] {
            var parser = SSEParser(); _ = try parser.append(bytes)
            XCTAssertThrowsError(try parser.finish()) { XCTAssertEqual($0 as? LLMFailure, .truncated) }
        }
        var parser = SSEParser()
        XCTAssertThrowsError(try parser.append(Data([0xff, 10]))) { XCTAssertEqual($0 as? LLMFailure, .protocolViolation) }
    }
    func testTotalLineAndEventBudgetsIncludeDiscardedFieldsAndComments() throws {
        var total = SSEParser(maximumBytes: 8)
        _ = try total.append(Data(":a\n\n".utf8))
        _ = try total.append(Data(":b\n\n".utf8))
        XCTAssertThrowsError(try total.append(Data([10])))
        var line = SSEParser(maximumEventBytes: 8)
        XCTAssertThrowsError(try line.append(Data("data: 12345".utf8)))
        var event = SSEParser(maximumEventBytes: 18)
        XCTAssertThrowsError(try event.append(Data("data: a\ndata: b\ndata: c\n\n".utf8)))
        var ignored = SSEParser(maximumBytes: 8)
        XCTAssertThrowsError(try ignored.append(Data(": hidden thought\n\n".utf8)))
        let crlf = Data("data:x\r\n\r\n".utf8)
        for cut in 0...crlf.count {
            var over = SSEParser(maximumEventBytes: crlf.count - 1)
            XCTAssertThrowsError(try over.append(crlf.prefix(cut)) + over.append(crlf.suffix(crlf.count - cut)))
            var exact = SSEParser(maximumEventBytes: crlf.count)
            XCTAssertEqual(try exact.append(crlf.prefix(cut)) + exact.append(crlf.suffix(crlf.count - cut)), [.init(name: "message", data: "x")])
            try exact.finish()
        }
    }
}
