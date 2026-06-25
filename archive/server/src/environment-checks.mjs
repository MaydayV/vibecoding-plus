import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";

const POSIX_PATH_DIRS = [
  "/opt/homebrew/bin",
  "/opt/homebrew/sbin",
  "/usr/local/bin",
  "/usr/local/sbin",
  "/usr/bin",
  "/bin",
  "/usr/sbin",
  "/sbin",
  path.join(os.homedir(), ".local", "bin"),
  path.join(os.homedir(), ".npm-global", "bin")
];

function splitPath(value) {
  return String(value || "")
    .split(path.delimiter)
    .map((item) => item.trim())
    .filter(Boolean);
}

function uniq(items) {
  return [...new Set(items.filter(Boolean))];
}

export function buildToolPath(basePath = process.env.PATH || "") {
  if (process.platform === "win32") {
    return basePath;
  }
  return uniq([...POSIX_PATH_DIRS, ...splitPath(basePath)]).join(path.delimiter);
}

export function applyToolPath(env = process.env) {
  env.PATH = buildToolPath(env.PATH);
  return env.PATH;
}

function candidateNames(command) {
  if (process.platform !== "win32") {
    return [command];
  }
  const ext = path.extname(command);
  if (ext) {
    return [command];
  }
  const pathext = String(process.env.PATHEXT || ".EXE;.CMD;.BAT;.COM")
    .split(";")
    .filter(Boolean);
  return [command, ...pathext.map((item) => `${command}${item.toLowerCase()}`), ...pathext.map((item) => `${command}${item.toUpperCase()}`)];
}

