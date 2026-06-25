import Foundation

// MARK: - Todo Command

/// A parsed voice command targeting the todo list.
struct TodoCommand {
    var action: String // "create", "toggle", "delete", "update", "list", "clear", "select_next", "select_prev"
    var text: String?
    var index: Int? // 1-based from user
    var id: String?
    var completed: Bool?
    var dueAt: String? // ISO 8601 date string
}

// MARK: - Pending Intent

/// An intent that is waiting for additional information from the user.
struct PendingIntent {
    var action: String
    var missing: String // "text", "index", "dueAt"
    var partialData: [String: String]
    var completed: Bool?
    var expiresAt: Date
}

// MARK: - Interpret Result

/// Result of interpreting a voice command.
struct InterpretResult {
    var ok: Bool
    var source: String // "rules" or "deepseek"
    var command: TodoCommand?
    var action: String // "command", "ask", "cancel", "parse"
    var message: String?
    var pendingIntent: PendingIntent?
}

// MARK: - Todo Assistant

actor TodoAssistant {

    // MARK: - Properties

    private var pendingIntents: [String: PendingIntent] = [:] // keyed by deviceId
    private let config: ServerConfig
    private let apiKey: String
    private let model: String
    private let baseUrl: String
    private let timeoutSeconds: TimeInterval

    // MARK: - Init

    init(config: ServerConfig) {
        self.config = config
        self.apiKey = config.deepSeekApiKey
        self.model = config.deepSeekModel.isEmpty ? "deepseek-chat" : config.deepSeekModel
        self.baseUrl = (config.deepSeekBaseUrl.isEmpty
            ? "https://api.deepseek.com"
            : config.deepSeekBaseUrl).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.timeoutSeconds = 10
    }

    // MARK: - Main Entry Point

    /// Interpret a voice command text, returning a structured result.
    func interpret(_ text: String, deviceId: String, snapshot: [[String: Any]]? = nil) async -> InterpretResult {
        let normalized = Self.collapseWhitespace(text)

        // 1. Resolve pending intent first.
        if let pending = pendingIntents[deviceId] {
            let resolved = Self.resolvePendingIntent(pending, text: normalized)
            if let resolved {
                if resolved.action == "command" || resolved.action == "cancel" {
                    pendingIntents.removeValue(forKey: deviceId)
                }
                return resolved
            }
        }

        // 2. Rule-based parsing (fast path).
        let localCommand = Self.parseTodoVoiceCommand(normalized)
        if localCommand.ok {
            // If create is missing dueAt, ask for it.
            if localCommand.command?.action == "create" && (localCommand.command?.dueAt ?? "").isEmpty {
                let intent = PendingIntent(
                    action: "create",
                    missing: "dueAt",
                    partialData: ["text": localCommand.command?.text ?? ""],
                    expiresAt: Date().addingTimeInterval(120)
                )
                pendingIntents[deviceId] = intent
                return InterpretResult(
                    ok: true, source: "rules", command: nil, action: "ask",
                    message: "提醒时间是什么？例如 明天早上9点",
                    pendingIntent: intent
                )
            }
            return localCommand
        }

        // 3. Explicit followup patterns (partial commands like "添加计划" without title).
        let explicitFollowup = Self.parseExplicitFollowup(normalized)
        if let explicitFollowup {
            if explicitFollowup.pendingIntent != nil {
                pendingIntents[deviceId] = explicitFollowup.pendingIntent
            }
            return explicitFollowup
        }

        // 4. LLM fallback.
        guard !apiKey.isEmpty else {
            return InterpretResult(
                ok: false, source: "rules", command: nil, action: "parse",
                message: localCommand.message ?? "请说：查看计划、添加计划 XXX、删除计划 2、修改计划 2 改成 XXX",
                pendingIntent: nil
            )
        }

        do {
            let llmResult = try await interpretWithLLM(normalized, snapshot: snapshot)
            if llmResult.action == "ask", let intent = llmResult.pendingIntent {
                pendingIntents[deviceId] = intent
            } else if llmResult.action == "command" || llmResult.action == "cancel" {
                pendingIntents.removeValue(forKey: deviceId)
            }
            return llmResult
        } catch {
            return InterpretResult(
                ok: false, source: "rules", command: nil, action: "parse",
                message: localCommand.message ?? "请说：查看计划、添加计划 XXX、删除计划 2、修改计划 2 改成 XXX",
                pendingIntent: nil
            )
        }
    }

    // MARK: - Pending Intent Management

    func clearPendingIntent(for deviceId: String) {
        pendingIntents.removeValue(forKey: deviceId)
    }

    // MARK: - Rule-Based Parsing

    /// Parse a complete voice command using regex rules.
    private static func parseTodoVoiceCommand(_ text: String) -> InterpretResult {
        let normalized = collapseWhitespace(text)
        guard !normalized.isEmpty else {
            return InterpretResult(
                ok: false, source: "rules", command: nil, action: "parse",
                message: "请说：查看计划、添加计划 XXX、删除计划 2、修改计划 2 改成 XXX",
                pendingIntent: nil
            )
        }

        // List
        if matches(normalized, #"^(查看|显示|列出)(计划|待办|todo)(列表)?$"#) {
            return commandResult(TodoCommand(action: "list"))
        }

        // Clear all
        if matches(normalized, #"^((删除|删掉)(全部|所有|全都)?(计划|待办|todo)(列表)?|(全部|全都|所有)(删除|删掉))$"#) {
            return commandResult(TodoCommand(action: "clear"))
        }

        // Select next / prev
        if matches(normalized, #"^(下一个|下一项|往下)"#) {
            return commandResult(TodoCommand(action: "select_next"))
        }
        if matches(normalized, #"^(上一个|上一项|往上)"#) {
            return commandResult(TodoCommand(action: "select_prev"))
        }

        // Create
        if let match = firstMatch(normalized, #"^(添加(一个)?|新增|增加|加一个)(计划|待办|todo)?\s*(.*)$"#) {
            let title = normalizeTitle(extractGroup(match, normalized, group: 4))
            guard !title.isEmpty else {
                return InterpretResult(
                    ok: false, source: "rules", command: nil, action: "parse",
                    message: "请说：添加计划 XXX", pendingIntent: nil
                )
            }
            let dueAt = parseDueAt(from: title)
            var cmd = TodoCommand(action: "create", text: title)
            if !dueAt.isEmpty {
                // Strip time hints from the title text
                cmd.text = stripTimeHints(title)
                cmd.dueAt = dueAt
            }
            return commandResult(cmd)
        }

        // Delete by index
        if let match = firstMatch(normalized, #"^(删除|删掉)(计划|待办|todo)\s*(第)?([0-9]+)(项)?$"#) {
            if let index = Int(extractGroup(match, normalized, group: 4)) {
                return commandResult(TodoCommand(action: "delete", index: index))
            }
        }
        if matches(normalized, #"^(删除|删掉)(计划|待办|todo)$"#) {
            return askResult("要删除第几个计划？", action: "delete", missing: "index")
        }

        // Delete by Chinese number
        if let match = firstMatch(normalized, #"^(删除|删掉)(第)?([一二两三四五六七八九十]+)(个)?(计划|待办|todo)?$"#) {
            if let index = parseChineseNumber(extractGroup(match, normalized, group: 3)) {
                return commandResult(TodoCommand(action: "delete", index: index))
            }
        }

        // Update
        if let match = firstMatch(normalized, #"^(修改|更新)(计划|待办|todo)\s*(第)?([0-9]+)(项)?\s*(改成|为|成)\s*(.*)$"#) {
            let title = normalizeTitle(extractGroup(match, normalized, group: 7))
            guard !title.isEmpty else {
                return InterpretResult(
                    ok: false, source: "rules", command: nil, action: "parse",
                    message: "请说：修改计划 2 改成 XXX", pendingIntent: nil
                )
            }
            if let index = Int(extractGroup(match, normalized, group: 4)) {
                return commandResult(TodoCommand(action: "update", text: title, index: index))
            }
        }
        if matches(normalized, #"^(修改|更新)(计划|待办|todo)\s*(第)?[0-9]+(项)?$"#) {
            return askResult("新的计划内容是什么？", action: "update", missing: "text")
        }
        if matches(normalized, #"^(修改|更新)(计划|待办|todo)?$"#) {
            return askResult("要修改第几个计划？", action: "update", missing: "index")
        }

        // Update with Chinese number
        if let match = firstMatch(normalized, #"^(修改|更新)(第)?([一二两三四五六七八九十]+)(个)?(计划|待办|todo)?\s*(改成|为|成)\s*(.*)$"#) {
            let title = normalizeTitle(extractGroup(match, normalized, group: 7))
            if let index = parseChineseNumber(extractGroup(match, normalized, group: 3)), !title.isEmpty {
                return commandResult(TodoCommand(action: "update", text: title, index: index))
            }
        }

        // Complete (toggle true)
        if let match = firstMatch(normalized, #"^(完成|搞定|勾选)(计划|待办|todo)\s*(第)?([0-9]+)(项)?$"#) {
            if let index = Int(extractGroup(match, normalized, group: 4)) {
                return commandResult(TodoCommand(action: "toggle", index: index, completed: true))
            }
        }
        if matches(normalized, #"^(完成|搞定|勾选)(计划|待办|todo)?$"#) {
            return askResult("要完成第几个计划？", action: "toggle", missing: "index", completed: true)
        }

        // Complete by Chinese number
        if let match = firstMatch(normalized, #"^(完成|搞定|勾选)(第)?([一二两三四五六七八九十]+)(个)?(计划|待办|todo)?$"#) {
            if let index = parseChineseNumber(extractGroup(match, normalized, group: 3)) {
                return commandResult(TodoCommand(action: "toggle", index: index, completed: true))
            }
        }

        // Uncomplete (toggle false)
        if let match = firstMatch(normalized, #"^(取消完成|取消勾选|恢复|还原)(计划|待办|todo)\s*(第)?([0-9]+)(项)?$"#) {
            if let index = Int(extractGroup(match, normalized, group: 4)) {
                return commandResult(TodoCommand(action: "toggle", index: index, completed: false))
            }
        }
        if matches(normalized, #"^(取消完成|取消勾选|恢复|还原)(计划|待办|todo)?$"#) {
            return askResult("要取消完成第几个计划？", action: "toggle", missing: "index", completed: false)
        }

        // Uncomplete by Chinese number
        if let match = firstMatch(normalized, #"^(取消完成|取消勾选|恢复|还原)(第)?([一二两三四五六七八九十]+)(个)?(计划|待办|todo)?$"#) {
            if let index = parseChineseNumber(extractGroup(match, normalized, group: 3)) {
                return commandResult(TodoCommand(action: "toggle", index: index, completed: false))
            }
        }

        return InterpretResult(
            ok: false, source: "rules", command: nil, action: "parse",
            message: "请说：查看计划、添加计划 XXX、删除计划 2、修改计划 2 改成 XXX",
            pendingIntent: nil
        )
    }

    /// Parse explicit followup patterns (partial commands that need more info).
    private static func parseExplicitFollowup(_ text: String) -> InterpretResult? {
        let normalized = collapseWhitespace(text)

        if matches(normalized, #"^(添加|新增)(计划|待办|todo)?$"#) {
            return askResult("计划内容是什么？", action: "create", missing: "text")
        }

        if matches(normalized, #"^(删除|删掉)(计划|待办|todo)?$"#) {
            return askResult("要删除第几个计划？", action: "delete", missing: "index")
        }

        // Update with index only (Chinese number)
        if let match = firstMatch(normalized, #"^(修改|更新)(计划|待办|todo)\s*(第)?([一二两三四五六七八九十]+)(项)?$"#) {
            if let index = parseChineseNumber(extractGroup(match, normalized, group: 4)) {
                var partial: [String: String] = [:]
                partial["index"] = String(index)
                return askResult("新的计划内容是什么？", action: "update", missing: "text", partialData: partial)
            }
        }

        if matches(normalized, #"^(修改|更新)(计划|待办|todo)?$"#) {
            return askResult("要修改第几个计划？", action: "update", missing: "index")
        }

        if matches(normalized, #"^(完成|勾选)(计划|待办|todo)?$"#) {
            return askResult("要完成第几个计划？", action: "toggle", missing: "index", completed: true)
        }

        if matches(normalized, #"^(取消完成|取消勾选)(计划|待办|todo)?$"#) {
            return askResult("要取消完成第几个计划？", action: "toggle", missing: "index", completed: false)
        }

        return nil
    }

    // MARK: - Pending Intent Resolution

    /// Try to resolve a pending intent with the user's followup text.
    private static func resolvePendingIntent(_ intent: PendingIntent, text: String) -> InterpretResult? {
        let normalized = collapseWhitespace(text)
        guard !normalized.isEmpty else { return nil }

        // Cancel words
        if matches(normalized, #"^(取消|算了|不用了|停止|退出)$"#) {
            return InterpretResult(
                ok: true, source: "rules", command: nil, action: "cancel",
                message: "已取消", pendingIntent: nil
            )
        }

        let action = intent.action

        if intent.missing == "text" {
            let parsedDueAt = action == "create" ? parseDueAt(from: normalized) : ""
            if action == "create" && parsedDueAt.isEmpty {
                // Need dueAt too
                var partial = intent.partialData
                partial["text"] = normalized
                let nextIntent = PendingIntent(
                    action: action, missing: "dueAt",
                    partialData: partial, completed: intent.completed,
                    expiresAt: Date().addingTimeInterval(120)
                )
                return askResult("提醒时间是什么？例如 明天早上9点", pendingIntent: nextIntent)
            }
            var cmd = TodoCommand(
                action: action,
                text: normalized,
                index: Int(intent.partialData["index"] ?? ""),
                completed: intent.completed
            )
            if !parsedDueAt.isEmpty {
                cmd.text = stripTimeHints(normalized)
                cmd.dueAt = parsedDueAt
            }
            return InterpretResult(
                ok: true, source: "rules", command: cmd, action: "command",
                message: nil, pendingIntent: nil
            )
        }

        if intent.missing == "dueAt" {
            let parsedDueAt = parseDueAt(from: normalized)
            if parsedDueAt.isEmpty {
                return askResult("请说提醒时间，例如 明天晚上8点", pendingIntent: intent)
            }
            let cmd = TodoCommand(
                action: action,
                text: intent.partialData["text"],
                index: Int(intent.partialData["index"] ?? ""),
                completed: intent.completed,
                dueAt: parsedDueAt
            )
            return InterpretResult(
                ok: true, source: "rules", command: cmd, action: "command",
                message: nil, pendingIntent: nil
            )
        }

        if intent.missing == "index" {
            let index = extractIndex(normalized)
            guard let index, index > 0 else {
                return askResult("请说计划序号，比如：第 2 个", pendingIntent: intent)
            }
            if action == "update" {
                var partial = intent.partialData
                partial["index"] = String(index)
                let nextIntent = PendingIntent(
                    action: action, missing: "text",
                    partialData: partial, completed: intent.completed,
                    expiresAt: Date().addingTimeInterval(120)
                )
                return askResult("新的计划内容是什么？", pendingIntent: nextIntent)
            }
            return InterpretResult(
                ok: true, source: "rules",
                command: TodoCommand(action: action, index: index, completed: intent.completed),
                action: "command", message: nil, pendingIntent: nil
            )
        }

        return nil
    }

    // MARK: - LLM Fallback

    /// Use DeepSeek API to interpret ambiguous commands.
    private func interpretWithLLM(_ text: String, snapshot: [[String: Any]]?) async throws -> InterpretResult {
        let url = URL(string: "\(baseUrl)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeoutSeconds

        let systemPrompt = Self.buildSystemPrompt()
        let userPrompt = Self.buildUserPrompt(text, snapshot: snapshot)

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "TodoAssistant", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "todo_intent_http_\(code)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "TodoAssistant", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "todo_intent_empty_response"])
        }

        let payload = try Self.extractJsonPayload(content)
        return Self.normalizeLlmCommand(payload)
    }

    // MARK: - LLM Prompt Builders

    private static func buildSystemPrompt() -> String {
        """
        你是一个 Todo List 语义解析器，只输出 JSON，不要输出 Markdown。
        你只负责把中文口语解析成结构化命令，不要执行命令。
        支持的 action 只有 list, create, update, delete, clear, toggle。
        如果用户只是查看待办，输出 {"type":"command","action":"list"}。
        如果用户想新增待办，输出 {"type":"command","action":"create","text":"待办内容","dueAt":"ISO时间"}。
        如果用户想删除全部或清空待办，输出 {"type":"command","action":"clear"}。
        如果用户想修改、删除、完成或取消完成某条待办，必须给出 1-based index；没有序号就输出 ask。
        create 必须包含 dueAt；如果缺少时间，输出 ask，pending.missing=dueAt，并带上 pending.text。
        如果用户只说添加/新增但没有内容，输出 {"type":"ask","question":"计划内容是什么？","pending":{"action":"create","missing":"text"}}。
        如果缺少序号，pending.missing 必须是 index；如果缺少新内容，pending.missing 必须是 text。
        toggle 的 completed 为 true 表示完成，false 表示取消完成。
        现在只做待办，不做提醒、日历、时间调度；时间仅作为待办 dueAt 字段。
        输出 JSON 形状只能是 command、ask 或 unsupported。
        """
    }

    private static func buildUserPrompt(_ text: String, snapshot: [[String: Any]]?) -> String {
        let items = snapshot ?? []
        let itemLines: String
        if items.isEmpty {
            itemLines = "空"
        } else {
            itemLines = items.enumerated().map { index, item in
                let title = item["title"] as? String ?? ""
                let completed = item["completed"] as? Bool ?? false
                let dueAt = item["dueAt"] as? String ?? ""
                let checkmark = completed ? "x" : " "
                let dueSuffix = dueAt.isEmpty ? "" : " (\(formatTodoDueShort(dueAt)))"
                return "\(index + 1). [\(checkmark)] \(title)\(dueSuffix)"
            }.joined(separator: "\n")
        }

        return """
        用户原话：\(collapseWhitespace(text))
        当前选中序号：无
        当前待办列表：
        \(itemLines)
        """
    }

    // MARK: - LLM Response Normalization

    private static func extractJsonPayload(_ content: String) throws -> [String: Any] {
        var text = collapseWhitespace(content)
        // Strip markdown code fences
        if text.hasPrefix("```") {
            if let endFence = text.range(of: "\n```") {
                text = String(text[endFence.upperBound...])
            } else {
                text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        // Try to extract JSON from surrounding text
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"),
           end > start {
            let jsonStr = String(text[start...end])
            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }

        throw NSError(domain: "TodoAssistant", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "todo_intent_invalid_json"])
    }

    private static func normalizeLlmCommand(_ payload: [String: Any]) -> InterpretResult {
        let type = normalizeWhitespace(payload["type"]).lowercased()

        if type == "unsupported" {
            let msg = normalizeWhitespace(payload["message"])
            return InterpretResult(
                ok: false, source: "deepseek", command: nil, action: "parse",
                message: msg.isEmpty ? "现在只支持待办增删改查" : msg, pendingIntent: nil
            )
        }

        if type == "ask" {
            let question = normalizeWhitespace(payload["question"])
            let pending = normalizeLlmPending(payload["pending"] as? [String: Any])
            return InterpretResult(
                ok: true, source: "deepseek", command: nil, action: "ask",
                message: question.isEmpty ? "请补充待办信息" : question,
                pendingIntent: pending
            )
        }

        guard type == "command" || type.isEmpty else {
            return InterpretResult(
                ok: false, source: "deepseek", command: nil, action: "parse",
                message: "没有识别出待办命令", pendingIntent: nil
            )
        }

        let action = normalizeActionAlias(normalizeWhitespace(payload["action"]))
        guard isValidAction(action) else {
            return InterpretResult(
                ok: false, source: "deepseek", command: nil, action: "parse",
                message: "不支持这个待办操作", pendingIntent: nil
            )
        }

        if action == "list" || action == "clear" {
            return InterpretResult(
                ok: true, source: "deepseek",
                command: TodoCommand(action: action), action: "command",
                message: nil, pendingIntent: nil
            )
        }

        let text = normalizeTextFields(payload)
        let index = normalizeIndexFields(payload)
        let dueAt = normalizeDueAtFields(payload)
        let completed = inferCompletedFromPayload(payload)

        if action == "create" {
            if text.isEmpty {
                return askResult("计划内容是什么？", action: "create", missing: "text")
            }
            if dueAt.isEmpty {
                var partial: [String: String] = [:]
                partial["text"] = text
                return askResult("提醒时间是什么？例如 明天早上9点",
                                 action: "create", missing: "dueAt", partialData: partial)
            }
            return InterpretResult(
                ok: true, source: "deepseek",
                command: TodoCommand(action: "create", text: text, dueAt: dueAt),
                action: "command", message: nil, pendingIntent: nil
            )
        }

        if index == nil {
            let question = action == "delete" ? "要删除第几个计划？"
                : action == "toggle" ? "要操作第几个计划？"
                : "要修改第几个计划？"
            return askResult(question, action: action, missing: "index", completed: completed)
        }

        if action == "update" && text.isEmpty {
            return askResult("新的计划内容是什么？", action: "update", missing: "text")
        }

        return InterpretResult(
            ok: true, source: "deepseek",
            command: TodoCommand(action: action, text: text.isEmpty ? nil : text,
                                 index: index, completed: completed),
            action: "command", message: nil, pendingIntent: nil
        )
    }

    private static func normalizeLlmPending(_ pending: [String: Any]?) -> PendingIntent? {
        guard let pending else { return nil }
        let action = normalizeActionAlias(normalizeWhitespace(pending["action"]))
        let missing = normalizeWhitespace(pending["missing"]).lowercased()
        guard isValidAction(action),
              ["text", "index", "dueAt"].contains(missing) else { return nil }

        var partial: [String: String] = [:]
        if let index = normalizeIndexFields(pending) {
            partial["index"] = String(index)
        }
        let text = normalizeTextFields(pending)
        if !text.isEmpty { partial["text"] = text }
        let dueAt = normalizeDueAtFields(pending)
        if !dueAt.isEmpty { partial["dueAt"] = dueAt }

        let completed = inferCompletedFromPayload(pending)

        return PendingIntent(
            action: action, missing: missing, partialData: partial,
            completed: completed, expiresAt: Date().addingTimeInterval(120)
        )
    }

    // MARK: - Normalization Helpers

    private static func normalizeWhitespace(_ value: Any?) -> String {
        collapseWhitespace(value.map { "\($0)" } ?? "")
    }

    private static func normalizeTextFields(_ payload: [String: Any]) -> String {
        for key in ["text", "title", "task", "todo", "content", "value"] {
            if let val = payload[key] as? String, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return collapseWhitespace(val)
            }
        }
        return ""
    }

    private static func normalizeIndexFields(_ payload: [String: Any]) -> Int? {
        for key in ["index", "id", "item", "item_index", "itemIndex"] {
            if let val = payload[key], let idx = normalizeIndex(val) {
                return idx
            }
        }
        return nil
    }

    private static func normalizeIndex(_ value: Any?) -> Int? {
        if let n = value as? Int, n > 0 { return n }
        if let s = value as? String { return extractIndex(s) }
        return nil
    }

    private static func normalizeDueAtFields(_ payload: [String: Any]) -> String {
        for key in ["dueAt", "due_at", "time", "datetime", "dateTime"] {
            if let val = payload[key] as? String, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return normalizeIsoOrChineseDate(val)
            }
        }
        // Try to parse dueAt from the text field itself
        let text = normalizeTextFields(payload)
        return parseDueAt(from: text)
    }

    private static func inferCompletedFromPayload(_ payload: [String: Any]) -> Bool? {
        for key in ["completed", "done", "checked", "is_done", "isDone"] {
            if let val = payload[key] as? Bool { return val }
        }
        if let actionText = payload["action"] as? String {
            let lower = actionText.lowercased()
            if lower.contains("uncheck") || lower.contains("取消完成") || lower.contains("未完成") {
                return false
            }
            if lower.contains("check") || lower.contains("complete") || lower.contains("完成") || lower.contains("勾选") {
                return true
            }
        }
        return nil
    }

    private static func normalizeActionAlias(_ value: String) -> String {
        let lower = value.lowercased()
        let aliasMap: [String: String] = [
            "add": "create", "insert": "create", "new": "create",
            "新增": "create", "添加": "create", "create": "create",
            "list": "list", "show": "list", "查看": "list", "query": "list",
            "update": "update", "edit": "update", "modify": "update", "修改": "update",
            "delete": "delete", "remove": "delete", "删": "delete",
            "clear": "clear", "reset": "clear", "清空": "clear",
            "toggle": "toggle", "check": "toggle", "uncheck": "toggle",
            "complete": "toggle", "completed": "toggle",
            "完成": "toggle", "取消完成": "toggle"
        ]
        return aliasMap[lower] ?? lower
    }

    private static func isValidAction(_ action: String) -> Bool {
        ["list", "create", "update", "delete", "clear", "toggle"].contains(action)
    }

    // MARK: - Chinese Number Parsing

    private static let chineseDigits: [Character: Int] = [
        "零": 0, "一": 1, "二": 2, "两": 2, "三": 3,
        "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
    ]

    /// Parse a Chinese number string (e.g. "三", "十二", "二十三") into an Int.
    static func parseChineseNumber(_ value: String) -> Int? {
        let cleaned = value
            .replacingOccurrences(of: "[第个项号计划待办\\s]", with: "", options: .regularExpression)
        guard !cleaned.isEmpty else { return nil }

        // Arabic digits
        if let n = Int(cleaned), n > 0 { return n }

        // Single digit
        if cleaned.count == 1, let ch = cleaned.first, let digit = chineseDigits[ch] {
            return digit
        }

        // 十
        if cleaned == "十" { return 10 }

        // 十X (11-19)
        if cleaned.hasPrefix("十"), cleaned.count == 2 {
            let second = cleaned[cleaned.index(after: cleaned.startIndex)]
            if let digit = chineseDigits[second] {
                return 10 + digit
            }
        }

        // X十 (20, 30, ...)
        if cleaned.count == 2, cleaned.hasSuffix("十") {
            let first = cleaned.first!
            if let digit = chineseDigits[first] {
                return digit * 10
            }
        }

        // X十Y (21-99)
        if cleaned.count == 3, cleaned[cleaned.index(cleaned.startIndex, offsetBy: 1)] == "十" {
            let first = cleaned.first!
            let third = cleaned[cleaned.index(cleaned.startIndex, offsetBy: 2)]
            if let tens = chineseDigits[first], let ones = chineseDigits[third] {
                return tens * 10 + ones
            }
        }

        return nil
    }

    /// Extract a 1-based index from text (arabic or Chinese).
    private static func extractIndex(_ text: String) -> Int? {
        // Try arabic digits first
        if let match = firstMatch(text, #"([0-9]+)"#) {
            let numStr = extractGroup(match, text, group: 1)
            if let n = Int(numStr), n > 0 { return n }
        }

        // Try Chinese number
        if let match = firstMatch(text, #"([一二两三四五六七八九十]+)"#) {
            let cnStr = extractGroup(match, text, group: 1)
            return parseChineseNumber(cnStr)
        }

        return nil
    }

    // MARK: - Due Date Parsing

    /// Parse natural Chinese time expressions into ISO 8601 strings.
    /// Handles: "明天早上9点", "后天下午3点半", "今晚8点", etc.
    static func parseDueAt(from text: String) -> String {
        let normalized = collapseWhitespace(text)

        let minutePattern = #"(\d{1,2})[:：点](\d{1,2})"#
        let hourOnlyPattern = #"(\d{1,2})点(整)?"#

        let hasMinute = firstMatch(normalized, minutePattern)
        let hasHour = hasMinute == nil ? firstMatch(normalized, hourOnlyPattern) : nil

        guard hasMinute != nil || hasHour != nil else { return "" }

        let amHint = normalized.range(of: #"上午|早上|清晨"#, options: .regularExpression) != nil
        let pmHint = normalized.range(of: #"下午|今晚|晚上|夜里|傍晚"#, options: .regularExpression) != nil
        let tomorrowHint = normalized.contains("明天")
        let dayAfterHint = normalized.contains("后天")

        var hour = 0
        var minute = 0

        if let match = hasMinute {
            hour = Int(extractGroup(match, normalized, group: 1)) ?? 0
            minute = Int(extractGroup(match, normalized, group: 2)) ?? 0
        } else if let match = hasHour {
            hour = Int(extractGroup(match, normalized, group: 1)) ?? 0
            minute = 0
        }

        guard hour >= 0, hour <= 23, minute >= 0, minute <= 59 else { return "" }

        if pmHint && hour >= 1 && hour <= 11 { hour += 12 }
        if amHint && hour == 12 { hour = 0 }

        let calendar = Calendar.current
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard var due = calendar.date(from: components) else { return "" }

        if tomorrowHint {
            due = calendar.date(byAdding: .day, value: 1, to: due) ?? due
        } else if dayAfterHint {
            due = calendar.date(byAdding: .day, value: 2, to: due) ?? due
        } else if due.timeIntervalSince(now) < -60 {
            // Time already passed today, roll to tomorrow
            due = calendar.date(byAdding: .day, value: 1, to: due) ?? due
        }

        return Self.iso8601String(from: due)
    }

    /// Try to parse a value as ISO 8601 or Chinese natural date.
    private static func normalizeIsoOrChineseDate(_ value: String) -> String {
        let trimmed = collapseWhitespace(value)
        if trimmed.isEmpty { return "" }

        // Try ISO 8601 first
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) {
            return iso8601String(from: date)
        }
        // Without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: trimmed) {
            return iso8601String(from: date)
        }

        // Fall back to Chinese natural language
        return parseDueAt(from: trimmed)
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Strip Chinese time hints from a todo title (e.g. "喝水 明天早上9点" -> "喝水").
    private static func stripTimeHints(_ text: String) -> String {
        var result = text
        let patterns = [
            #"明天|后天|今晚|今天"#,
            #"上午|下午|早上|晚上|清晨|夜里|傍晚"#,
            #"\d{1,2}[:：]\d{1,2}"#,
            #"\d{1,2}点(整|半)?"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return collapseWhitespace(result)
    }

    // MARK: - Formatting

    /// Format a todo due date into a short display string.
    static func formatTodoDueShort(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString) else {
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: isoString) else { return "" }
            return formatShortDate(date)
        }
        return formatShortDate(date)
    }

    private static func formatShortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let hour = String(format: "%02d", calendar.component(.hour, from: date))
        let minute = String(format: "%02d", calendar.component(.minute, from: date))

        let isToday = calendar.isDate(date, inSameDayAs: now)
        if isToday {
            return "\(hour):\(minute)"
        }
        let month = String(format: "%02d", calendar.component(.month, from: date))
        let day = String(format: "%02d", calendar.component(.day, from: date))
        return "\(month)/\(day) \(hour):\(minute)"
    }

    // MARK: - String Helpers

    private static func collapseWhitespace(_ value: String) -> String {
        value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeTitle(_ value: String) -> String {
        collapseWhitespace(value)
    }

    // MARK: - Regex Helpers

    /// Check if a string fully matches a regex pattern (anchored).
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        let match = regex.firstMatch(in: text, options: [], range: range)
        guard let match else { return false }
        // Ensure the match covers the entire string for anchored patterns
        return match.range.length == text.utf16.count
    }

    /// Find the first match of a regex in text.
    private static func firstMatch(_ text: String, _ pattern: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range)
    }

    /// Extract a capture group from a match.
    private static func extractGroup(_ match: NSTextCheckingResult, _ text: String, group: Int) -> String {
        guard group < match.numberOfRanges else { return "" }
        let nsRange = match.range(at: group)
        guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { return "" }
        return String(text[range])
    }

    // MARK: - Result Builders

    private static func commandResult(_ command: TodoCommand) -> InterpretResult {
        InterpretResult(
            ok: true, source: "rules", command: command, action: "command",
            message: nil, pendingIntent: nil
        )
    }

    private static func askResult(
        _ message: String, action: String, missing: String,
        partialData: [String: String] = [:], completed: Bool? = nil
    ) -> InterpretResult {
        let intent = PendingIntent(
            action: action, missing: missing, partialData: partialData,
            completed: completed, expiresAt: Date().addingTimeInterval(120)
        )
        return InterpretResult(
            ok: true, source: "rules", command: nil, action: "ask",
            message: message, pendingIntent: intent
        )
    }

    private static func askResult(_ message: String, pendingIntent: PendingIntent?) -> InterpretResult {
        InterpretResult(
            ok: true, source: "rules", command: nil, action: "ask",
            message: message, pendingIntent: pendingIntent
        )
    }
}
