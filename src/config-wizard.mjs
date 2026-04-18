import readline from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";

import {
  detectConfiguredSttProvider,
  getConfigIssues,
  hasRequiredConfig,
  loadConfig,
  redactValue,
  writeUserConfigValues
} from "./config.mjs";

class MutedWriter {
  constructor(stream) {
    this.stream = stream;
    this.muted = false;
  }

  get isTTY() {
    return this.stream.isTTY;
  }

  get columns() {
    return this.stream.columns;
  }

  get rows() {
    return this.stream.rows;
  }

  write(chunk, encoding, callback) {
    if (!this.muted) {
      return this.stream.write(chunk, encoding, callback);
    }

    if (typeof callback === "function") {
      callback();
    }

    return true;
  }

  on(eventName, listener) {
    this.stream.on(eventName, listener);
    return this;
  }

  once(eventName, listener) {
    this.stream.once(eventName, listener);
    return this;
  }

  removeListener(eventName, listener) {
    this.stream.removeListener(eventName, listener);
    return this;
  }
}

function createPromptInterface() {
  const mutedOutput = new MutedWriter(output);
  const rl = readline.createInterface({
    input,
    output: mutedOutput,
    terminal: Boolean(input.isTTY && output.isTTY)
  });

  return { rl, mutedOutput };
}

function printWizardIntro(config) {
  const provider = detectConfiguredSttProvider(config) || "not configured";
  const deliveryMode =
    config.transcriptDeliveryMode === "immediate" ? "immediate" : "confirm_on_device";
  const injectionMode =
    config.textInjectionMode === "type_only" ? "type_only" : "type_and_enter";
  const todoIntent =
    config.todoIntentProvider === "deepseek"
      ? `deepseek · ${config.todoIntentModel || "deepseek-chat"}`
      : "rules";
  const overridingFiles = (config.loadedConfigFiles || []).filter((filePath) => filePath !== config.userConfigPath);

  output.write("\nVibe setup\n\n");
  output.write(`Config file: ${config.userConfigPath}\n`);
  output.write(`Current STT provider: ${provider}\n`);
  output.write(`Current transcript delivery: ${deliveryMode}\n`);
  output.write(`Current text injection mode: ${injectionMode}\n`);
  output.write(`Current Todo intent parser: ${todoIntent}\n`);
  output.write("This wizard configures the required STT settings for first use.\n");
  output.write("Required: STT provider + matching API keys\n");
  output.write("Optional: transcript delivery mode, text injection mode, DeepSeek Todo parser, LAN_SHARED_SECRET (only if your board uses LAN auth)\n");
  output.write('Run "vibe config" again anytime to change these values.\n\n');

  if (overridingFiles.length > 0) {
    output.write("Note: a local config file is currently overriding user-level config:\n");
    for (const filePath of overridingFiles) {
      output.write(`  - ${filePath}\n`);
    }
    output.write("\n");
  }
}

function promptSuffix({ defaultValue, allowClear = false, optional = false }) {
  const parts = [];
  if (defaultValue) {
    parts.push("Enter = keep current");
  }
  if (allowClear) {
    parts.push('"-" = clear');
  }
  if (optional && !defaultValue) {
    parts.push("Enter = skip");
  }

  return parts.length ? ` (${parts.join(", ")})` : "";
}

async function askText(rl, label, { defaultValue = "", optional = false, allowClear = false } = {}) {
  while (true) {
    const answer = String(await rl.question(`${label}${promptSuffix({ defaultValue, optional, allowClear })}: `)).trim();

    if (answer === "-" && allowClear) {
      return "";
    }

    if (!answer) {
      if (defaultValue) {
        return defaultValue;
      }
      if (optional) {
        return "";
      }
      output.write("This value is required.\n");
      continue;
    }

    return answer;
  }
}

async function askSecret(rl, mutedOutput, label, { defaultValue = "", optional = false, allowClear = false } = {}) {
  while (true) {
    output.write(`${label}${promptSuffix({ defaultValue, optional, allowClear })}: `);
    mutedOutput.muted = true;
    const answer = String(await rl.question("")).trim();
    mutedOutput.muted = false;
    output.write("\n");

    if (answer === "-" && allowClear) {
      return "";
    }

    if (!answer) {
      if (defaultValue) {
        return defaultValue;
      }
      if (optional) {
        return "";
      }
      output.write("This value is required.\n");
      continue;
    }

    return answer;
  }
}

