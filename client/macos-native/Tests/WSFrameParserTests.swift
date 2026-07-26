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

    // MARK: - Masking (verifies the cursor-relative mask-key offset math)

    func testParsesMaskedTextFrame() {
        let parser = WSFrameParser()
        let payloadString = "hello masked"
        let payload = Data(payloadString.utf8)
        let maskKey: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        var maskedBytes = [UInt8](payload)
        for i in maskedBytes.indices {
            maskedBytes[i] ^= maskKey[i % 4]
        }

        var frame = Data()
        frame.append(0x81) // FIN=1, opcode=text
        frame.append(0x80 | UInt8(payload.count)) // masked bit set, 7-bit length
        frame.append(contentsOf: maskKey)
        frame.append(contentsOf: maskedBytes)

        let result = parser.feed(frame)
        XCTAssertNil(result.protocolError)
        XCTAssertEqual(result.messages.count, 1)
        if case .text(let text) = result.messages[0] {
            XCTAssertEqual(text, payloadString)
        } else {
            XCTFail("expected text frame")
        }
    }

    func testParsesMaskedFrameSplitAcrossFeeds() {
        // Same masked frame as above, but delivered in two pieces that split
        // inside the mask key itself — the trickiest offset to get right
        // after switching from absolute buffer indices to a read cursor.
        let parser = WSFrameParser()
        let payloadString = "masked+split"
        let payload = Data(payloadString.utf8)
        let maskKey: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD]
        var maskedBytes = [UInt8](payload)
        for i in maskedBytes.indices {
            maskedBytes[i] ^= maskKey[i % 4]
        }

        var frame = Data()
        frame.append(0x81)
        frame.append(0x80 | UInt8(payload.count))
        frame.append(contentsOf: maskKey)
        frame.append(contentsOf: maskedBytes)

        // Split after byte 3 (FIN/opcode + length byte + first 2 mask bytes).
        let splitAt = frame.startIndex + 3
        let firstResult = parser.feed(frame[frame.startIndex..<splitAt])
        XCTAssertNil(firstResult.protocolError)
        XCTAssertTrue(firstResult.messages.isEmpty)

        let secondResult = parser.feed(frame[splitAt...])
        XCTAssertNil(secondResult.protocolError)
        XCTAssertEqual(secondResult.messages.count, 1)
        if case .text(let text) = secondResult.messages[0] {
            XCTAssertEqual(text, payloadString)
        } else {
            XCTFail("expected text frame")
        }
    }

    // MARK: - Multiple frames per feed (exercises the compaction path)

    func testParsesMultipleFramesInSingleFeed() {
        let parser = WSFrameParser()
        let frame1 = WSEncoder.encode(opcode: .text, payload: Data("first".utf8))
        let frame2 = WSEncoder.encode(opcode: .text, payload: Data("second".utf8))
        let frame3 = WSEncoder.encode(opcode: .binary, payload: Data([0x01, 0x02, 0x03]))
        var combined = Data()
        combined.append(frame1)
        combined.append(frame2)
        combined.append(frame3)

        let result = parser.feed(combined)
        XCTAssertNil(result.protocolError)
        XCTAssertEqual(result.messages.count, 3)
        if case .text(let t1) = result.messages[0] { XCTAssertEqual(t1, "first") } else { XCTFail("expected text frame") }
        if case .text(let t2) = result.messages[1] { XCTAssertEqual(t2, "second") } else { XCTFail("expected text frame") }
        if case .binary(let b3) = result.messages[2] { XCTAssertEqual(b3, Data([0x01, 0x02, 0x03])) } else { XCTFail("expected binary frame") }
    }

    func testHandlesCompleteFrameFollowedByPartialNextFrame() {
        // One full frame plus the start of a second frame arrive together;
        // the second should stay buffered (needMoreData) until its
        // remaining bytes arrive in a later feed.
        let parser = WSFrameParser()
        let frame1 = WSEncoder.encode(opcode: .text, payload: Data("complete".utf8))
        let frame2 = WSEncoder.encode(opcode: .text, payload: Data("second-frame-payload".utf8))

        var combined = Data()
        combined.append(frame1)
        combined.append(frame2.prefix(3))

        let firstResult = parser.feed(combined)
        XCTAssertNil(firstResult.protocolError)
        XCTAssertEqual(firstResult.messages.count, 1)
        if case .text(let t1) = firstResult.messages[0] { XCTAssertEqual(t1, "complete") } else { XCTFail("expected text frame") }

        let remainder = frame2.suffix(from: frame2.startIndex + 3)
        let secondResult = parser.feed(Data(remainder))
        XCTAssertNil(secondResult.protocolError)
        XCTAssertEqual(secondResult.messages.count, 1)
        if case .text(let text) = secondResult.messages[0] {
            XCTAssertEqual(text, "second-frame-payload")
        } else {
            XCTFail("expected text frame")
        }
    }

    // MARK: - Fragmentation across many small feeds (half-frames)

    func testHandlesByteByByteFeedOfExtendedLengthFrame() {
        // 500-byte payload forces the 16-bit extended length (126) path.
        let parser = WSFrameParser()
        let payload = Data(repeating: 0x5A, count: 500)
        let frame = WSEncoder.encode(opcode: .binary, payload: payload)

        var messages: [WSFrameMessage] = []
        for byte in frame {
            let result = parser.feed(Data([byte]))
            XCTAssertNil(result.protocolError)
            messages.append(contentsOf: result.messages)
        }

        XCTAssertEqual(messages.count, 1)
        if case .binary(let data) = messages[0] {
            XCTAssertEqual(data, payload)
        } else {
            XCTFail("expected binary frame")
        }
    }

    func testHandlesLargeFrameViaExtended64BitLength() {
        // Payload > 0xFFFF forces the 64-bit extended length (127) path.
        let parser = WSFrameParser()
        let payload = Data(repeating: 0x7E, count: 70_000)
        let frame = WSEncoder.encode(opcode: .binary, payload: payload)

        // Split header/length-field from payload to also cross a feed boundary.
        let splitAt = frame.startIndex + 10 // 1 (fin/opcode) + 1 (len=127 marker) + 8 (64-bit length)
        let firstResult = parser.feed(frame[frame.startIndex..<splitAt])
        XCTAssertNil(firstResult.protocolError)
        XCTAssertTrue(firstResult.messages.isEmpty)

        let secondResult = parser.feed(frame[splitAt...])
        XCTAssertNil(secondResult.protocolError)
        XCTAssertEqual(secondResult.messages.count, 1)
        if case .binary(let data) = secondResult.messages[0] {
            XCTAssertEqual(data, payload)
        } else {
            XCTFail("expected binary frame")
        }
    }
}
