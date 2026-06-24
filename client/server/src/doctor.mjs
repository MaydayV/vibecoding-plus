import { createServer } from "node:net";
import { getEnvironmentChecks } from "./environment-checks.mjs";

function ok(label) {
  console.log(`  \x1b[32m[✓]\x1b[0m ${label}`);
}

function fail(label) {
  console.log(`  \x1b[31m[✗]\x1b[0m ${label}`);
}

function warn(label) {
  console.log(`  \x1b[33m[~]\x1b[0m ${label}`);
}

function checkPort(port) {
  return new Promise((resolve) => {
    const server = createServer();
    server.once("error", () => resolve(false));
    server.once("listening", () => server.close(() => resolve(true)));
    server.listen(port, "127.0.0.1");
  });
}

function resolveSttLabel(config) {
  if (config.mockTranscript) {
    return { label: "mock (MOCK_TRANSCRIPT set)", valid: true };
  }
  const provider =
    config.sttProvider ||
    (config.qwenAsrModel
      ? "qwen_asr"
      : config.whisperCppModelPath
        ? "whisper_cpp"
        : config.openaiApiKey
          ? "openai"
          : config.volcengineAppKey
            ? "volcengine"
            : "");
  if (provider === "qwen_asr") {
    if (!String(config.qwenAsrModel || "").trim()) {
      return { label: "qwen_asr — QWEN_ASR_MODEL missing", valid: false };
    }
    if (!String(config.qwenAsrApiKey || "").trim()) {
      return { label: "qwen_asr — QWEN_ASR_API_KEY missing", valid: false };
    }
    if (!String(config.qwenAsrRealtimeBaseUrl || "").trim()) {
      return { label: "qwen_asr — QWEN_ASR_REALTIME_BASE_URL missing", valid: false };
    }
    return { label: `qwen_asr · realtime_ws · ${config.qwenAsrModel}`, valid: true };
  }
  if (provider === "openai") {
    return config.openaiApiKey
      ? { label: `openai · ${config.openaiModel}`, valid: true }
      : { label: "openai — OPENAI_API_KEY missing", valid: false };
  }
  if (provider === "volcengine") {
    const keysOk = config.volcengineAppKey && config.volcengineAccessKey;
    return keysOk
      ? { label: `volcengine · ${config.volcengineLanguage}`, valid: true }
      : { label: "volcengine — VOLCENGINE_APP_KEY or VOLCENGINE_ACCESS_KEY missing", valid: false };
  }
  if (provider === "whisper_cpp") {
    if (!config.whisperCppModelPath) {
      return { label: "whisper_cpp — WHISPER_CPP_MODEL_PATH missing", valid: false };
    }
    const command = String(config.whisperCppCommand || "whisper-cli").trim() || "whisper-cli";
    if (!isCliAvailable(command)) {
      return { label: `whisper_cpp — command not found: ${command}`, valid: false };
    }
    return { label: `whisper_cpp · ${config.whisperCppLanguage}`, valid: true };
  }
  return {
    label: "none — set QWEN_ASR_MODEL, OPENAI_API_KEY, VOLCENGINE_APP_KEY + VOLCENGINE_ACCESS_KEY, or WHISPER_CPP_MODEL_PATH",
    valid: false
  };
}

function resolveTodoIntentLabel(config) {
  if (config.todoIntentProvider !== "deepseek") {
    return { label: "rules", valid: true };
  }
  return config.todoIntentApiKey
    ? { label: `deepseek · ${config.todoIntentModel}`, valid: true }
    : { label: "deepseek — TODO_INTENT_API_KEY missing", valid: false };
}

export async function runDoctor(config) {
  console.log("\nvibecoding-plus doctor\n");

  let hasError = false;

  if (config.loadedConfigFiles?.length) {
    ok(`config loaded from: ${config.loadedConfigFiles.join(", ")}`);
  } else {
    warn(`no config file loaded — run "vibe config" to create ${config.userConfigPath}`);
  }

  // STT provider
  const stt = resolveSttLabel(config);
  if (stt.valid) {
    ok(`STT: ${stt.label}`);
  } else {
    fail(`STT: ${stt.label}`);
    hasError = true;
  }

  const todoIntent = resolveTodoIntentLabel(config);
  if (todoIntent.valid) {
    ok(`Todo intent: ${todoIntent.label}`);
  } else {
    warn(`Todo intent: ${todoIntent.label}`);
  }

  const environment = await getEnvironmentChecks(config, { configIssues: [] });
  const missingRequiredTools = environment.checks.filter((item) => item.type === "tool" && item.required && item.status === "missing");

  for (const item of environment.checks.filter((entry) => entry.type === "tool")) {
    if (item.status === "ok") {
      ok(`${item.label}: ${item.path}${item.version ? ` (${item.version})` : ""}`);
    } else if (item.required) {
      fail(`${item.label}: not found — ${item.note || item.purpose}`);
      hasError = true;
    } else {
      warn(`${item.label}: not found — ${item.note || item.purpose}`);
    }
  }

  if (missingRequiredTools.length > 0) {
    warn(`missing required desktop tools: ${missingRequiredTools.map((item) => item.id).join(", ")}`);
  }

  // Ports
  const wsAvailable = await checkPort(config.port);
  if (wsAvailable) {
    ok(`port ${config.port} available (WebSocket)`);
  } else {
    fail(`port ${config.port} in use — set LAN_VOICE_PORT to a free port`);
    hasError = true;
  }

  if (config.discoveryEnabled) {
    const udpAvailable = await checkPort(config.discoveryPort);
    if (udpAvailable) {
      ok(`port ${config.discoveryPort} available (UDP discovery)`);
    } else {
      warn(`port ${config.discoveryPort} may be in use (UDP discovery) — set LAN_DISCOVERY_PORT or LAN_DISCOVERY_ENABLED=0`);
    }
  }

  // Summary
  const autoNote = config.sendTargetAuto ? " [auto-detected]" : "";
  console.log(`\n  Target: \x1b[1m${config.sendTarget}\x1b[0m${autoNote}`);
  console.log(`  Delivery: \x1b[1m${config.transcriptDeliveryMode}\x1b[0m`);
  console.log(`  Inject: \x1b[1m${config.textInjectionMode}\x1b[0m`);
  if (hasError) {
    console.log('  \x1b[31mSome checks failed — fix the issues above before starting. Run "vibe config" if needed.\x1b[0m\n');
    process.exit(1);
  } else {
    console.log("  \x1b[32mAll checks passed.\x1b[0m\n");
    process.exit(0);
  }
}