async function askYesNo(rl, label, defaultYes = true) {
  const hint = defaultYes ? "[Y/n]" : "[y/N]";
  const answer = String(await rl.question(`${label} ${hint}: `)).trim().toLowerCase();
  if (!answer) {
    return defaultYes;
  }
  return answer === "y" || answer === "yes";
}

async function askProvider(rl, currentProvider) {
  const defaultOption =
    currentProvider === "openai"
      ? "2"
      : currentProvider === "whisper_cpp"
        ? "3"
        : currentProvider === "qwen_asr"
          ? "4"
          : "1";

  while (true) {
    output.write("Choose your STT provider:\n");
    output.write("  1. Volcengine (VOLCENGINE_APP_KEY + VOLCENGINE_ACCESS_KEY)\n");
    output.write("  2. OpenAI (OPENAI_API_KEY)\n");
    output.write("  3. whisper.cpp local (WHISPER_CPP_MODEL_PATH)\n");
    output.write("  4. Qwen3-ASR realtime WebSocket (official online API)\n");
    const answer = String(await rl.question(`Selection [${defaultOption}]: `)).trim();
    const selection = answer || defaultOption;

    if (selection === "1" || selection.toLowerCase() === "volcengine") {
      return "volcengine";
    }
    if (selection === "2" || selection.toLowerCase() === "openai") {
      return "openai";
    }
    if (selection === "3" || selection.toLowerCase() === "whisper_cpp") {
      return "whisper_cpp";
    }
    if (selection === "4" || selection.toLowerCase() === "qwen_asr") {
      return "qwen_asr";
    }

    output.write("Please choose 1, 2, 3, or 4.\n");
  }
}

async function askTranscriptDeliveryMode(rl, currentMode) {
  const defaultOption = currentMode === "immediate" ? "2" : "1";

  while (true) {
    output.write("Choose transcript delivery mode:\n");
    output.write("  1. Confirm on device (recommended) — keep transcript on the board, UP sends, DN undoes\n");
    output.write("  2. Immediate — send as soon as each recording segment is transcribed\n");
    const answer = String(await rl.question(`Selection [${defaultOption}]: `)).trim();
    const selection = answer || defaultOption;

    if (selection === "1" || selection.toLowerCase() === "confirm_on_device") {
      return "confirm_on_device";
    }
    if (selection === "2" || selection.toLowerCase() === "immediate") {
      return "immediate";
    }

    output.write("Please choose 1 or 2.\n");
  }
}

async function askTextInjectionMode(rl, currentMode) {
  const defaultOption = currentMode === "type_only" ? "2" : "1";

  while (true) {
    output.write("Choose text injection mode (used by plain `vibe` / inject mode):\n");
    output.write("  1. Type and press Enter (recommended)\n");
    output.write("  2. Type only\n");
    const answer = String(await rl.question(`Selection [${defaultOption}]: `)).trim();
    const selection = answer || defaultOption;

    if (selection === "1" || selection.toLowerCase() === "type_and_enter") {
      return "type_and_enter";
    }
    if (selection === "2" || selection.toLowerCase() === "type_only") {
      return "type_only";
    }

    output.write("Please choose 1 or 2.\n");
  }
}

async function askTodoIntentMode(rl, currentProvider) {
  const defaultYes = currentProvider === "deepseek";
  return await askYesNo(rl, "Enable DeepSeek Todo semantic parser?", defaultYes);
}

