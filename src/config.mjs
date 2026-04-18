import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

import { getUserConfigPath, projectRoot } from "./paths.mjs";

const INITIAL_ENV_KEYS = new Set(Object.keys(process.env));
let appliedConfigKeys = new Set();

function parseEnvContent(content) {
  const values = {};
  for (const rawLine of content.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) {
      continue;
    }

    const separatorIndex = line.indexOf("=");
    if (separatorIndex <= 0) {
      continue;
    }

    const key = line.slice(0, separatorIndex).trim();
    const value = line.slice(separatorIndex + 1).trim();
    values[key] = value;
  }
  return values;
}

function readEnvFile(filePath) {
  if (!fs.existsSync(filePath)) {
    return null;
  }

  return parseEnvContent(fs.readFileSync(filePath, "utf8"));
}

function applyEnvValues(values) {
  for (const [key, value] of Object.entries(values)) {
    if (INITIAL_ENV_KEYS.has(key)) {
      continue;
    }
    process.env[key] = value;
  }
}

function uniqPaths(paths) {
  return [...new Set(paths.map((candidate) => path.resolve(candidate)))];
}

function invokeCwd() {
  return String(process.env.VIBE_INVOKE_CWD || "").trim() || process.cwd();
}

function resolveDesktopModeOption(desktopMode) {
  if (desktopMode !== undefined) {
    return Boolean(desktopMode);
  }

  return process.env.VIBE_DESKTOP === "1";
}

export function listConfigFileCandidates() {
  return listConfigFileCandidatesForMode();
}

export function listConfigFileCandidatesForMode({ desktopMode } = {}) {
  desktopMode = resolveDesktopModeOption(desktopMode);
  const userConfigPath = getUserConfigPath();
  const projectConfigPath = path.join(projectRoot, ".env");
  const cwdConfigPath = path.join(invokeCwd(), ".env");

  if (desktopMode) {
    return uniqPaths([userConfigPath]);
  }

  return uniqPaths([userConfigPath, projectConfigPath, cwdConfigPath]);
}

export function loadConfigFiles({ quietMissing = false, desktopMode } = {}) {
  desktopMode = resolveDesktopModeOption(desktopMode);
  const mergedValues = {};
  const loadedConfigFiles = [];

  for (const filePath of listConfigFileCandidatesForMode({ desktopMode })) {
    const values = readEnvFile(filePath);
    if (!values) {
      continue;
    }

    Object.assign(mergedValues, values);
    loadedConfigFiles.push(filePath);
  }

  for (const key of appliedConfigKeys) {
    if (!INITIAL_ENV_KEYS.has(key)) {
      delete process.env[key];
    }
  }

  applyEnvValues(mergedValues);
  appliedConfigKeys = new Set(Object.keys(mergedValues).filter((key) => !INITIAL_ENV_KEYS.has(key)));

  if (!quietMissing && loadedConfigFiles.length === 0) {
    console.warn(
      `[vibecoding-plus] No config file found.\n` +
        `                   Run "vibe config" to create ${getUserConfigPath()}.\n` +
        `                   You can also use environment variables or a local .env file.`
    );
  }

  return {
    loadedConfigFiles,
    userConfigPath: getUserConfigPath(),
    cwdConfigPath: path.join(invokeCwd(), ".env"),
    projectConfigPath: path.join(projectRoot, ".env")
  };
}

function resolveCodexCommand() {
  if (process.env.CODEX_COMMAND) {
    return process.env.CODEX_COMMAND;
  }

  if (process.platform !== "win32") {
    return "codex";
  }

  const npmShimPath = path.join(process.env.APPDATA || "", "npm", "codex.ps1");
  return fs.existsSync(npmShimPath) ? npmShimPath : "codex";
}

function resolveClaudeCommand() {
  if (process.env.CLAUDE_COMMAND) {
    return process.env.CLAUDE_COMMAND;
  }

  if (process.platform !== "win32") {
    return "claude";
  }

  const npmShimPath = path.join(process.env.APPDATA || "", "npm", "claude.ps1");
  return fs.existsSync(npmShimPath) ? npmShimPath : "claude";
}

function resolveCodexCwd() {
  const configured = String(process.env.CODEX_CWD || "").trim();
  if (!configured) {
    return invokeCwd();
  }

  return path.isAbsolute(configured) ? configured : path.resolve(invokeCwd(), configured);
}

