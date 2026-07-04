import XCTest
@testable import VibeCodingPlusNative

final class LANAuthTests: XCTestCase {

    func testChallengeHelloSignatureRoundTrip() {
        let secret = "test-secret"
        let sig = LANAuth.signHelloChallengePayload(
            secret: secret,
            deviceId: "dev-1",
            boardType: "esp32s3",
            serverNonce: "srv-nonce",
            deviceNonce: "dev-nonce"
        )
        let expected = LANAuth.signHelloChallengePayload(
            secret: secret,
            deviceId: "dev-1",
            boardType: "esp32s3",
            serverNonce: "srv-nonce",
            deviceNonce: "dev-nonce"
        )
        XCTAssertTrue(LANAuth.signaturesMatch(sig, expected))
        XCTAssertFalse(LANAuth.signaturesMatch(sig, "00" + expected.dropFirst(2)))
    }

    func testFreshTimestampWindow() {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        XCTAssertTrue(LANAuth.isFreshTimestamp(nowMs, windowSec: 300))
        XCTAssertFalse(LANAuth.isFreshTimestamp(nowMs - 400_000, windowSec: 300))
    }
}