export async function runConfigWizard() {
  if (!input.isTTY || !output.isTTY) {
    throw new Error('Interactive setup requires a TTY. Run "vibe config" in a terminal.');
  }

  const currentConfig = loadConfig({ quietMissing: true });
  const currentProvider = detectConfiguredSttProvider(currentConfig) || "volcengine";
  const currentDeliveryMode =
    currentConfig.transcriptDeliveryMode === "immediate" ? "immediate" : "confirm_on_device";
  const currentTextInjectionMode =
    currentConfig.textInjectionMode === "type_only" ? "type_only" : "type_and_enter";
  const currentTodoIntentProvider = currentConfig.todoIntentProvider === "deepseek" ? "deepseek" : "rules";

  printWizardIntro(currentConfig);

  const { rl, mutedOutput } = createPromptInterface();

  try {
    const provider = await askProvider(rl, currentProvider);
    const updates = {
      STT_PROVIDER: provider
    };

    if (provider === "volcengine") {
      updates.VOLCENGINE_APP_KEY = await askSecret(rl, mutedOutput, "VOLCENGINE_APP_KEY", {
        defaultValue: currentConfig.volcengineAppKey
      });
      updates.VOLCENGINE_ACCESS_KEY = await askSecret(rl, mutedOutput, "VOLCENGINE_ACCESS_KEY", {
        defaultValue: currentConfig.volcengineAccessKey
      });
      updates.VOLCENGINE_RESOURCE_ID = await askText(rl, "VOLCENGINE_RESOURCE_ID", {
        defaultValue: currentConfig.volcengineResourceId || "volc.bigasr.auc_turbo"
      });
      updates.VOLCENGINE_LANGUAGE = await askText(rl, "VOLCENGINE_LANGUAGE", {
        defaultValue: currentConfig.volcengineLanguage || "zh-CN"
      });
    } else if (provider === "openai") {
      updates.OPENAI_API_KEY = await askSecret(rl, mutedOutput, "OPENAI_API_KEY", {
        defaultValue: currentConfig.openaiApiKey
      });
      updates.OPENAI_TRANSCRIBE_MODEL = await askText(rl, "OPENAI_TRANSCRIBE_MODEL", {
        defaultValue: currentConfig.openaiModel || "whisper-1"
      });
      updates.OPENAI_TRANSCRIBE_LANGUAGE = await askText(rl, "OPENAI_TRANSCRIBE_LANGUAGE", {
        defaultValue: currentConfig.openaiLanguage,
        optional: true,
        allowClear: true
      });
    } else if (provider === "whisper_cpp") {
      updates.WHISPER_CPP_MODEL_PATH = await askText(rl, "WHISPER_CPP_MODEL_PATH", {
        defaultValue: currentConfig.whisperCppModelPath,
        optional: false
      });
      updates.WHISPER_CPP_LANGUAGE = await askText(rl, "WHISPER_CPP_LANGUAGE", {
        defaultValue: currentConfig.whisperCppLanguage || "zh"
      });
      updates.WHISPER_CPP_THREADS = await askText(rl, "WHISPER_CPP_THREADS", {
        defaultValue: String(currentConfig.whisperCppThreads || 4)
      });
      updates.WHISPER_CPP_COMMAND = await askText(rl, "WHISPER_CPP_COMMAND", {
        defaultValue: currentConfig.whisperCppCommand || "whisper-cli"
      });
      updates.WHISPER_CPP_EXTRA_ARGS = await askText(rl, "WHISPER_CPP_EXTRA_ARGS", {
        defaultValue: currentConfig.whisperCppExtraArgs,
        optional: true,
        allowClear: true
      });
    } else {
      updates.QWEN_ASR_MODEL = await askText(rl, "QWEN_ASR_MODEL", {
        defaultValue: currentConfig.qwenAsrModel || "qwen3-asr-flash-realtime"
      });
      updates.QWEN_ASR_API_KEY = await askSecret(rl, mutedOutput, "QWEN_ASR_API_KEY (or DASHSCOPE_API_KEY)", {
        defaultValue: currentConfig.qwenAsrApiKey
      });
      updates.QWEN_ASR_REALTIME_BASE_URL = await askText(rl, "QWEN_ASR_REALTIME_BASE_URL", {
        defaultValue: currentConfig.qwenAsrRealtimeBaseUrl || "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
      });
      updates.QWEN_ASR_SAMPLE_RATE = await askText(rl, "QWEN_ASR_SAMPLE_RATE", {
        defaultValue: String(currentConfig.qwenAsrSampleRate || 16000)
      });
      updates.QWEN_ASR_LANGUAGE = await askText(rl, "QWEN_ASR_LANGUAGE", {
        defaultValue: currentConfig.qwenAsrLanguage || "zh"
      });
      updates.QWEN_ASR_PROMPT = await askText(rl, "QWEN_ASR_PROMPT", {
        defaultValue: currentConfig.qwenAsrPrompt,
        optional: true,
        allowClear: true
      });
      updates.QWEN_ASR_TIMEOUT_MS = await askText(rl, "QWEN_ASR_TIMEOUT_MS", {
        defaultValue: String(currentConfig.qwenAsrTimeoutMs || 45000)
      });
    }

    updates.TRANSCRIPT_DELIVERY_MODE = await askTranscriptDeliveryMode(rl, currentDeliveryMode);
    updates.TEXT_INJECTION_MODE = await askTextInjectionMode(rl, currentTextInjectionMode);

    if (await askTodoIntentMode(rl, currentTodoIntentProvider)) {
      updates.TODO_INTENT_PROVIDER = "deepseek";
      updates.TODO_INTENT_API_KEY = await askSecret(rl, mutedOutput, "TODO_INTENT_API_KEY (DeepSeek)", {
        defaultValue: currentConfig.todoIntentApiKey
      });
      updates.TODO_INTENT_MODEL = await askText(rl, "TODO_INTENT_MODEL", {
        defaultValue: currentConfig.todoIntentModel || "deepseek-chat"
      });
      updates.TODO_INTENT_BASE_URL = await askText(rl, "TODO_INTENT_BASE_URL", {
        defaultValue: currentConfig.todoIntentBaseUrl || "https://api.deepseek.com"
      });
    } else {
      updates.TODO_INTENT_PROVIDER = "rules";
    }
    updates.TODO_FOLLOWUP_TIMEOUT_MS = await askText(rl, "TODO_FOLLOWUP_TIMEOUT_MS", {
      defaultValue: String(currentConfig.todoFollowupTimeoutMs || 30000)
    });

    updates.LAN_SHARED_SECRET = await askSecret(rl, mutedOutput, "LAN_SHARED_SECRET", {
      defaultValue: currentConfig.lanSharedSecret,
      optional: true,
      allowClear: true
    });

    output.write("\nSummary\n");
    output.write(`  STT_PROVIDER=${provider}\n`);
    if (provider === "volcengine") {
      output.write(`  VOLCENGINE_APP_KEY=${redactValue(updates.VOLCENGINE_APP_KEY)}\n`);
      output.write(`  VOLCENGINE_ACCESS_KEY=${redactValue(updates.VOLCENGINE_ACCESS_KEY)}\n`);
      output.write(`  VOLCENGINE_RESOURCE_ID=${updates.VOLCENGINE_RESOURCE_ID}\n`);
      output.write(`  VOLCENGINE_LANGUAGE=${updates.VOLCENGINE_LANGUAGE}\n`);
    } else if (provider === "openai") {
      output.write(`  OPENAI_API_KEY=${redactValue(updates.OPENAI_API_KEY)}\n`);
      output.write(`  OPENAI_TRANSCRIBE_MODEL=${updates.OPENAI_TRANSCRIBE_MODEL}\n`);
      output.write(`  OPENAI_TRANSCRIBE_LANGUAGE=${updates.OPENAI_TRANSCRIBE_LANGUAGE || "(auto)"}\n`);
    } else if (provider === "whisper_cpp") {
      output.write(`  WHISPER_CPP_MODEL_PATH=${updates.WHISPER_CPP_MODEL_PATH}\n`);
      output.write(`  WHISPER_CPP_LANGUAGE=${updates.WHISPER_CPP_LANGUAGE}\n`);
      output.write(`  WHISPER_CPP_THREADS=${updates.WHISPER_CPP_THREADS}\n`);
      output.write(`  WHISPER_CPP_COMMAND=${updates.WHISPER_CPP_COMMAND}\n`);
      output.write(`  WHISPER_CPP_EXTRA_ARGS=${updates.WHISPER_CPP_EXTRA_ARGS || "(none)"}\n`);
    } else {
      output.write(`  QWEN_ASR_MODEL=${updates.QWEN_ASR_MODEL}\n`);
      output.write(`  QWEN_ASR_API_KEY=${redactValue(updates.QWEN_ASR_API_KEY)}\n`);
      output.write(`  QWEN_ASR_REALTIME_BASE_URL=${updates.QWEN_ASR_REALTIME_BASE_URL}\n`);
      output.write(`  QWEN_ASR_SAMPLE_RATE=${updates.QWEN_ASR_SAMPLE_RATE}\n`);
      output.write(`  QWEN_ASR_LANGUAGE=${updates.QWEN_ASR_LANGUAGE}\n`);
      output.write(`  QWEN_ASR_PROMPT=${updates.QWEN_ASR_PROMPT || "(none)"}\n`);
      output.write(`  QWEN_ASR_TIMEOUT_MS=${updates.QWEN_ASR_TIMEOUT_MS}\n`);
    }

    output.write(`  TRANSCRIPT_DELIVERY_MODE=${updates.TRANSCRIPT_DELIVERY_MODE}\n`);
    output.write(`  TEXT_INJECTION_MODE=${updates.TEXT_INJECTION_MODE}\n`);
    output.write(`  TODO_INTENT_PROVIDER=${updates.TODO_INTENT_PROVIDER}\n`);
    if (updates.TODO_INTENT_PROVIDER === "deepseek") {
      output.write(`  TODO_INTENT_API_KEY=${redactValue(updates.TODO_INTENT_API_KEY)}\n`);
      output.write(`  TODO_INTENT_MODEL=${updates.TODO_INTENT_MODEL}\n`);
      output.write(`  TODO_INTENT_BASE_URL=${updates.TODO_INTENT_BASE_URL}\n`);
    }
    output.write(`  TODO_FOLLOWUP_TIMEOUT_MS=${updates.TODO_FOLLOWUP_TIMEOUT_MS}\n`);
    output.write(`  LAN_SHARED_SECRET=${redactValue(updates.LAN_SHARED_SECRET)}\n\n`);

    const shouldSave = await askYesNo(rl, `Save these values to ${currentConfig.userConfigPath}?`, true);
    if (!shouldSave) {
      output.write("Setup cancelled.\n");
      return { saved: false, userConfigPath: currentConfig.userConfigPath };
    }

    const userConfigPath = writeUserConfigValues(updates);
    output.write(`Saved config to ${userConfigPath}\n`);
    const overridingFiles = (currentConfig.loadedConfigFiles || []).filter((filePath) => filePath !== currentConfig.userConfigPath);
    if (overridingFiles.length > 0) {
      output.write("A local .env file still has higher priority than this user config.\n");
    }
    output.write("Restart vibe if it is already running.\n");
    return { saved: true, userConfigPath };
  } finally {
    rl.close();
  }
}

