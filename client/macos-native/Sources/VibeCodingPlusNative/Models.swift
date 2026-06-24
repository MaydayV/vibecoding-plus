import Foundation

enum ServiceStatus: String {
    case stopped
    case starting
    case running
    case needsSetup
    case error

    var label: String {
        switch self {
        case .stopped: "已停止"
        case .starting: "启动中"
        case .running: "运行中"
        case .needsSetup: "待配置"
        case .error: "异常"
        }
    }
}

enum SendTarget: String, CaseIterable, Identifiable {
    case textInjector = "text_injector"
    case codexExec = "codex_exec"
    case claudeCode = "claude_code"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .textInjector: "输入注入"
        case .codexExec: "Codex"
        case .claudeCode: "Claude Code"
        }
    }
}

enum STTProvider: String, CaseIterable, Identifiable {
    case volcengine
    case openai
    case whisperCpp = "whisper_cpp"
    case qwenAsr = "qwen_asr"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .volcengine: "Volcengine"
        case .openai: "OpenAI"
        case .whisperCpp: "whisper.cpp"
        case .qwenAsr: "Qwen3-ASR"
        }
    }
}

struct ServiceSnapshot {
    var status: ServiceStatus = .stopped
    var message: String = "服务已停止"
    var mode: SendTarget = .textInjector
    var port: Int = 8765
    var pid: Int32?
    var logs: [String] = []
}

struct EnvironmentCheck: Identifiable, Codable {
    var id: String
    var label: String
    var type: String
    var status: String
    var required: Bool
    var installable: Bool
    var installLabel: String
    var command: String
    var path: String
    var version: String
    var purpose: String
    var note: String

    var statusLabel: String {
        switch status {
        case "ok": "正常"
        case "missing": "缺失"
        case "optional": "可选"
        default: "提示"
        }
    }
}

struct EnvironmentReport {
    var ok: Bool
    var path: String
    var provider: String
    var sendTarget: SendTarget
    var checks: [EnvironmentCheck]
}

struct DesktopSettings: Codable {
    var autoLaunch: Bool = false
    var launchToTray: Bool = false
    var closeToTray: Bool = false
}

struct AppConfig {
    var sendTarget: SendTarget = .textInjector
    var sttProvider: STTProvider = .volcengine
    var transcriptDeliveryMode: String = "confirm_on_device"
    var textInjectionMode: String = "type_and_enter"
    var openaiApiKey: String = ""
    var openaiModel: String = "whisper-1"
    var volcengineAppKey: String = ""
    var volcengineAccessKey: String = ""
    var whisperCppModelPath: String = ""
    var whisperCppLanguage: String = "zh"
    var whisperCppThreads: String = "4"
    var whisperCppCommand: String = "whisper-cli"
    var whisperCppExtraArgs: String = ""
    var qwenAsrApiKey: String = ""
    var qwenAsrModel: String = "Qwen/Qwen3-ASR-0.6B"
    var qwenAsrLanguage: String = "zh"
    var qwenAsrPrompt: String = ""
    var qwenAsrSampleRate: String = "16000"
    var qwenAsrRealtimeBaseUrl: String = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
    var lanSharedSecret: String = ""
    var codexCwd: String = ""
    var claudeCwd: String = ""
    var codexSkipGitRepoCheck: Bool = false
    var claudeDangerouslySkipPermissions: Bool = false
    var port: Int = 8765
}

struct DeviceInfo: Identifiable, Decodable {
    var deviceId: String
    var boardType: String?
    var voiceMode: String?
    var remoteAddress: String?
    var connectedAt: Double?

    var id: String { deviceId }
}

struct TodoSnapshot: Decodable {
    var items: [TodoItem] = []
    var archiveItems: [TodoItem] = []
}

struct TodoItem: Identifiable, Decodable {
    var id: String
    var title: String
    var completed: Bool
    var dueAt: String?
    var appleId: String?
}

struct ServiceStatusPayload: Decodable {
    var ok: Bool
    var uptime: Double?
    var clientCount: Int?
    var sttProvider: String?
    var sendTarget: String?
    var discoveryEnabled: Bool?
    var port: Int?
    var nodeVersion: String?
}

struct ReminderSyncStatus: Decodable {
    var enabled: Bool?
    var lastSyncAt: Double?
    var syncCount: Int?
    var lastError: String?
}

struct ReminderSyncPayload: Decodable {
    var ok: Bool
    var status: ReminderSyncStatus?
}
