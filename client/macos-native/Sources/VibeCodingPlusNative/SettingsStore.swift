import Foundation

struct SettingsStore {
    let configDirectory: URL

    init() {
        configDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/vibecoding-plus", isDirectory: true)
    }

    var configURL: URL { configDirectory.appendingPathComponent("config.env") }
    var desktopSettingsURL: URL { configDirectory.appendingPathComponent("desktop-settings.json") }

    func loadConfig() -> AppConfig {
        let values = readEnv()
        var config = AppConfig()
        config.sendTarget = SendTarget(rawValue: values["SEND_TARGET"] ?? "") ?? .textInjector
        config.sttProvider = STTProvider(rawValue: values["STT_PROVIDER"] ?? "") ?? inferredProvider(values)
        config.transcriptDeliveryMode = values["TRANSCRIPT_DELIVERY_MODE"] ?? config.transcriptDeliveryMode
        config.textInjectionMode = values["TEXT_INJECTION_MODE"] ?? config.textInjectionMode
        config.openaiApiKey = values["OPENAI_API_KEY"] ?? ""
        config.openaiModel = values["OPENAI_TRANSCRIBE_MODEL"] ?? config.openaiModel
        config.volcengineAppKey = values["VOLCENGINE_APP_KEY"] ?? ""
        config.volcengineAccessKey = values["VOLCENGINE_ACCESS_KEY"] ?? ""
        config.whisperCppModelPath = values["WHISPER_CPP_MODEL_PATH"] ?? ""
        config.whisperCppLanguage = values["WHISPER_CPP_LANGUAGE"] ?? config.whisperCppLanguage
        config.whisperCppThreads = values["WHISPER_CPP_THREADS"] ?? config.whisperCppThreads
        config.whisperCppCommand = values["WHISPER_CPP_COMMAND"] ?? config.whisperCppCommand
        config.whisperCppExtraArgs = values["WHISPER_CPP_EXTRA_ARGS"] ?? ""
        config.qwenAsrApiKey = values["QWEN_ASR_API_KEY"] ?? ""
        config.qwenAsrModel = values["QWEN_ASR_MODEL"] ?? config.qwenAsrModel
        config.qwenAsrLanguage = values["QWEN_ASR_LANGUAGE"] ?? config.qwenAsrLanguage
        config.qwenAsrPrompt = values["QWEN_ASR_PROMPT"] ?? ""
        config.qwenAsrSampleRate = values["QWEN_ASR_SAMPLE_RATE"] ?? config.qwenAsrSampleRate
        config.qwenAsrRealtimeBaseUrl = values["QWEN_ASR_REALTIME_BASE_URL"] ?? config.qwenAsrRealtimeBaseUrl
        config.lanSharedSecret = values["LAN_SHARED_SECRET"] ?? ""
        config.codexCwd = values["CODEX_CWD"] ?? ""
        config.claudeCwd = values["CLAUDE_CWD"] ?? ""
        config.codexSkipGitRepoCheck = values["CODEX_SKIP_GIT_REPO_CHECK"] == "1"
        config.claudeDangerouslySkipPermissions = values["CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS"] == "1"
        config.port = Int(values["PORT"] ?? "") ?? 8765
        return config
    }

    func saveConfig(_ config: AppConfig) throws {
        var values = readEnv()
        values["SEND_TARGET"] = config.sendTarget.rawValue
        values["STT_PROVIDER"] = config.sttProvider.rawValue
        values["TRANSCRIPT_DELIVERY_MODE"] = config.transcriptDeliveryMode
        values["TEXT_INJECTION_MODE"] = config.textInjectionMode
        values["OPENAI_API_KEY"] = nilIfEmpty(config.openaiApiKey)
        values["OPENAI_TRANSCRIBE_MODEL"] = nilIfEmpty(config.openaiModel)
        values["VOLCENGINE_APP_KEY"] = nilIfEmpty(config.volcengineAppKey)
        values["VOLCENGINE_ACCESS_KEY"] = nilIfEmpty(config.volcengineAccessKey)
        values["WHISPER_CPP_MODEL_PATH"] = nilIfEmpty(config.whisperCppModelPath)
        values["WHISPER_CPP_LANGUAGE"] = nilIfEmpty(config.whisperCppLanguage)
        values["WHISPER_CPP_THREADS"] = nilIfEmpty(config.whisperCppThreads)
        values["WHISPER_CPP_COMMAND"] = nilIfEmpty(config.whisperCppCommand)
        values["WHISPER_CPP_EXTRA_ARGS"] = nilIfEmpty(config.whisperCppExtraArgs)
        values["QWEN_ASR_API_KEY"] = nilIfEmpty(config.qwenAsrApiKey)
        values["QWEN_ASR_MODEL"] = nilIfEmpty(config.qwenAsrModel)
        values["QWEN_ASR_LANGUAGE"] = nilIfEmpty(config.qwenAsrLanguage)
        values["QWEN_ASR_PROMPT"] = nilIfEmpty(config.qwenAsrPrompt)
        values["QWEN_ASR_SAMPLE_RATE"] = nilIfEmpty(config.qwenAsrSampleRate)
        values["QWEN_ASR_REALTIME_BASE_URL"] = nilIfEmpty(config.qwenAsrRealtimeBaseUrl)
        values["LAN_SHARED_SECRET"] = nilIfEmpty(config.lanSharedSecret)
        values["CODEX_CWD"] = nilIfEmpty(config.codexCwd)
        values["CLAUDE_CWD"] = nilIfEmpty(config.claudeCwd)
        values["CODEX_SKIP_GIT_REPO_CHECK"] = config.codexSkipGitRepoCheck ? "1" : nil
        values["CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS"] = config.claudeDangerouslySkipPermissions ? "1" : nil
        try writeEnv(values)
    }

    func loadDesktopSettings() -> DesktopSettings {
        guard let data = try? Data(contentsOf: desktopSettingsURL),
              let settings = try? JSONDecoder().decode(DesktopSettings.self, from: data) else {
            return DesktopSettings()
        }
        return settings
    }

    func saveDesktopSettings(_ settings: DesktopSettings) throws {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(settings)
        try data.write(to: desktopSettingsURL, options: .atomic)
    }

    private func readEnv() -> [String: String] {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let index = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }
        return values
    }

    private func writeEnv(_ values: [String: String]) throws {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let body = values
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n") + "\n"
        try body.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func inferredProvider(_ values: [String: String]) -> STTProvider {
        if values["WHISPER_CPP_MODEL_PATH"]?.isEmpty == false { return .whisperCpp }
        if values["QWEN_ASR_API_KEY"]?.isEmpty == false { return .qwenAsr }
        if values["OPENAI_API_KEY"]?.isEmpty == false { return .openai }
        return .volcengine
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
