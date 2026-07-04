import Foundation

// MARK: - ServerConfig

/// Server-side configuration loaded from a `.env` file.
/// Replaces the Node.js `config.mjs` for the native macOS client.
struct ServerConfig {

    // MARK: - Paths

    static let applicationSupportDirectoryName = "vibecoding-plus"
    static let configFileName = "config.env"
    static let todoListFileName = "todo-list.json"

    /// `~/Library/Application Support/vibecoding-plus`
    var configDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(
            "Library/Application Support/\(Self.applicationSupportDirectoryName)"
        )
    }

    /// Path to the todo-list JSON file inside the config directory.
    var todoListPath: String {
        (configDirectory as NSString).appendingPathComponent(Self.todoListFileName)
    }

    // MARK: - Core Settings

    var sendTarget: String = "text_injector"
    var sttProvider: String = ""
    var transcriptDeliveryMode: String = "confirm_on_device"
    var textInjectionMode: String = "type_and_enter"
    var port: Int = 8765
    var discoveryPort: Int = 8766
    var discoveryEnabled: Bool = true
    var bindHost: String = "0.0.0.0"
    var discoveryHostId: String = "VibeServer"
    var pairingCode: String = ""
    var lanSharedSecret: String = ""
    var lanAudioMaxBytes: Int = 10_000_000
    var cliTimeoutSec: Double = 300

    // MARK: - OpenAI / Whisper

    var openaiApiKey: String = ""
    var openaiModel: String = "whisper-1"
    var openaiTranscribeModel: String = ""
    var openaiBaseUrl: String = ""

    // MARK: - Volcengine

    var volcengineAppKey: String = ""
    var volcengineAccessKey: String = ""

    // MARK: - whisper.cpp

    var whisperCppModelPath: String = ""
    var whisperCppLanguage: String = "zh"
    var whisperCppThreads: Int = 4
    var whisperCppCommand: String = "whisper-cli"
    var whisperCppExtraArgs: String = ""

    // MARK: - Qwen ASR

    var qwenAsrApiKey: String = ""
    var qwenAsrModel: String = "Qwen/Qwen3-ASR-0.6B"
    var qwenAsrLanguage: String = "zh"
    var qwenAsrSampleRate: Int = 16000
    var qwenAsrRealtimeBaseUrl: String = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
    var qwenAsrPrompt: String = ""

    // MARK: - Claude Code

    var claudeCommand: String = "claude"
    var claudeCwd: String = ""
    var claudeMaxTurns: Int = 10
    var claudeDangerouslySkipPermissions: Bool = false

    // MARK: - Codex

    var codexCommand: String = "codex"
    var codexCwd: String = ""
    var codexSkipGitRepoCheck: Bool = false

    // MARK: - Reminders

    var remindersSyncEnabled: Bool = false
    var remindctlPath: String = "remindctl"
    var remindersListName: String = ""
    var remindersPollSec: Int = 15

    // MARK: - Display

    var displayTodoRefreshMs: Int = 2000
    var displayCodingRefreshMs: Int = 2000
    var displayStyle: String = "light"

    // MARK: - DeepSeek

    var deepSeekApiKey: String = ""
    var deepSeekModel: String = "deepseek-chat"
    var deepSeekBaseUrl: String = "https://api.deepseek.com"

    // MARK: - Debug / Test

    var mockTranscript: String = ""
    var dryRunTextInjection: Bool = false

    // MARK: - Resolved STT Provider

    /// The effective STT provider, inferring from available keys when `sttProvider` is empty.
    var resolvedSttProvider: String {
        if !sttProvider.isEmpty { return sttProvider }
        if !whisperCppModelPath.isEmpty { return "whisper_cpp" }
        if !qwenAsrApiKey.isEmpty { return "qwen_asr" }
        if !openaiApiKey.isEmpty { return "openai" }
        return "volcengine"
    }
}

// MARK: - Loading

extension ServerConfig {

    /// Load configuration from the default config path.
    static func load() -> ServerConfig {
        let defaultPath = defaultConfigPath()
        return load(from: defaultPath)
    }

    /// Load configuration from a specific `.env` file path.
    static func load(from path: String) -> ServerConfig {
        let values = parseEnvFile(at: path)
        return applyValues(values)
    }

    /// Potential config file locations, checked in priority order.
    static func configFileCandidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appSupport = (home as NSString).appendingPathComponent(
            "Library/Application Support/\(applicationSupportDirectoryName)/\(configFileName)"
        )
        let projectEnv = (projectRootPath() as NSString).appendingPathComponent(".env")
        let cwdEnv = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(".env")

