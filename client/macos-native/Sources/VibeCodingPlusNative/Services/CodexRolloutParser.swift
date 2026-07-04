import Foundation

/// Incremental state extracted from `~/.codex/sessions/**/rollout-*.jsonl`.
struct CodexRolloutSnapshot: Equatable {
    var sessionId: String = ""
    var cwd: String = ""
    var lastUserPrompt: String = ""
    var lastAssistantMessage: String = ""
    var currentTool: String = ""
    var phase: String = "idle"
    var summary: String = ""
    var primaryUsedPct: Double?
    var secondaryUsedPct: Double?
    var planType: String = ""
}

/// Line-by-line reducer for Codex rollout transcripts (read-only observation).
enum CodexRolloutParser {

    private static let tailMaxBytes = 256 * 1024

    static func sessionsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    static func findLatestRolloutFile(threadId: String = "") -> URL? {
        let root = sessionsRoot()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [URL] = []
        for case let file as URL in enumerator {
            let name = file.lastPathComponent
            if name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") {
                files.append(file)
            }
        }
        files.sort { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate > rDate
        }
        if !threadId.isEmpty, let exact = files.first(where: { $0.path.contains(threadId) }) {
            return exact
        }
        return files.first
    }

    static func snapshot(from url: URL) -> CodexRolloutSnapshot? {
        let lines = tailLines(from: url)
        guard !lines.isEmpty else { return nil }
        var snapshot = CodexRolloutSnapshot()
        for line in lines {
            apply(line: line, to: &snapshot)
        }
        return snapshot
    }

    static func apply(line: String, to snapshot: inout CodexRolloutSnapshot) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let sid = object["sessionId"] as? String, !sid.isEmpty {
            snapshot.sessionId = sid
        }
        if let cwd = object["cwd"] as? String, !cwd.isEmpty {
            snapshot.cwd = cwd
        }

        switch object["type"] as? String {
        case "event_msg":
            applyEventMessage(object["payload"] as? [String: Any] ?? [:], to: &snapshot)
        case "response_item":
            applyResponseItem(object["payload"] as? [String: Any] ?? [:], to: &snapshot)
        default:
            break
        }
    }

    // MARK: - Private

    private static func tailLines(from url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let offset = max(0, size - tailMaxBytes)
        try? handle.seek(toOffset: UInt64(offset))
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        return lines
    }

    private static func applyEventMessage(_ payload: [String: Any], to snapshot: inout CodexRolloutSnapshot) {
        switch payload["type"] as? String {
        case "task_started", "turn_started":
            snapshot.phase = "running"
            snapshot.summary = snapshot.summary.isEmpty ? "Codex started a new turn." : snapshot.summary
        case "user_message":
            if let message = clipped(payload["message"] as? String), !message.isEmpty {
                snapshot.lastUserPrompt = message
                snapshot.phase = "running"
            }
        case "agent_message":
            if let message = clipped(payload["message"] as? String), !message.isEmpty {
                snapshot.lastAssistantMessage = message
                snapshot.summary = message
                snapshot.phase = "running"
            }
        case "task_complete", "turn_complete":
            snapshot.currentTool = ""
            snapshot.phase = "idle"
            if let message = payload["last_agent_message"] as? String, !message.isEmpty {
                snapshot.lastAssistantMessage = message
                snapshot.summary = message
            } else if snapshot.summary.isEmpty {
                snapshot.summary = "Codex completed the turn."
            }
        case "turn_aborted":
            snapshot.currentTool = ""
            snapshot.phase = "idle"
            snapshot.summary = "Codex turn was interrupted."
        case "token_count":
            if let rateLimits = payload["rate_limits"] as? [String: Any] {
                snapshot.primaryUsedPct = number(from: (rateLimits["primary"] as? [String: Any])?["used_percent"])
                snapshot.secondaryUsedPct = number(from: (rateLimits["secondary"] as? [String: Any])?["used_percent"])
                snapshot.planType = (rateLimits["plan_type"] as? String) ?? snapshot.planType
            }
        case "exec_command_begin":
            snapshot.currentTool = "exec_command"
            snapshot.phase = "running"
        case "patch_apply_begin", "patch_apply_updated":
            snapshot.currentTool = "apply_patch"
            snapshot.phase = "running"
        case "mcp_tool_call_begin":
            if let tool = payload["server"] as? String ?? payload["tool"] as? String {
                snapshot.currentTool = tool
                snapshot.phase = "running"
            }
        default:
            break
        }
    }

    private static func applyResponseItem(_ payload: [String: Any], to snapshot: inout CodexRolloutSnapshot) {
        switch payload["type"] as? String {
        case "message":
            let role = payload["role"] as? String ?? ""
            let parsed = parseMessageContent(payload["content"])
            guard !parsed.text.isEmpty || parsed.tool != nil else { return }
            if let tool = parsed.tool {
                snapshot.currentTool = tool
                snapshot.phase = "running"
            }
            if !parsed.text.isEmpty {
                if role == "user" {
                    snapshot.lastUserPrompt = parsed.text
                    snapshot.phase = "running"
                } else if role == "assistant" {
                    snapshot.lastAssistantMessage = parsed.text
                    snapshot.summary = parsed.text
                }
            }
        case "function_call", "custom_tool_call":
            snapshot.currentTool = (payload["name"] as? String) ?? snapshot.currentTool
            snapshot.phase = "running"
        default:
            break
        }
    }

    private struct ParsedMessageContent {
        var text: String = ""
        var tool: String?
    }

    private static func parseMessageContent(_ content: Any?) -> ParsedMessageContent {
        if let text = content as? String {
            return ParsedMessageContent(text: clipped(text) ?? "")
        }
        guard let blocks = content as? [[String: Any]] else { return ParsedMessageContent() }
        var parts: [String] = []
        var tool: String?
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    parts.append(text)
                }
            case "tool_use":
                tool = block["name"] as? String ?? tool
            default:
                break
            }
        }
        return ParsedMessageContent(
            text: parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            tool: tool
        )
    }

    private static func clipped(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let number as Double: number
        case let number as Int: Double(number)
        case let number as NSNumber: number.doubleValue
        default: nil
        }
    }
}
