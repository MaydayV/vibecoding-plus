import XCTest
@testable import VibeCodingPlusNative

final class ClaudeTranscriptParserTests: XCTestCase {

    func testParsesUserAndAssistantMessages() {
        var snapshot = ClaudeTranscriptSnapshot()
        let userLine = #"{"sessionId":"s1","cwd":"/tmp/proj","message":{"role":"user","content":"fix tests"}}"#
        let assistantLine = #"{"sessionId":"s1","message":{"role":"assistant","content":[{"type":"text","text":"On it."},{"type":"tool_use","name":"Read"}]}}"#
        ClaudeTranscriptParser.apply(line: userLine, to: &snapshot)
        ClaudeTranscriptParser.apply(line: assistantLine, to: &snapshot)
        XCTAssertEqual(snapshot.sessionId, "s1")
        XCTAssertEqual(snapshot.cwd, "/tmp/proj")
        XCTAssertEqual(snapshot.lastUserPrompt, "fix tests")
        XCTAssertEqual(snapshot.lastAssistantMessage, "On it.")
        XCTAssertEqual(snapshot.currentTool, "Read")
    }
}
