import test from "node:test";
import assert from "node:assert/strict";

import { buildDesktopFormState, buildUserConfigUpdates } from "../src/desktop-config.mjs";
import { normalizeDesktopSettings } from "../src/desktop-settings.mjs";
import { listConfigFileCandidatesForMode, resolveSendTarget } from "../src/config.mjs";

test("normalizeDesktopSettings applies safe defaults", () => {
  assert.deepEqual(normalizeDesktopSettings(), {
    autoLaunch: false,
    launchToTray: false,
    closeToTray: false
  });

  assert.deepEqual(
    normalizeDesktopSettings({
      autoLaunch: true,
      launchToTray: true,
      closeToTray: false
    }),
    {
      autoLaunch: true,
      launchToTray: true,
      closeToTray: false
    }
  );
});

test("buildDesktopFormState exposes effective config values for the desktop UI", () => {
  const formState = buildDesktopFormState(
    {
      sendTarget: "claude_code",
      sttProvider: "openai",
      openaiApiKey: "sk-test",
      openaiModel: "gpt-4o-mini-transcribe",
      volcengineAppKey: "",
      volcengineAccessKey: "",
      whisperCppModelPath: "",
      whisperCppLanguage: "zh",
      whisperCppThreads: 4,
      whisperCppCommand: "whisper-cli",
      whisperCppExtraArgs: "",
      qwenAsrApiKey: "",
      qwenAsrModel: "Qwen/Qwen3-ASR-0.6B",
      qwenAsrLanguage: "zh",
      qwenAsrPrompt: "",
      qwenAsrSampleRate: 16000,
      qwenAsrRealtimeBaseUrl: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime",
      transcriptDeliveryMode: "immediate",
      textInjectionMode: "type_only",
      lanSharedSecret: "secret",
      codexCwd: "D:/codex",
      claudeCwd: "D:/claude",
      codexSkipGitRepoCheck: true,
      claudeDangerouslySkipPermissions: true,
      loadedConfigFiles: ["C:/Users/test/AppData/Roaming/vibecoding-plus/config.env", "D:/github/app/.env"],
      userConfigPath: "C:/Users/test/AppData/Roaming/vibecoding-plus/config.env",
      cwdConfigPath: "D:/github/app/.env",
      projectConfigPath: "D:/github/vibecoding-plus/.env",
      port: 8765,
      discoveryPort: 8766
    },
    {
      autoLaunch: true,
      launchToTray: true,
      closeToTray: false
    }
  );

  assert.equal(formState.sendTarget, "claude_code");
  assert.equal(formState.sttProvider, "openai");
  assert.equal(formState.openaiModel, "gpt-4o-mini-transcribe");
  assert.equal(formState.transcriptDeliveryMode, "immediate");
  assert.equal(formState.textInjectionMode, "type_only");
  assert.deepEqual(formState.overrideFiles, ["D:/github/app/.env"]);
  assert.deepEqual(formState.desktopSettings, {
    autoLaunch: true,
    launchToTray: true,
    closeToTray: false
  });
});

test("buildUserConfigUpdates normalizes desktop form payload into env values", () => {
  const updates = buildUserConfigUpdates({
    sendTarget: "codex_exec",
    sttProvider: "volcengine",
    openaiApiKey: "sk-keep",
    openaiModel: "whisper-1",
    volcengineAppKey: "app-key",
    volcengineAccessKey: "access-key",
    qwenAsrApiKey: "sk-qwen",
    qwenAsrModel: "qwen3-asr-flash-realtime",
    qwenAsrLanguage: "zh",
    qwenAsrPrompt: "",
    qwenAsrSampleRate: "16000",
    qwenAsrRealtimeBaseUrl: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime",
    transcriptDeliveryMode: "immediate",
    textInjectionMode: "type_only",
    lanSharedSecret: "",
    codexCwd: "D:/workspace",
    claudeCwd: "",
    codexSkipGitRepoCheck: true,
    claudeDangerouslySkipPermissions: false
  });

  assert.deepEqual(updates, {
    SEND_TARGET: "codex_exec",
    STT_PROVIDER: "volcengine",
    OPENAI_API_KEY: "sk-keep",
    OPENAI_TRANSCRIBE_MODEL: "whisper-1",
    VOLCENGINE_APP_KEY: "app-key",
    VOLCENGINE_ACCESS_KEY: "access-key",
    WHISPER_CPP_MODEL_PATH: null,
    WHISPER_CPP_LANGUAGE: null,
    WHISPER_CPP_THREADS: null,
    WHISPER_CPP_COMMAND: null,
    WHISPER_CPP_EXTRA_ARGS: null,
    QWEN_ASR_API_KEY: "sk-qwen",
    QWEN_ASR_MODEL: "qwen3-asr-flash-realtime",
    QWEN_ASR_LANGUAGE: "zh",
    QWEN_ASR_PROMPT: null,
    QWEN_ASR_REALTIME_BASE_URL: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime",
    QWEN_ASR_SAMPLE_RATE: "16000",
    TRANSCRIPT_DELIVERY_MODE: "immediate",
    TEXT_INJECTION_MODE: "type_only",
    LAN_SHARED_SECRET: null,
    CODEX_CWD: "D:/workspace",
    CLAUDE_CWD: null,
    CODEX_SKIP_GIT_REPO_CHECK: "1",
    CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS: null
  });
});