function isExecutable(filePath) {
  try {
    fs.accessSync(filePath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

export function findExecutable(command, { env = process.env } = {}) {
  const normalized = String(command || "").trim();
  if (!normalized) {
    return "";
  }

  if (path.isAbsolute(normalized) || normalized.includes(path.sep)) {
    return isExecutable(normalized) ? normalized : "";
  }

  for (const dir of splitPath(buildToolPath(env.PATH))) {
    for (const name of candidateNames(normalized)) {
      const candidate = path.join(dir, name);
      if (isExecutable(candidate)) {
        return candidate;
      }
    }
  }

  return "";
}

function execText(command, args = [], { timeoutMs = 4000, env = process.env } = {}) {
  return new Promise((resolve) => {
    execFile(command, args, { timeout: timeoutMs, encoding: "utf8", env: { ...env, PATH: buildToolPath(env.PATH) } }, (error, stdout, stderr) => {
      resolve({
        ok: !error,
        text: String(stdout || stderr || error?.message || "").trim()
      });
    });
  });
}

function firstLine(text) {
  return String(text || "").split(/\r?\n/u).find(Boolean) || "";
}

function normalizeIssueText(text) {
  return String(text || "")
    .replace(/^No STT provider is configured\./u, "未配置语音识别")
    .replace(/ is not set\.$/u, " 未填写")
    .replace(/^Unsupported STT_PROVIDER:/u, "不支持的语音识别提供商：");
}

function providerFromConfig(config) {
  const explicit = String(config.sttProvider || "").trim();
  if (explicit) return explicit;
  if (config.whisperCppModelPath) return "whisper_cpp";
  if (config.qwenAsrModel) return "qwen_asr";
  if (config.openaiApiKey) return "openai";
  if (config.volcengineAppKey || config.volcengineAccessKey) return "volcengine";
  return "";
}

function toolStatus({ id, label, command, purpose, required, installable = true, installLabel = "安装", note = "", versionArgs = ["--version"] }, foundPath, versionText = "") {
  const ok = Boolean(foundPath);
  return {
    id,
    label,
    type: "tool",
    status: ok ? "ok" : required ? "missing" : "optional",
    required: Boolean(required),
    installable: Boolean(installable && !ok),
    installLabel,
    command,
    path: foundPath,
    version: firstLine(versionText),
    purpose,
    note,
    versionArgs
  };
}

export async function getEnvironmentChecks(config, { configIssues = [] } = {}) {
  const env = { ...process.env, PATH: buildToolPath(process.env.PATH) };
  const provider = providerFromConfig(config);
  const sendTarget = String(config.sendTarget || "text_injector");
  const remindersEnabled = Boolean(config.remindersSyncEnabled);

  const commands = {
    brew: "brew",
    npm: "npm",
    remindctl: String(config.remindersRemindctlPath || "remindctl").trim() || "remindctl",
    claude: String(config.claudeCommand || "claude").trim() || "claude",
    codex: String(config.codexCommand || "codex").trim() || "codex",
    whisper: String(config.whisperCppCommand || "whisper-cli").trim() || "whisper-cli"
  };

  const found = Object.fromEntries(
    Object.entries(commands).map(([key, command]) => [key, findExecutable(command, { env })])
  );

  const versionEntries = await Promise.all([
    ["brew", found.brew, ["--version"]],
    ["npm", found.npm, ["--version"]],
    ["remindctl", found.remindctl, ["--version"]],
    ["claude", found.claude, ["--version"]],
    ["codex", found.codex, ["--version"]],
    ["whisper", found.whisper, ["--help"]]
  ].map(async ([key, command, args]) => [key, command ? await execText(command, args, { env }) : { ok: false, text: "" }]));
  const versions = Object.fromEntries(versionEntries);

  const checks = [
    toolStatus({
      id: "brew",
      label: "Homebrew",
      command: commands.brew,
      purpose: "安装 remindctl、whisper.cpp 等 macOS 工具",
      required: false,
      installLabel: "安装 Homebrew",
      note: "没有 Homebrew 时，依赖安装会先打开安装脚本"
    }, found.brew, versions.brew.text),
    toolStatus({
      id: "remindctl",
      label: "remindctl",
      command: commands.remindctl,
      purpose: "苹果提醒事项同步",
      required: remindersEnabled,
      installLabel: "安装 remindctl",
      note: remindersEnabled ? "提醒同步已启用，缺失时同步不可用" : "仅启用苹果提醒同步时需要"
    }, found.remindctl, versions.remindctl.text),
    toolStatus({
      id: "claude",
      label: "Claude Code CLI",
      command: commands.claude,
      purpose: "Claude Code 模式",
      required: sendTarget === "claude_code",
      installLabel: "安装 Claude CLI",
      note: sendTarget === "claude_code" ? "当前发送目标需要 Claude CLI" : "仅 Claude Code 模式需要"
    }, found.claude, versions.claude.text),
    toolStatus({
      id: "codex",
      label: "Codex CLI",
      command: commands.codex,
      purpose: "Codex 模式",
      required: sendTarget === "codex_exec",
      installLabel: "安装 Codex CLI",
      note: sendTarget === "codex_exec" ? "当前发送目标需要 Codex CLI" : "仅 Codex 模式需要"
    }, found.codex, versions.codex.text),
    toolStatus({
      id: "whisper_cpp",
      label: "whisper.cpp",
      command: commands.whisper,
      purpose: "本地 whisper.cpp 语音识别",
      required: provider === "whisper_cpp",
      installLabel: "安装 whisper.cpp",
      note: provider === "whisper_cpp" ? "当前 STT 提供商需要 whisper-cli 和模型文件" : "仅选择 whisper.cpp 时需要"
    }, found.whisper, versions.whisper.text),
    {
      id: "stt_config",
      label: "STT 密钥 / 模型",
      type: "config",
      status: configIssues.length === 0 ? "ok" : "missing",
      required: true,
      installable: false,
      path: config.userConfigPath || "",
      purpose: "语音转文字",
      note: configIssues.length === 0 ? "语音识别配置完整" : configIssues.map(normalizeIssueText).join("；")
    },
    {
      id: "macos_permissions",
      label: "macOS 权限",
      type: "permission",
      status: "optional",
      required: sendTarget === "text_injector",
      installable: false,
      purpose: "输入注入、麦克风、提醒事项访问",
      note: "首次使用时系统会请求权限；输入注入需要在系统设置里允许辅助功能/自动化"
    }
  ];

  return {
    ok: checks.every((item) => item.status !== "missing"),
    path: env.PATH,
    provider,
    sendTarget,
    checks
  };
}

export const INSTALL_TOOL_IDS = new Set(["brew", "remindctl", "claude", "codex", "whisper_cpp"]);

export function getInstallScript(toolId) {
  const brewInstall = String.raw`if ! command -v brew >/dev/null 2>&1; then
  echo "Installing Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi`;

  const scripts = {
    brew: String.raw`set -e
if command -v brew >/dev/null 2>&1; then
  brew --version
  exit 0
fi
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
brew --version`,
    remindctl: `set -e\n${brewInstall}\nbrew install remindctl\nremindctl --version`,
    whisper_cpp: `set -e\n${brewInstall}\nbrew install whisper-cpp\nwhisper-cli --help >/dev/null || true\necho "whisper.cpp installed"`,
    claude: String.raw`set -e
curl -fsSL https://claude.ai/install.sh | bash
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
claude --version`,
    codex: String.raw`set -e
curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
codex --version`
  };

  return scripts[toolId] || "";
}