export async function ensureConfigReadyInteractive() {
  const config = loadConfig({ quietMissing: true });
  if (hasRequiredConfig(config)) {
    return { ready: true, configuredNow: false, config };
  }

  const issues = getConfigIssues(config);
  output.write("\nVibe needs STT configuration before first use.\n");
  for (const issue of issues) {
    output.write(`- ${issue}\n`);
  }
  output.write(`Config file location: ${config.userConfigPath}\n`);

  if (!input.isTTY || !output.isTTY) {
    throw new Error(`Missing configuration. Run "vibe config" to create ${config.userConfigPath}.`);
  }

  const { rl } = createPromptInterface();
  try {
    const shouldConfigure = await askYesNo(rl, "Launch setup now?", true);
    if (!shouldConfigure) {
      throw new Error(`Missing configuration. Run "vibe config" to create ${config.userConfigPath}.`);
    }
  } finally {
    rl.close();
  }

  const result = await runConfigWizard();
  if (!result.saved) {
    throw new Error("Missing configuration. Run \"vibe config\" to finish setup.");
  }

  const refreshedConfig = loadConfig({ quietMissing: true });
  const refreshedIssues = getConfigIssues(refreshedConfig);
  if (refreshedIssues.length > 0) {
    throw new Error(`Configuration is still incomplete: ${refreshedIssues.join(" ")}`);
  }

  return { ready: true, configuredNow: true, config: refreshedConfig };
}
