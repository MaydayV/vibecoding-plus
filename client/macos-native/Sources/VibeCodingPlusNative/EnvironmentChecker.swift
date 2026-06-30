import AppKit
import Foundation
import EventKit
#if canImport(AVFoundation)
import AVFoundation
import AVFAudio
#endif

struct EnvironmentChecker {
    func check(config: AppConfig) async -> EnvironmentReport {
        let provider = config.sttProvider
        let commands = [
            "brew": "brew",
            "remindctl": "remindctl",
            "claude": "claude",
            "codex": "codex",
            "whisper_cpp": config.whisperCppCommand.isEmpty ? "whisper-cli" : config.whisperCppCommand
        ]

        async let brewVersion = version(command: commands["brew"] ?? "brew", args: ["--version"])
        async let remindVersion = version(command: commands["remindctl"] ?? "remindctl", args: ["--version"])
        async let claudeVersion = version(command: commands["claude"] ?? "claude", args: ["--version"])
        async let codexVersion = version(command: commands["codex"] ?? "codex", args: ["--version"])
        async let whisperVersion = version(command: commands["whisper_cpp"] ?? "whisper-cli", args: ["--help"])

        let versions = await [
            "brew": brewVersion,
            "remindctl": remindVersion,
            "claude": claudeVersion,
            "codex": codexVersion,
            "whisper_cpp": whisperVersion
        ]

        let checks = [
            tool(
                id: "brew",
                label: "Homebrew",
                command: commands["brew"] ?? "brew",
                required: false,
                installLabel: "安装 Homebrew",
                purpose: "安装 remindctl、whisper.cpp 等 macOS 工具",
                note: "没有 Homebrew 时会先安装 Homebrew",
                version: versions["brew"] ?? ""
            ),
            tool(
                id: "remindctl",
                label: "remindctl",
                command: commands["remindctl"] ?? "remindctl",
                required: false,
                installLabel: "安装 remindctl",
                purpose: "Apple 提醒事项同步",
                note: "启用提醒同步时需要",
                version: versions["remindctl"] ?? ""
            ),
            tool(
                id: "claude",
                label: "Claude Code CLI",
                command: commands["claude"] ?? "claude",
                required: config.sendTarget == .claudeCode,
                installLabel: "安装 Claude CLI",
                purpose: "Claude Code 模式",
                note: config.sendTarget == .claudeCode ? "当前模式需要 Claude CLI" : "仅 Claude Code 模式需要",
                version: versions["claude"] ?? ""
            ),
            tool(
                id: "codex",
                label: "Codex CLI",
                command: commands["codex"] ?? "codex",
                required: config.sendTarget == .codexExec,
                installLabel: "安装 Codex CLI",
                purpose: "Codex 模式",
                note: config.sendTarget == .codexExec ? "当前模式需要 Codex CLI" : "仅 Codex 模式需要",
                version: versions["codex"] ?? ""
            ),
            tool(
                id: "whisper_cpp",
                label: "whisper.cpp",
                command: commands["whisper_cpp"] ?? "whisper-cli",
                required: provider == .whisperCpp,
                installLabel: "安装 whisper.cpp",
                purpose: "本地语音识别",
                note: provider == .whisperCpp ? "当前 STT provider 需要 whisper-cli 和模型文件" : "仅选择 whisper.cpp 时需要",
                version: versions["whisper_cpp"] ?? ""
            ),
            sttCheck(config: config),
            macosPermissionsCheck(config: config)
        ]

        return EnvironmentReport(
            ok: checks.allSatisfy { $0.status != "missing" },
            path: Shell.toolPath(),
            provider: provider.rawValue,
            sendTarget: config.sendTarget,
            checks: checks
        )
    }

    private func macosPermissionsCheck(config: AppConfig) -> EnvironmentCheck {
        let accessibility = AccessibilitySupport.isTrusted
        let reminderGranted: Bool = {
            let status = EKEventStore.authorizationStatus(for: .reminder)
            return status == .authorized || status == .fullAccess || status == .writeOnly
        }()
        let micGranted = MicrophonePermission.isGranted

        let needsAccessibility = config.sendTarget == .textInjector
        let needsReminders = config.remindersSyncEnabled
        let needsMic = true

        var missing: [String] = []
        if needsAccessibility && !accessibility { missing.append("辅助功能") }
        if needsReminders && !reminderGranted { missing.append("提醒事项") }
        if needsMic && !micGranted { missing.append("麦克风") }

        let allRequired = [needsAccessibility ? accessibility : true,
                           needsReminders ? reminderGranted : true,
                           micGranted].allSatisfy { $0 }
        let anyMissing = !missing.isEmpty

        var status = "optional"
        if allRequired && !anyMissing {
            status = "ok"
        } else if anyMissing {
            status = "missing"
        }

        let parts: [String] = [
            "辅助功能: \(accessibility ? "已授权" : (needsAccessibility ? "未授权" : "不需要"))",
            "麦克风: \(MicrophonePermission.statusText)",
            "提醒事项: \(reminderGranted ? "已授权" : (needsReminders ? "未授权" : "不需要"))"
        ]
        let version = parts.joined(separator: " · ")

        let note: String
        if anyMissing {
            note = "缺少: \(missing.joined(separator: "、")) — 点「在 Finder 中显示」→ 系统设置辅助功能删除旧条目 → 用 + 重新添加当前应用"
        } else {
            note = "已授权所需权限；重新编译后若输入失效，请重新添加辅助功能授权"
        }

        return EnvironmentCheck(
            id: "macos_permissions",
            label: "macOS 权限",
            type: "permission",
            status: status,
            required: needsAccessibility || needsReminders,
            installable: false,
            installLabel: "",
            command: "",
            path: "",
            version: version,
            purpose: "输入注入、麦克风、提醒事项访问",
            note: note
        )
    }

