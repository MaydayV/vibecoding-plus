import Foundation

/// Snapshot of CLI quota remaining percentages (5h / 7d windows).
struct CLIRateLimitSnapshot {
    var primaryRemainingPct: Int?
    var secondaryRemainingPct: Int?
    var planType: String = ""
}

/// Reads Codex / Claude rate-limit data from local session files.
/// Port of `codex-rate-limits.mjs` and `claude-rate-limits.mjs`.
enum CLIRateLimits {

    private static let claudeCacheMaxAgeMs: Int64 = 60 * 60 * 1000

    static func readLatest(sendTarget: String, threadId: String = "") -> CLIRateLimitSnapshot? {
        if sendTarget == "claude_code" {
            return readLatestClaude()
        }
        return readLatestCodex(threadId: threadId)
    }

    // MARK: - Codex

    private static func codexSessionsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private static func collectJsonlFiles(at root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let file as URL in enumerator {
            if file.pathExtension == "jsonl" {
                files.append(file)
            }
        }
        files.sort { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate > rDate
        }
        return files
    }

    private static func findCodexSessionFile(threadId: String) -> URL? {
        let root = codexSessionsRoot()
        let files = collectJsonlFiles(at: root)
        guard !files.isEmpty else { return nil }
        if !threadId.isEmpty, let exact = files.first(where: { $0.path.contains(threadId) }) {
            return exact
        }
        return files.first
    }

    private static func parseCodexRateLimits(from content: String) -> CLIRateLimitSnapshot? {
        let lines = content.split(whereSeparator: \.isNewline).reversed()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "event_msg",
                  let payload = event["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let rateLimits = payload["rate_limits"] as? [String: Any] else {
                continue
            }

            let primaryUsed = (rateLimits["primary"] as? [String: Any])?["used_percent"] as? Double
            let secondaryUsed = (rateLimits["secondary"] as? [String: Any])?["used_percent"] as? Double
            let primaryRemaining = primaryUsed.map { max(0, Int((100 - $0).rounded())) }
            let secondaryRemaining = secondaryUsed.map { max(0, Int((100 - $0).rounded())) }
            let planType = (rateLimits["plan_type"] as? String) ?? ""

            return CLIRateLimitSnapshot(
                primaryRemainingPct: primaryRemaining,
                secondaryRemainingPct: secondaryRemaining,
                planType: planType
            )
        }
        return nil
    }

    private static func readLatestCodex(threadId: String) -> CLIRateLimitSnapshot? {
        guard let file = findCodexSessionFile(threadId: threadId),
              let content = try? String(contentsOf: file, encoding: .utf8) else {
            return nil
        }
        return parseCodexRateLimits(from: content)
    }

    // MARK: - Claude

    private static func claudeCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecoding-plus-claude-rate-limits.json")
    }

    private static func readLatestClaude() -> CLIRateLimitSnapshot? {
        let url = claudeCacheURL()
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let writtenAt = (json["writtenAt"] as? NSNumber)?.int64Value ?? 0
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if writtenAt > 0, nowMs - writtenAt > claudeCacheMaxAgeMs {
            return nil
        }

        let fiveHour = json["fiveHourUsedPct"] as? Double
        let sevenDay = json["sevenDayUsedPct"] as? Double
        if fiveHour == nil && sevenDay == nil { return nil }

        return CLIRateLimitSnapshot(
            primaryRemainingPct: fiveHour.map { max(0, Int((100 - $0).rounded())) },
            secondaryRemainingPct: sevenDay.map { max(0, Int((100 - $0).rounded())) },
            planType: "max"
        )
    }
}