        // Deduplicate while preserving order
        var seen = Set<String>()
        var candidates: [String] = []
        for path in [appSupport, projectEnv, cwdEnv] {
            let resolved = resolvePath(path)
            if !seen.contains(resolved) {
                seen.insert(resolved)
                candidates.append(resolved)
            }
        }
        return candidates
    }
}

// MARK: - Writing

extension ServerConfig {

    /// Merge new key-value pairs into the env file, preserving existing entries.
    /// Passing `nil` as a value removes the key.
    func writeValues(_ values: [String: String?]) {
        let path = Self.defaultConfigPath()
        var existing = Self.parseEnvFile(at: path)

        for (key, value) in values {
            if let v = value {
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    existing.removeValue(forKey: key)
                } else {
                    existing[key] = trimmed.replacingOccurrences(of: "\n", with: " ")
                }
            } else {
                existing.removeValue(forKey: key)
            }
        }

        let body = existing
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n") + "\n"

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        try? body.write(toFile: path, atomically: true, encoding: String.Encoding.utf8)
    }
}

// MARK: - Private Helpers

private extension ServerConfig {

    static func defaultConfigPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(
            "Library/Application Support/\(applicationSupportDirectoryName)/\(configFileName)"
        )
    }

    /// Find the project root by walking up from the executable looking for a marker file.
    static func projectRootPath() -> String {
        var current = Bundle.main.bundlePath
        let fm = FileManager.default
        for _ in 0..<10 {
            let marker = (current as NSString).appendingPathComponent("CLAUDE.md")
            let gitDir = (current as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: marker) || fm.fileExists(atPath: gitDir) {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return fm.currentDirectoryPath
    }

    /// Resolve `~` and make relative paths absolute.
    static func resolvePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return expanded
        }
        return (FileManager.default.currentDirectoryPath as NSString)
            .appendingPathComponent(expanded)
    }

    // MARK: Env File Parsing

    /// Parse a `.env` file into a dictionary. Comments (`#`) and empty lines are skipped.
    static func parseEnvFile(at path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let value = String(line[line.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }
        return values
    }

    // MARK: Value Application

    /// Build a `ServerConfig` populated from raw env values.
    static func applyValues(_ v: [String: String]) -> ServerConfig {
        var c = ServerConfig()

        // Core
        c.sendTarget = v["SEND_TARGET"] ?? c.sendTarget
        c.sttProvider = v["STT_PROVIDER"] ?? ""
        c.transcriptDeliveryMode = normalizeDeliveryMode(v["TRANSCRIPT_DELIVERY_MODE"])
        c.textInjectionMode = normalizeInjectionMode(v["TEXT_INJECTION_MODE"])
        c.port = positiveInt(v["LAN_VOICE_PORT"], fallback: c.port)
        c.discoveryPort = positiveInt(v["LAN_DISCOVERY_PORT"], fallback: c.discoveryPort)
        c.discoveryEnabled = v["LAN_DISCOVERY_ENABLED"] != "0"
        c.discoveryHostId = (v["LAN_DISCOVERY_HOST_ID"] ?? "").trimmingCharacters(in: .whitespaces)
        if c.discoveryHostId.isEmpty {
            c.discoveryHostId = "VibeServer"
        }
        c.lanSharedSecret = v["LAN_SHARED_SECRET"] ?? ""
        c.lanAudioMaxBytes = max(32768, positiveInt(v["LAN_AUDIO_MAX_BYTES"], fallback: c.lanAudioMaxBytes))
        c.cliTimeoutSec = positiveDouble(v["CLI_TIMEOUT_SEC"], fallback: c.cliTimeoutSec)

        // OpenAI
        c.openaiApiKey = v["OPENAI_API_KEY"] ?? ""
        c.openaiModel = v["OPENAI_TRANSCRIBE_MODEL"] ?? v["OPENAI_MODEL"] ?? c.openaiModel
        c.openaiTranscribeModel = v["OPENAI_TRANSCRIBE_MODEL"] ?? ""
        c.openaiBaseUrl = (v["OPENAI_BASE_URL"] ?? v["OPENAI_API_BASE"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Volcengine
        c.volcengineAppKey = v["VOLCENGINE_APP_KEY"] ?? ""
        c.volcengineAccessKey = v["VOLCENGINE_ACCESS_KEY"] ?? ""

        // whisper.cpp
        c.whisperCppModelPath = v["WHISPER_CPP_MODEL_PATH"] ?? ""
        c.whisperCppLanguage = v["WHISPER_CPP_LANGUAGE"] ?? c.whisperCppLanguage
        c.whisperCppThreads = positiveInt(v["WHISPER_CPP_THREADS"], fallback: c.whisperCppThreads)
        c.whisperCppCommand = v["WHISPER_CPP_COMMAND"] ?? c.whisperCppCommand
        c.whisperCppExtraArgs = v["WHISPER_CPP_EXTRA_ARGS"] ?? ""

        // Qwen ASR
        c.qwenAsrApiKey = v["QWEN_ASR_API_KEY"] ?? v["DASHSCOPE_API_KEY"] ?? ""
        c.qwenAsrModel = v["QWEN_ASR_MODEL"] ?? c.qwenAsrModel
        c.qwenAsrLanguage = v["QWEN_ASR_LANGUAGE"] ?? c.qwenAsrLanguage
        c.qwenAsrSampleRate = positiveInt(v["QWEN_ASR_SAMPLE_RATE"], fallback: c.qwenAsrSampleRate)
        c.qwenAsrRealtimeBaseUrl = v["QWEN_ASR_REALTIME_BASE_URL"] ?? c.qwenAsrRealtimeBaseUrl
        c.qwenAsrPrompt = v["QWEN_ASR_PROMPT"] ?? ""

        // Claude Code
        c.claudeCommand = v["CLAUDE_COMMAND"] ?? c.claudeCommand
        c.claudeCwd = v["CLAUDE_CWD"] ?? ""
        c.claudeMaxTurns = positiveInt(v["CLAUDE_MAX_TURNS"], fallback: c.claudeMaxTurns)
        c.claudeDangerouslySkipPermissions = isTruthy(v["CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS"])

        // Codex
        c.codexCommand = v["CODEX_COMMAND"] ?? c.codexCommand
        c.codexCwd = v["CODEX_CWD"] ?? ""
        c.codexSkipGitRepoCheck = isTruthy(v["CODEX_SKIP_GIT_REPO_CHECK"])

        // Reminders
        c.remindersSyncEnabled = isTruthy(v["REMINDERS_SYNC_ENABLED"])
        c.remindctlPath = v["REMINDCTL_PATH"] ?? c.remindctlPath
        c.remindersListName = v["REMINDERS_LIST"] ?? ""
        c.remindersPollSec = positiveInt(v["REMINDERS_POLL_SEC"], fallback: c.remindersPollSec)

        // Display
        c.displayTodoRefreshMs = clampRefreshMs(v["DISPLAY_TODO_REFRESH_MS"], fallback: c.displayTodoRefreshMs)
        c.displayCodingRefreshMs = clampRefreshMs(v["DISPLAY_CODING_REFRESH_MS"], fallback: c.displayCodingRefreshMs)
        c.displayStyle = normalizeDisplayStyle(v["DISPLAY_STYLE"])

        // DeepSeek
        c.deepSeekApiKey = v["DEEPSEEK_API_KEY"] ?? ""
        c.deepSeekModel = v["DEEPSEEK_MODEL"] ?? c.deepSeekModel
        c.deepSeekBaseUrl = v["DEEPSEEK_BASE_URL"] ?? c.deepSeekBaseUrl

        // Debug
        c.mockTranscript = v["MOCK_TRANSCRIPT"] ?? ""
        c.dryRunTextInjection = isTruthy(v["DRY_RUN_TEXT_INJECTION"])

        return c
    }

    // MARK: Normalizers

    static func normalizeDeliveryMode(_ raw: String?) -> String {
        guard let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return "confirm_on_device"
        }
        return v == "immediate" ? "immediate" : "confirm_on_device"
    }

    static func normalizeInjectionMode(_ raw: String?) -> String {
        guard let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return "type_and_enter"
        }
        return v == "type_only" ? "type_only" : "type_and_enter"
    }

    static func normalizeDisplayStyle(_ raw: String?) -> String {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return "light"
        }
        if ["dark", "black", "black_on_white", "black-on-white"].contains(text) {
            return "dark"
        }
        return "light"
    }

    // MARK: Type Helpers

    static func isTruthy(_ raw: String?) -> Bool {
        guard let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return v == "1" || v == "true" || v == "yes" || v == "on"
    }

    static func positiveInt(_ raw: String?, fallback: Int) -> Int {
        guard let s = raw, let n = Int(s), n > 0 else { return fallback }
        return n
    }

    static func positiveDouble(_ raw: String?, fallback: Double) -> Double {
        guard let s = raw, let n = Double(s), n > 0 else { return fallback }
        return n
    }

    static func clampRefreshMs(_ raw: String?, fallback: Int) -> Int {
        guard let s = raw, let n = Int(s) else { return fallback }
        return min(10_000, max(200, n))
    }
}