    func installScript(for toolId: String) -> String {
        let brewInstall = """
        if ! command -v brew >/dev/null 2>&1; then
          echo "Installing Homebrew..."
          NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
        if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
        """

        switch toolId {
        case "brew":
            return """
            set -e
            if command -v brew >/dev/null 2>&1; then
              brew --version
              exit 0
            fi
            NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
            if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
            brew --version
            """
        case "remindctl":
            return "set -e\n\(brewInstall)\nbrew install remindctl\nremindctl --version"
        case "whisper_cpp":
            return "set -e\n\(brewInstall)\nbrew install whisper-cpp\nwhisper-cli --help >/dev/null || true\necho \"whisper.cpp installed\""
        case "claude":
            return """
            set -e
            curl -fsSL https://claude.ai/install.sh | bash
            export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
            claude --version
            """
        case "codex":
            return """
            set -e
            curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
            export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
            codex --version
            """
        default:
            return ""
        }
    }

    func openPermissions() {
        AccessibilitySupport.openAccessibilitySettings()
        AccessibilitySupport.revealRunningAppInFinder()
    }

    func openToolLogin(_ toolId: String) throws {
        let command: String
        switch toolId {
        case "codex": command = "codex"
        case "claude": command = "claude"
        case "remindctl": command = "remindctl status"
        case "whisper_cpp": command = "whisper-cli --help"
        default: return
        }

        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("vibecoding-\(toolId)-\(Int(Date().timeIntervalSince1970)).command")
        let content = """
        #!/bin/zsh
        export PATH="\(Shell.toolPath().replacingOccurrences(of: "\"", with: "\\\""))"
        cd "$HOME"
        \(command)
        echo
        echo '完成后可关闭此窗口。'
        read -k 1 '?按任意键关闭...'
        """
        try content.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        NSWorkspace.shared.open(scriptURL)
    }

    private func tool(id: String, label: String, command: String, required: Bool, installLabel: String, purpose: String, note: String, version: String) -> EnvironmentCheck {
        let found = Shell.findExecutable(command)
        let ok = !found.isEmpty
        return EnvironmentCheck(
            id: id,
            label: label,
            type: "tool",
            status: ok ? "ok" : required ? "missing" : "optional",
            required: required,
            installable: !ok,
            installLabel: installLabel,
            command: command,
            path: found,
            version: version,
            purpose: purpose,
            note: note
        )
    }

    private func sttCheck(config: AppConfig) -> EnvironmentCheck {
        let missing: String
        switch config.sttProvider {
        case .volcengine:
            missing = config.volcengineAppKey.isEmpty || config.volcengineAccessKey.isEmpty ? "Volcengine App Key / Access Key 未填写" : ""
        case .openai:
            missing = config.openaiApiKey.isEmpty ? "OpenAI API Key 未填写" : ""
        case .whisperCpp:
            missing = config.whisperCppModelPath.isEmpty ? "whisper.cpp 模型路径未填写" : ""
        case .qwenAsr:
            missing = config.qwenAsrApiKey.isEmpty ? "Qwen ASR API Key 未填写" : ""
        }

        return EnvironmentCheck(
            id: "stt_config",
            label: "STT 密钥 / 模型",
            type: "config",
            status: missing.isEmpty ? "ok" : "missing",
            required: true,
            installable: false,
            installLabel: "",
            command: "",
            path: SettingsStore().configURL.path,
            version: "",
            purpose: "语音转文字",
            note: missing.isEmpty ? "语音识别配置完整" : missing
        )
    }

    private func version(command: String, args: [String]) async -> String {
        let executable = Shell.findExecutable(command)
        guard !executable.isEmpty else { return "" }
        let result = await Shell.run(executable, arguments: args, timeout: 4)
        return result.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}