function normalizeTranscriptDeliveryMode(value) {
  const normalized = String(value || "").trim().toLowerCase();
  return normalized === "immediate" ? "immediate" : "confirm_on_device";
}

function normalizeTextInjectionMode(value) {
  const normalized = String(value || "").trim().toLowerCase();
  return normalized === "type_only" ? "type_only" : "type_and_enter";
}

function normalizeTodoIntentProvider(value, apiKey) {
  const normalized = String(value || "").trim().toLowerCase();
  if (normalized === "deepseek" || normalized === "rules") {
    return normalized;
  }
  return apiKey ? "deepseek" : "rules";
}

export function isCliAvailable(command) {
  if (!command) {
    return false;
  }

  if (path.isAbsolute(command) || command.includes(path.sep)) {
    return fs.existsSync(command);
  }

  try {
    const finder = process.platform === "win32" ? "where" : "which";
    execSync(`${finder} ${command}`, { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function autoDetectSendTarget(claudeCommand, codexCommand) {
  if (isCliAvailable(claudeCommand)) {
    return { sendTarget: "claude_code", sendTargetAuto: true };
  }
  if (isCliAvailable(codexCommand)) {
    return { sendTarget: "codex_exec", sendTargetAuto: true };
  }
  return { sendTarget: "text_injector", sendTargetAuto: true };
}

export function resolveSendTarget(sendTargetEnv, { desktopMode = false, claudeCommand, codexCommand } = {}) {
  const explicitSendTarget = String(sendTargetEnv || "").trim();
  if (explicitSendTarget) {
    return { sendTarget: explicitSendTarget, sendTargetAuto: false };
  }

  if (desktopMode) {
    return { sendTarget: "text_injector", sendTargetAuto: false };
  }

  return autoDetectSendTarget(claudeCommand, codexCommand);
}

export function detectConfiguredSttProvider(config) {
  const explicit = String(config.sttProvider || "").trim().toLowerCase();
  if (explicit) {
    return explicit;
  }

  if (config.whisperCppModelPath) {
    return "whisper_cpp";
  }

  if (config.qwenAsrModel) {
    return "qwen_asr";
  }

  if (config.openaiApiKey) {
    return "openai";
  }

  if (config.volcengineAppKey || config.volcengineAccessKey) {
    return "volcengine";
  }

  return "";
}


export function getConfigIssues(config) {
  if (config.mockTranscript) {
    return [];
  }

  const provider = detectConfiguredSttProvider(config);
  if (!provider) {
    return [
      "No STT provider is configured. Set STT_PROVIDER or provider-specific settings (QWEN_ASR_MODEL + QWEN_ASR_API_KEY + QWEN_ASR_REALTIME_BASE_URL, OPENAI_API_KEY, VOLCENGINE_APP_KEY + VOLCENGINE_ACCESS_KEY, or WHISPER_CPP_MODEL_PATH)."
    ];
  }

  if (provider === "qwen_asr") {
    const issues = [];
    if (!String(config.qwenAsrModel || "").trim()) {
      issues.push("QWEN_ASR_MODEL is not set.");
    }
    if (!String(config.qwenAsrApiKey || "").trim()) {
      issues.push("QWEN_ASR_API_KEY is not set.");
    }
    if (!String(config.qwenAsrRealtimeBaseUrl || "").trim()) {
      issues.push("QWEN_ASR_REALTIME_BASE_URL is not set.");
    }
    return issues;
  }

  if (provider === "openai") {
    return config.openaiApiKey ? [] : ["OPENAI_API_KEY is not set."];
  }

  if (provider === "volcengine") {
    const issues = [];
    if (!config.volcengineAppKey) {
      issues.push("VOLCENGINE_APP_KEY is not set.");
    }
    if (!config.volcengineAccessKey) {
      issues.push("VOLCENGINE_ACCESS_KEY is not set.");
    }
    return issues;
  }

  if (provider === "whisper_cpp") {
    const issues = [];
    if (!config.whisperCppModelPath) {
      issues.push("WHISPER_CPP_MODEL_PATH is not set.");
    }
    return issues;
  }

  return [`Unsupported STT_PROVIDER: ${config.sttProvider}`];
}

export function hasRequiredConfig(config) {
  return getConfigIssues(config).length === 0;
}

export function readUserConfigValues() {
  return readEnvFile(getUserConfigPath()) || {};
}

function normalizeEnvValue(value) {
  if (value === undefined || value === null) {
    return "";
  }
  return String(value).replace(/\r?\n/g, " ").trim();
}

function formatEnvFile(values) {
  const keys = Object.keys(values).sort((left, right) => left.localeCompare(right));
  return `${keys.map((key) => `${key}=${normalizeEnvValue(values[key])}`).join("\n")}\n`;
}

export function writeUserConfigValues(updates) {
  const currentValues = readUserConfigValues();
  const nextValues = { ...currentValues };

  for (const [key, value] of Object.entries(updates)) {
    if (value === undefined) {
      continue;
    }

    if (value === null) {
      delete nextValues[key];
      continue;
    }

    nextValues[key] = normalizeEnvValue(value);
  }

  const userConfigPath = getUserConfigPath();
  fs.mkdirSync(path.dirname(userConfigPath), { recursive: true });
  fs.writeFileSync(userConfigPath, formatEnvFile(nextValues), "utf8");
  return userConfigPath;
}

export function redactValue(value) {
  const trimmed = String(value || "").trim();
  if (!trimmed) {
    return "(not set)";
  }

  if (trimmed.length <= 8) {
    return `${trimmed.slice(0, 1)}***${trimmed.slice(-1)}`;
  }

  return `${trimmed.slice(0, 4)}***${trimmed.slice(-4)}`;
}

export function loadConfig(options = {}) {
  const desktopMode = resolveDesktopModeOption(options.desktopMode);
  const { loadedConfigFiles, userConfigPath, cwdConfigPath, projectConfigPath } = loadConfigFiles({
    ...options,
    desktopMode
  });

  const claudeCommand = resolveClaudeCommand();
  const codexCommand = resolveCodexCommand();

  const { sendTarget, sendTargetAuto } = resolveSendTarget(process.env.SEND_TARGET, {
    desktopMode,
    claudeCommand,
    codexCommand
  });
  const todoIntentApiKey = process.env.TODO_INTENT_API_KEY || process.env.DEEPSEEK_API_KEY || "";

  return {
    bindHost: process.env.LAN_VOICE_BIND || "0.0.0.0",
    port: Number(process.env.LAN_VOICE_PORT || "8765"),
    discoveryEnabled: process.env.LAN_DISCOVERY_ENABLED !== "0",
    discoveryPort: Number(process.env.LAN_DISCOVERY_PORT || "8766"),
    discoveryHostId:
      String(process.env.LAN_DISCOVERY_HOST_ID || "").trim() ||
      process.env.COMPUTERNAME ||
      process.env.HOSTNAME ||
      "vibecoding-plus-host",
    lanSharedSecret: String(process.env.LAN_SHARED_SECRET || "").trim(),
    lanAuthWindowSec: Number(process.env.LAN_AUTH_WINDOW_SEC || "300"),
    lanTrustLocalhost: process.env.LAN_TRUST_LOCALHOST === "1",
    lanAudioMaxBytes: Math.max(32768, Number(process.env.LAN_AUDIO_MAX_BYTES || `${2 * 1024 * 1024}`)),
    lanAudioMaxMs: Math.max(1000, Number(process.env.LAN_AUDIO_MAX_MS || "120000")),
    sendTarget,
    sendTargetAuto,
    transcriptDeliveryMode: normalizeTranscriptDeliveryMode(
      process.env.TRANSCRIPT_DELIVERY_MODE || "confirm_on_device"
    ),
    textInjectionMode: normalizeTextInjectionMode(
      process.env.TEXT_INJECTION_MODE || "type_and_enter"
    ),
    todoIntentProvider: normalizeTodoIntentProvider(process.env.TODO_INTENT_PROVIDER, todoIntentApiKey),
    todoIntentApiKey,
    todoIntentModel: process.env.TODO_INTENT_MODEL || "deepseek-chat",
    todoIntentBaseUrl: process.env.TODO_INTENT_BASE_URL || "https://api.deepseek.com",
    todoIntentTimeoutMs: Number(process.env.TODO_INTENT_TIMEOUT_MS || "8000"),
    todoFollowupTimeoutMs: Number(process.env.TODO_FOLLOWUP_TIMEOUT_MS || "30000"),
    deepseekApiKey: process.env.DEEPSEEK_API_KEY || "",
    dryRunTextInjection: process.env.DRY_RUN_TEXT_INJECTION === "1",
    terminalMirrorEnabled: process.env.TERMINAL_MIRROR_ENABLED === "1",
    terminalMirrorSession: String(process.env.TERMINAL_MIRROR_SESSION || "").trim() || "vibehost",
    terminalMirrorWindow: String(process.env.TERMINAL_MIRROR_WINDOW || "").trim() || "node",
    terminalMirrorIntervalMs: Number(process.env.TERMINAL_MIRROR_INTERVAL_MS || "800"),
    terminalMirrorLines: Number(process.env.TERMINAL_MIRROR_LINES || "60"),
    codexCommand,
    codexCwd: resolveCodexCwd(),
    codexSkipGitRepoCheck: process.env.CODEX_SKIP_GIT_REPO_CHECK === "1",
    claudeCommand,
    claudeCwd: String(process.env.CLAUDE_CWD || "").trim()
      ? path.resolve(invokeCwd(), String(process.env.CLAUDE_CWD || "").trim())
      : invokeCwd(),
    claudeAllowedTools: process.env.CLAUDE_ALLOWED_TOOLS || "Read,Edit,Write,Bash,Glob,Grep",
    claudeMaxTurns: process.env.CLAUDE_MAX_TURNS !== undefined ? Number(process.env.CLAUDE_MAX_TURNS) : 30,
    claudeDangerouslySkipPermissions: process.env.CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS === "1",
    cliTimeoutSec: Number(process.env.CLI_TIMEOUT_SEC || "300"),
    sttProvider: process.env.STT_PROVIDER || "",
    openaiBaseUrl: process.env.OPENAI_BASE_URL || "https://api.openai.com/v1",
    openaiApiKey: process.env.OPENAI_API_KEY || "",
    openaiModel: process.env.OPENAI_TRANSCRIBE_MODEL || "whisper-1",
    openaiLanguage: process.env.OPENAI_TRANSCRIBE_LANGUAGE || "",
    whisperCppCommand: process.env.WHISPER_CPP_COMMAND || "whisper-cli",
    whisperCppModelPath: process.env.WHISPER_CPP_MODEL_PATH || "",
    whisperCppLanguage: process.env.WHISPER_CPP_LANGUAGE || "zh",
    whisperCppThreads: Number(process.env.WHISPER_CPP_THREADS || "4"),
    whisperCppExtraArgs: process.env.WHISPER_CPP_EXTRA_ARGS || "",
    whisperCppTimeoutMs: Number(process.env.WHISPER_CPP_TIMEOUT_MS || "45000"),
    volcengineAppKey: process.env.VOLCENGINE_APP_KEY || "",
    volcengineAccessKey: process.env.VOLCENGINE_ACCESS_KEY || "",
    volcengineResourceId: process.env.VOLCENGINE_RESOURCE_ID || "volc.bigasr.auc_turbo",
    volcengineLanguage: process.env.VOLCENGINE_LANGUAGE || "zh-CN",
    qwenAsrModel: process.env.QWEN_ASR_MODEL || "Qwen/Qwen3-ASR-0.6B",
    qwenAsrLanguage: process.env.QWEN_ASR_LANGUAGE || "zh",
    qwenAsrPrompt: process.env.QWEN_ASR_PROMPT || "",
    qwenAsrTimeoutMs: Number(process.env.QWEN_ASR_TIMEOUT_MS || "45000"),
    qwenAsrApiKey: process.env.QWEN_ASR_API_KEY || process.env.DASHSCOPE_API_KEY || "",
    qwenAsrRealtimeBaseUrl: process.env.QWEN_ASR_REALTIME_BASE_URL || "wss://dashscope.aliyuncs.com/api-ws/v1/realtime",
    qwenAsrSampleRate: Number(process.env.QWEN_ASR_SAMPLE_RATE || "16000"),
    mockTranscript: process.env.MOCK_TRANSCRIPT || "",
    saveDebugWav: process.env.SAVE_DEBUG_WAV === "1",
    userConfigPath,
    cwdConfigPath,
    projectConfigPath
  };
}