test("buildDesktopFormState supports whisper_cpp provider fields", () => {
  const formState = buildDesktopFormState({
    sendTarget: "text_injector",
    sttProvider: "whisper_cpp",
    whisperCppModelPath: "/models/ggml-base.bin",
    whisperCppLanguage: "zh",
    whisperCppThreads: 6,
    whisperCppCommand: "whisper-cli",
    whisperCppExtraArgs: "-fa",
    loadedConfigFiles: [],
    userConfigPath: "C:/Users/test/AppData/Roaming/vibecoding-plus/config.env",
    cwdConfigPath: "D:/github/app/.env",
    projectConfigPath: "D:/github/vibecoding-plus/.env",
    port: 8765,
    discoveryPort: 8766
  });

  assert.equal(formState.sttProvider, "whisper_cpp");
  assert.equal(formState.whisperCppModelPath, "/models/ggml-base.bin");
  assert.equal(formState.whisperCppLanguage, "zh");
  assert.equal(formState.whisperCppThreads, "6");
  assert.equal(formState.whisperCppCommand, "whisper-cli");
  assert.equal(formState.whisperCppExtraArgs, "-fa");
});

test("buildDesktopFormState supports qwen_asr realtime fields", () => {
  const formState = buildDesktopFormState({
    sendTarget: "text_injector",
    sttProvider: "qwen_asr",
    qwenAsrApiKey: "sk-qwen",
    qwenAsrModel: "qwen3-asr-flash-realtime",
    qwenAsrLanguage: "zh",
    qwenAsrPrompt: "只输出转写文本",
    qwenAsrSampleRate: 16000,
    qwenAsrRealtimeBaseUrl: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime",
    loadedConfigFiles: [],
    userConfigPath: "C:/Users/test/AppData/Roaming/vibecoding-plus/config.env",
    cwdConfigPath: "D:/github/app/.env",
    projectConfigPath: "D:/github/vibecoding-plus/.env",
    port: 8765,
    discoveryPort: 8766
  });

  assert.equal(formState.sttProvider, "qwen_asr");
  assert.equal(formState.qwenAsrApiKey, "sk-qwen");
  assert.equal(formState.qwenAsrModel, "qwen3-asr-flash-realtime");
  assert.equal(formState.qwenAsrLanguage, "zh");
  assert.equal(formState.qwenAsrPrompt, "只输出转写文本");
  assert.equal(formState.qwenAsrSampleRate, "16000");
  assert.equal(formState.qwenAsrRealtimeBaseUrl, "wss://dashscope.aliyuncs.com/api-ws/v1/realtime");
});

test("buildUserConfigUpdates maps whisper_cpp form values to env variables", () => {
  const updates = buildUserConfigUpdates({
    sendTarget: "text_injector",
    sttProvider: "whisper_cpp",
    whisperCppModelPath: "/models/ggml-base.bin",
    whisperCppLanguage: "zh",
    whisperCppThreads: "6",
    whisperCppCommand: "whisper-cli",
    whisperCppExtraArgs: "-fa",
    transcriptDeliveryMode: "confirm_on_device",
    textInjectionMode: "type_and_enter"
  });

  assert.equal(updates.STT_PROVIDER, "whisper_cpp");
  assert.equal(updates.WHISPER_CPP_MODEL_PATH, "/models/ggml-base.bin");
  assert.equal(updates.WHISPER_CPP_LANGUAGE, "zh");
  assert.equal(updates.WHISPER_CPP_THREADS, "6");
  assert.equal(updates.WHISPER_CPP_COMMAND, "whisper-cli");
  assert.equal(updates.WHISPER_CPP_EXTRA_ARGS, "-fa");
});

test("buildUserConfigUpdates maps qwen_asr form values to env variables", () => {
  const updates = buildUserConfigUpdates({
    sendTarget: "text_injector",
    sttProvider: "qwen_asr",
    qwenAsrApiKey: "sk-qwen",
    qwenAsrModel: "qwen3-asr-flash-realtime",
    qwenAsrLanguage: "zh",
    qwenAsrPrompt: "",
    qwenAsrSampleRate: "16000",
    qwenAsrRealtimeBaseUrl: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime",
    transcriptDeliveryMode: "confirm_on_device",
    textInjectionMode: "type_and_enter"
  });

  assert.equal(updates.STT_PROVIDER, "qwen_asr");
  assert.equal(updates.QWEN_ASR_API_KEY, "sk-qwen");
  assert.equal(updates.QWEN_ASR_MODEL, "qwen3-asr-flash-realtime");
  assert.equal(updates.QWEN_ASR_LANGUAGE, "zh");
  assert.equal(updates.QWEN_ASR_PROMPT, null);
  assert.equal(updates.QWEN_ASR_SAMPLE_RATE, "16000");
  assert.equal(updates.QWEN_ASR_REALTIME_BASE_URL, "wss://dashscope.aliyuncs.com/api-ws/v1/realtime");
});

test("resolveSendTarget defaults desktop mode to inject", () => {
  const resolved = resolveSendTarget("", {
    desktopMode: true,
    claudeCommand: "claude",
    codexCommand: "codex"
  });

  assert.deepEqual(resolved, {
    sendTarget: "text_injector",
    sendTargetAuto: false
  });
});

test("resolveSendTarget still preserves explicit desktop mode selection", () => {
  const resolved = resolveSendTarget("codex_exec", {
    desktopMode: true,
    claudeCommand: "claude",
    codexCommand: "codex"
  });

  assert.deepEqual(resolved, {
    sendTarget: "codex_exec",
    sendTargetAuto: false
  });
});

test("desktop mode env limits config search to the user config file", () => {
  const previousDesktopEnv = process.env.VIBE_DESKTOP;

  process.env.VIBE_DESKTOP = "1";
  try {
    const candidates = listConfigFileCandidatesForMode();
    assert.equal(candidates.length, 1);
    assert.match(candidates[0], /config\.env$/);
  } finally {
    if (previousDesktopEnv === undefined) {
      delete process.env.VIBE_DESKTOP;
    } else {
      process.env.VIBE_DESKTOP = previousDesktopEnv;
    }
  }
});
