import XCTest
@testable import VibeCodingPlusNative

final class WSFrameParserTests: XCTestCase {

    func testParsesSingleTextFrame() {
        let parser = WSFrameParser()
        let payload = Data("{\"type\":\"hello\"}".utf8)
        let frame = WSEncoder.encode(opcode: .text, payload: payload)
        let result = parser.feed(frame)
        XCTAssertNil(result.protocolError)
        XCTAssertEqual(result.messages.count, 1)
        if case .text(let text) = result.messages[0] {
            XCTAssertEqual(text, "{\"type\":\"hello\"}")
        } else {
            XCTFail("expected text frame")
        }
    }

    func testRejectsFragmentedTextFrame() {
        let parser = WSFrameParser()
        var frame = Data()
        frame.append(0x01) // FIN=0, opcode=text
        frame.append(0x05)
        frame.append(contentsOf: "hello".utf8)
        let result = parser.feed(frame)
        XCTAssertNotNil(result.protocolError)
        XCTAssertTrue(result.messages.isEmpty)
    }

    func testRejectsOversizedPayload() {
        let parser = WSFrameParser(maxFramePayload: 8)
        let payload = Data(repeating: 0x41, count: 16)
        let frame = WSEncoder.encode(opcode: .text, payload: payload)
        let result = parser.feed(frame)
        XCTAssertEqual(result.protocolError, "frame_too_large")
    }
}
