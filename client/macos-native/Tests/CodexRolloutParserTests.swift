import XCTest
@testable import VibeCodingPlusNative

final class CodexRolloutParserTests: XCTestCase {

    func testParsesTokenCountAndAgentMessage() {
        var snapshot = CodexRolloutSnapshot()
        let lines = [
            #"{"type":"event_msg","payload":{"type":"turn_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"Done."}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12},"secondary":{"used_percent":34},"plan_type":"plus"}}}"#
        ]
        for line in lines {
            CodexRolloutParser.apply(line: line, to: &snapshot)
        }
        XCTAssertEqual(snapshot.phase, "running")
        XCTAssertEqual(snapshot.lastAssistantMessage, "Done.")
        XCTAssertEqual(snapshot.primaryUsedPct, 12)
        XCTAssertEqual(snapshot.secondaryUsedPct, 34)
        XCTAssertEqual(snapshot.planType, "plus")
    }

    func testParsesResponseItemAssistantMessage() {
        var snapshot = CodexRolloutSnapshot()
        let line = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"Hello"}]}}"#
        CodexRolloutParser.apply(line: line, to: &snapshot)
        XCTAssertEqual(snapshot.lastAssistantMessage, "Hello")
    }
}
