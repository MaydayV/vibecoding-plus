import CryptoKit
import Foundation

/// HMAC-SHA256 signing and verification for LAN WebSocket authentication.
///
/// Mirrors the Node.js `lan-auth.mjs` protocol: shared-secret HMAC over
/// pipe-delimited message fields. Replay protection (server challenge nonce
/// + recent-nonce cache) is handled by `NativeServer`.
enum LANAuth {

    // MARK: - Signing

    /// Signs a hello message using server-issued challenge nonce (replay-safe).
    ///
    /// Message format: `"hello|{deviceId}|{boardType}|{serverNonce}|{deviceNonce}"`
    static func signHelloChallengePayload(
        secret: String,
        deviceId: String,
        boardType: String,
        serverNonce: String,
        deviceNonce: String
    ) -> String {
        let message = "hello|\(deviceId)|\(boardType)|\(serverNonce)|\(deviceNonce)"
        return hmacHex(secret: secret, message: message)
    }

    /// Signs a discovery reply message.
    ///
    /// Message format: `"discover_reply|{hostId}|{hostName}|{wsUrl}|{nonce}"`
    static func signDiscoveryReply(
        secret: String,
        hostId: String,
        hostName: String,
        wsUrl: String,
        nonce: String
    ) -> String {
        let message = "discover_reply|\(hostId)|\(hostName)|\(wsUrl)|\(nonce)"
        return hmacHex(secret: secret, message: message)
    }

    /// Signs a pairing token for NFC / discovery pairing.
    ///
    /// Message format: `"pair_token|{hostId}|{pairCode}|{nonce}"`
    static func signPairToken(
        secret: String,
        hostId: String,
        pairCode: String,
        nonce: String
    ) -> String {
        let message = "pair_token|\(hostId)|\(pairCode)|\(nonce)"
        return hmacHex(secret: secret, message: message)
    }

    // MARK: - Verification

    /// Returns `true` if `timestampMs` is within `windowSec` seconds of now.
    static func isFreshTimestamp(_ timestampMs: Int, windowSec: Int = 300) -> Bool {
        guard timestampMs > 0 else { return false }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        return abs(nowMs - timestampMs) <= windowSec * 1000
    }

    /// Timing-safe comparison of two hex-encoded signature strings.
    ///
    /// Decodes both strings to bytes and performs a constant-time comparison
    /// that does not short-circuit on mismatch.
    static func signaturesMatch(_ a: String, _ b: String) -> Bool {
        let lhs = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhs = b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !lhs.isEmpty, !rhs.isEmpty, lhs.count == rhs.count else {
            return false
        }

        guard let lhsData = Data(hexString: lhs),
              let rhsData = Data(hexString: rhs),
              lhsData.count == rhsData.count else {
            return false
        }

        return constantTimeCompare(lhsData, rhsData)
    }

    // MARK: - Private Helpers

    /// Computes HMAC-SHA256 and returns the result as a lowercase hex string.
    private static func hmacHex(secret: String, message: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let tag = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: key
        )
        return tag.map { String(format: "%02x", $0) }.joined()
    }

    /// Byte-by-byte comparison that does not short-circuit on mismatch.
    private static func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for (x, y) in zip(a, b) {
            result |= x ^ y
        }
        return result == 0
    }
}

// MARK: - Data Hex Helpers

private extension Data {
    /// Initialises `Data` from a lowercase hex string. Returns `nil` on invalid input.
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }

        var bytes = Data()
        bytes.reserveCapacity(hexString.count / 2)

        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = nextIndex
        }

        self = bytes
    }
}
