import { detectConfiguredSttProvider, getConfigIssues } from "./config.mjs";
import { normalizeDesktopSettings } from "./desktop-settings.mjs";

const VALID_SEND_TARGETS = new Set(["text_injector", "codex_exec", "claude_code"]);
const VALID_STT_PROVIDERS = new Set(["volcengine", "openai", "whisper_cpp", "qwen_asr"]);

function normalizeChoice(value, fallback, validValues) {
  const normalized = String(value || "").trim();
  return validValues.has(normalized) ? normalized : fallback;
}

function normalizeOptionalText(value) {
  const trimmed = String(value ?? "").trim();
  return trimmed ? trimmed : null;
}

export function buildDesktopFormState(config, desktopSettings = {}) {
  return {
    sendTarget: normalizeChoice(config.sendTarget, "text_injector", VALID_SEND_TARGETS),
    sttProvider: normalizeChoice(detectConfiguredSttProvider(config), "volcengine", VALID_STT_PROVIDERS),
    openaiApiKey: String(config.openaiApiKey || ""),
    openaiModel: String(config.openaiModel || "whisper-1"),
    volcengineAppKey: String(config.volcengineAppKey || ""),
    volcengineAccessKey: String(config.volcengineAccessKey || ""),
    whisperCppModelPath: String(config.whisperCppModelPath || ""),
    whisperCppLanguage: String(config.whisperCppLanguage || "zh"),
    whisperCppThreads: String(config.whisperCppThreads || "4"),
    whisperCppCommand: String(config.whisperCppCommand || "whisper-cli"),
    whisperCppExtraArgs: String(config.whisperCppExtraArgs || ""),
    qwenAsrApiKey: String(config.qwenAsrApiKey || ""),
    qwenAsrModel: String(config.qwenAsrModel || "Qwen/Qwen3-ASR-0.6B"),
    qwenAsrLanguage: String(config.qwenAsrLanguage || "zh"),
    qwenAsrPrompt: String(config.qwenAsrPrompt || ""),
    qwenAsrRealtimeBaseUrl: String(config.qwenAsrRealtimeBaseUrl || "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"),
    qwenAsrSampleRate: String(config.qwenAsrSampleRate || 16000),
    transcriptDeliveryMode:
      String(config.transcriptDeliveryMode || "").trim().toLowerCase() === "immediate"
        ? "immediate"
        : "confirm_on_device",
    textInjectionMode:
      String(config.textInjectionMode || "").trim().toLowerCase() === "type_only"
        ? "type_only"
        : "type_and_enter",
    lanSharedSecret: String(config.lanSharedSecret || ""),
    codexCwd: String(config.codexCwd || ""),
    claudeCwd: String(config.claudeCwd || ""),
    codexSkipGitRepoCheck: Boolean(config.codexSkipGitRepoCheck),
    claudeDangerouslySkipPermissions: Boolean(config.claudeDangerouslySkipPermissions),
    desktopSettings: normalizeDesktopSettings(desktopSettings),
    configIssues: getConfigIssues(config),
    loadedConfigFiles: [...(config.loadedConfigFiles || [])],
    overrideFiles: (config.loadedConfigFiles || []).filter((filePath) => filePath !== config.userConfigPath),
    userConfigPath: config.userConfigPath,
    cwdConfigPath: config.cwdConfigPath,
    projectConfigPath: config.projectConfigPath,
    port: config.port,
    discoveryPort: config.discoveryPort
  };
}

export function buildUserConfigUpdates(formState = {}) {
  const sendTarget = normalizeChoice(formState.sendTarget, "text_injector", VALID_SEND_TARGETS);
  const sttProvider = normalizeChoice(formState.sttProvider, "volcengine", VALID_STT_PROVIDERS);

  return {
    SEND_TARGET: sendTarget,
    STT_PROVIDER: sttProvider,
    OPENAI_API_KEY: normalizeOptionalText(formState.openaiApiKey),
    OPENAI_TRANSCRIBE_MODEL: normalizeOptionalText(formState.openaiModel),
    VOLCENGINE_APP_KEY: normalizeOptionalText(formState.volcengineAppKey),
    VOLCENGINE_ACCESS_KEY: normalizeOptionalText(formState.volcengineAccessKey),
    WHISPER_CPP_MODEL_PATH: normalizeOptionalText(formState.whisperCppModelPath),
    WHISPER_CPP_LANGUAGE: normalizeOptionalText(formState.whisperCppLanguage),
    WHISPER_CPP_THREADS: normalizeOptionalText(formState.whisperCppThreads),
    WHISPER_CPP_COMMAND: normalizeOptionalText(formState.whisperCppCommand),
    WHISPER_CPP_EXTRA_ARGS: normalizeOptionalText(formState.whisperCppExtraArgs),
    QWEN_ASR_API_KEY: normalizeOptionalText(formState.qwenAsrApiKey),
    QWEN_ASR_MODEL: normalizeOptionalText(formState.qwenAsrModel),
    QWEN_ASR_LANGUAGE: normalizeOptionalText(formState.qwenAsrLanguage),
    QWEN_ASR_PROMPT: normalizeOptionalText(formState.qwenAsrPrompt),
    QWEN_ASR_REALTIME_BASE_URL: normalizeOptionalText(formState.qwenAsrRealtimeBaseUrl),
    QWEN_ASR_SAMPLE_RATE: normalizeOptionalText(formState.qwenAsrSampleRate),
    TRANSCRIPT_DELIVERY_MODE:
      String(formState.transcriptDeliveryMode || "").trim().toLowerCase() === "immediate"
        ? "immediate"
        : "confirm_on_device",
    TEXT_INJECTION_MODE:
      String(formState.textInjectionMode || "").trim().toLowerCase() === "type_only"
        ? "type_only"
        : "type_and_enter",
    LAN_SHARED_SECRET: normalizeOptionalText(formState.lanSharedSecret),
    CODEX_CWD: normalizeOptionalText(formState.codexCwd),
    CLAUDE_CWD: normalizeOptionalText(formState.claudeCwd),
    CODEX_SKIP_GIT_REPO_CHECK: formState.codexSkipGitRepoCheck ? "1" : null,
    CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS: formState.claudeDangerouslySkipPermissions ? "1" : null
  };
}
