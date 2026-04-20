import { execFileSync } from "node:child_process";
import fs from "node:fs";
import { createServer } from "node:http";
import os from "node:os";
import path from "node:path";


import { WebSocketServer, WebSocket } from "ws";

import { createCliView, formatCodexEvent, pushLogLine, summarizeAssistantText } from "./cli-projector.mjs";
import { readLatestRateLimits } from "./codex-rate-limits.mjs";
import { readLatestClaudeRateLimits } from "./claude-rate-limits.mjs";
import { loadConfig } from "./config.mjs";
import { runDoctor } from "./doctor.mjs";
import { startDiscoveryServer } from "./discovery-server.mjs";
import { isFreshTimestamp, signHelloPayload, signaturesMatch } from "./lan-auth.mjs";
import { getUserTodoListPath } from "./paths.mjs";
import { ClaudeSessionManager } from "./claude-session.mjs";
import { CodexSessionManager } from "./codex-session.mjs";
import { transcribePcm16Mono } from "./stt.mjs";
import { createTodoAssistant } from "./todo-assistant.mjs";
import { createTodoService, VALID_VOICE_MODES } from "./todo-service.mjs";
import { createAdminRoutes } from "./admin-routes.mjs";
import { injectText, undoLastInput } from "./text-injector.mjs";


const config = loadConfig();

if (process.argv.includes("--doctor")) {
  await runDoctor(config);
}

const codexSession = new CodexSessionManager(config);
const claudeSession = new ClaudeSessionManager(config);
const cliView = createCliView(config);
const todoService = createTodoService({ storagePath: getUserTodoListPath() });
const todoAssistant = createTodoAssistant(config);
const recentHelloNonces = new Map();
applyRateLimitSnapshot(readLatestRateLimits());

const MIN_PLAUSIBLE_EPOCH_MS = Date.UTC(2020, 0, 1);
const VALID_SEND_TARGETS = new Set(["text_injector", "codex_exec", "claude_code"]);

const MAX_PLAN_OPTIONS = 8;
const LOCALHOST_REMOTE_ADDRESSES = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"]);
const TODO_PENDING_INTENTS_PATH = path.join(path.dirname(getUserTodoListPath()), "todo-pending-intents.json");
const PCM_SAMPLE_RATE = 16000;
const PCM_BYTES_PER_SAMPLE = 2;
const DISPLAY_REPO_NAME = "vibecoding-plus";

let cliDispatchLock = Promise.resolve();
let cliLogTailFlushTimer = null;
let terminalMirrorPollTimer = null;
let terminalMirrorLastSnapshot = "";
let terminalMirrorLastError = "";
let terminalMirrorPaneTargetsCache = {
  expiresAt: 0,
  targets: []
};
const pendingTodoIntentByDevice = loadPendingTodoIntentByDevice();

function loadPendingTodoIntentByDevice() {
  try {
    if (!fs.existsSync(TODO_PENDING_INTENTS_PATH)) {
      return new Map();
    }
    const parsed = JSON.parse(fs.readFileSync(TODO_PENDING_INTENTS_PATH, "utf8"));
    if (!parsed || typeof parsed !== "object") {
      return new Map();
    }
    const entries = Object.entries(parsed)
      .filter(([deviceId, entry]) => {
        if (!deviceId || !entry || typeof entry !== "object") {
          return false;
        }
        if (!entry.pendingIntent || typeof entry.pendingIntent !== "object") {
          return false;
        }
        const expiresAt = Number(entry.expiresAt);
        return Number.isFinite(expiresAt) && expiresAt > Date.now();
      })
      .map(([deviceId, entry]) => [deviceId, entry]);
    return new Map(entries);
  } catch {
    return new Map();
  }
}

function persistPendingTodoIntentByDevice() {
  try {
    const now = Date.now();
    const payload = {};
    for (const [deviceId, entry] of pendingTodoIntentByDevice.entries()) {
      if (!deviceId || !entry || typeof entry !== "object") {
        continue;
      }
      if (!entry.pendingIntent || typeof entry.pendingIntent !== "object") {
        continue;
      }
      const expiresAt = Number(entry.expiresAt);
      if (!Number.isFinite(expiresAt) || expiresAt <= now) {
        continue;
      }
      payload[deviceId] = {
        pendingIntent: entry.pendingIntent,
        expiresAt
      };
    }
    fs.mkdirSync(path.dirname(TODO_PENDING_INTENTS_PATH), { recursive: true });
    fs.writeFileSync(TODO_PENDING_INTENTS_PATH, `${JSON.stringify(payload)}\n`, "utf8");
  } catch {
    // ignore
  }
}

function isWsReadyForJson(ws) {
  return Boolean(ws && ws.readyState === WebSocket.OPEN);
}

function sendJsonIfOpen(ws, payload) {
  if (!isWsReadyForJson(ws)) {
    return false;
  }
  try {
    ws.send(JSON.stringify(payload));
    return true;
  } catch {
    return false;
  }
}

function restorePendingTodoIntentForState(state) {
  if (!state) {
    return;
  }
  const deviceId = String(state.deviceId || "").trim();
  if (!deviceId) {
    return;
  }
  const entry = pendingTodoIntentByDevice.get(deviceId);
  if (!entry) {
    return;
  }
  const expiresAt = Number(entry.expiresAt);
  if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) {
    pendingTodoIntentByDevice.delete(deviceId);
    persistPendingTodoIntentByDevice();
    return;
  }
  state.pendingTodoIntent = entry.pendingIntent;
  state.pendingTodoIntentExpiresAt = expiresAt;
}

function queueCliDispatch(task) {
  const run = async () => {
    try {
      return await task();
    } catch (error) {
      throw error;
    }
  };
  const next = cliDispatchLock.then(run, run);
  cliDispatchLock = next.then(() => undefined, () => undefined);
  return next;
}

function scheduleCliLogTailFlush() {
  if (cliLogTailFlushTimer) {
    return;
  }
  const delayMs = Math.max(100, Number(config.terminalMirrorIntervalMs) || 800);
  cliLogTailFlushTimer = setTimeout(() => {
    cliLogTailFlushTimer = null;
    broadcastJson({
      type: "cli_log_tail",
      lines: cliView.logLines
    });
  }, delayMs);
  cliLogTailFlushTimer.unref?.();
}


function toClaudeProjectSlug(cwdPath) {
  const resolved = path.resolve(String(cwdPath || process.cwd()));
  const slug = resolved.replace(/[\\/]+/g, "-");
  return slug.startsWith("-") ? slug : `-${slug}`;
}

const CLAUDE_PROJECT_TRANSCRIPTS_DIR = path.join(
  os.homedir(),
  ".claude",
  "projects",
  toClaudeProjectSlug(config.claudeCwd || process.cwd())
);
const CLAUDE_TRANSCRIPT_MAX_AGE_MS = 30 * 60 * 1000;

function parseTerminalMirrorTargets(rawValue) {
  const text = String(rawValue || "").trim();
  if (!text) {
    return [];
  }
  return text
    .split(",")
    .map((part) => String(part || "").trim())
    .filter(Boolean)
    .map((target) => {
      const separatorIndex = target.lastIndexOf(":");
      if (separatorIndex <= 0 || separatorIndex === target.length - 1) {
        return null;
      }
      const session = target.slice(0, separatorIndex).trim();
      const window = target.slice(separatorIndex + 1).trim();
      if (!session || !window) {
        return null;
      }
      return { session, window };
    })
    .filter(Boolean);
}

function shouldUseTmuxMirror() {
  return Boolean(
    parseTerminalMirrorTargets(config.terminalMirrorTargets).length > 0 ||
      (config.terminalMirrorSession && config.terminalMirrorWindow)
  );
}

function getLatestClaudeTranscriptFile() {
  if (!fs.existsSync(CLAUDE_PROJECT_TRANSCRIPTS_DIR)) {
    return "";
  }

  const candidates = fs
    .readdirSync(CLAUDE_PROJECT_TRANSCRIPTS_DIR, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".jsonl"))
    .map((entry) => path.join(CLAUDE_PROJECT_TRANSCRIPTS_DIR, entry.name));

  if (candidates.length === 0) {
    return "";
  }

  candidates.sort((left, right) => {
    const leftMtime = fs.statSync(left).mtimeMs;
    const rightMtime = fs.statSync(right).mtimeMs;
    return rightMtime - leftMtime;
  });

  const newest = candidates[0];
  const ageMs = Date.now() - fs.statSync(newest).mtimeMs;
  if (ageMs > CLAUDE_TRANSCRIPT_MAX_AGE_MS) {
    return "";
  }
  return newest;
}

function extractTextFromClaudeMessageContent(content) {
  if (!Array.isArray(content)) {
    return "";
  }
  const pieces = [];
  for (const block of content) {
    if (!block || typeof block !== "object") {
      continue;
    }
    if (block.type === "text" && block.text) {
      pieces.push(String(block.text));
    }
    if (block.type === "tool_result" && typeof block.content === "string") {
      pieces.push(String(block.content));
    }
  }
  return pieces.join("\n").trim();
}

function readClaudeTranscriptSnapshot() {
  const transcriptPath = getLatestClaudeTranscriptFile();
  if (!transcriptPath) {
    return { text: "", userText: "", statusLine: "Claude mirror unavailable" };
  }

  const raw = fs.readFileSync(transcriptPath, "utf8");
  const lines = raw.split(/\r?\n/).filter(Boolean);
  const recent = lines.slice(-200);

  let latestUserText = "";
  let latestAssistantText = "";
  const tailLines = [];

  for (const line of recent) {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }

    if (event.type === "user") {
      const text = extractTextFromClaudeMessageContent(event?.message?.content);
      if (text) {
        latestUserText = text;
        tailLines.push(`user: ${text}`);
      }
      continue;
    }

    if (event.type === "assistant") {
      const text = extractTextFromClaudeMessageContent(event?.message?.content);
      if (text) {
        latestAssistantText = text;
        tailLines.push(`assistant: ${text}`);
      }
    }
  }

  const snapshotText = tailLines.slice(-Math.max(8, Number(config.terminalMirrorLines) || 60)).join("\n");
  return {
    text: snapshotText,
    userText: latestUserText,
    assistantText: latestAssistantText,
    statusLine: `Claude mirror ${path.basename(transcriptPath)}`
  };
}

function getTerminalMirrorPaneTargets() {
  const now = Date.now();
  if (terminalMirrorPaneTargetsCache.expiresAt > now && terminalMirrorPaneTargetsCache.targets.length > 0) {
    return terminalMirrorPaneTargetsCache.targets;
  }

  const targets = [];
  const pushTarget = (session, window) => {
    const normalizedSession = String(session || "").trim();
    const normalizedWindow = String(window || "").trim();
    if (!normalizedSession || !normalizedWindow) {
      return;
    }
    const exists = targets.some((item) => item.session === normalizedSession && item.window === normalizedWindow);
    if (!exists) {
      targets.push({ session: normalizedSession, window: normalizedWindow });
    }
  };

  const configuredTargets = parseTerminalMirrorTargets(config.terminalMirrorTargets);
  for (const item of configuredTargets) {
    pushTarget(item.session, item.window);
  }

  pushTarget(config.terminalMirrorSession, config.terminalMirrorWindow);

  let activeSession = "";
  let activeWindow = "";
  try {
    activeSession = String(
      execFileSync("tmux", ["display-message", "-p", "#{session_name}"], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"]
      })
    ).trim();
    activeWindow = String(
      execFileSync("tmux", ["display-message", "-p", "#{window_name}"], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"]
      })
    ).trim();
  } catch {
    // ignore
  }

  pushTarget(activeSession, activeWindow);

  try {
    const listOutput = String(
      execFileSync("tmux", ["list-windows", "-a", "-F", "#{session_name}:#{window_name}"], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"]
      })
    );
    for (const line of listOutput.split(/\r?\n/)) {
      const pair = String(line || "").trim();
      if (!pair) {
        continue;
      }
      const separatorIndex = pair.lastIndexOf(":");
      if (separatorIndex <= 0 || separatorIndex === pair.length - 1) {
        continue;
      }
      const session = pair.slice(0, separatorIndex).trim();
      const window = pair.slice(separatorIndex + 1).trim();
      pushTarget(session, window);
    }
  } catch {
    // ignore
  }

  terminalMirrorPaneTargetsCache = {
    expiresAt: now + 60_000,
    targets
  };
  return terminalMirrorPaneTargetsCache.targets;
}


function readTmuxPaneLines(session, window, lines) {
  return String(
    execFileSync(
      "tmux",
      [
        "capture-pane",
        "-pt",
        `${session}:${window}`,
        "-S",
        `-${Math.max(20, Math.min(400, Number(lines) || 60))}`,
        "-J"
      ],
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"]
      }
    ) || ""
  );
}

function normalizeTerminalSnapshot(text) {
  return String(text || "")
    .replace(/\u001b\[[0-9;]*[A-Za-z]/g, "")
    .replace(/\r/g, "")
    .split("\n")
    .map((line) => line.replace(/\s+/g, " ").trim())
    .filter(Boolean)
    .join("\n")
    .trim();
}

function extractLatestTerminalUserPrompt(text) {
  const lines = String(text || "")
    .split(/\r?\n/)
    .map((line) => String(line || "").trim())
    .filter(Boolean);

  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index];
    if (/^(?:you|用户|我)\s*[:：]\s+/iu.test(line)) {
      return line.replace(/^(?:you|用户|我)\s*[:：]\s+/iu, "").trim();
    }
    if (/^user\s*[:：]\s+/iu.test(line)) {
      return line.replace(/^user\s*[:：]\s+/iu, "").trim();
    }
  }

  return "";
}

function extractLatestTerminalAssistantReply(text) {
  const lines = String(text || "")
    .split(/\r?\n/)
    .map((line) => String(line || "").trim())
    .filter(Boolean);

  const assistantMarkers = [
    /^assistant\s*[:：]\s+/iu,
    /^claude\s*[:：]\s+/iu,
    /^回复\s*[:：]\s+/iu
  ];

  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index];
    for (const marker of assistantMarkers) {
      if (marker.test(line)) {
        return line.replace(marker, "").trim();
      }
    }
  }

  const tail = lines.slice(-8).join("\n").trim();
  return summarizeAssistantText(tail);
}

function updateCliSummaryFromTerminalSnapshot(snapshot, sourceTarget) {
  const normalized = normalizeTerminalSnapshot(snapshot);
  if (!normalized || normalized === terminalMirrorLastSnapshot) {
    return;
  }

  terminalMirrorLastSnapshot = normalized;
  const userText = extractLatestTerminalUserPrompt(normalized);
  const assistantText = extractLatestTerminalAssistantReply(normalized);

  if (userText) {
    cliView.latestUserText = summarizeAssistantText(userText);
  }
  if (assistantText) {
    cliView.latestAssistantText = summarizeAssistantText(assistantText);
  }
  cliView.statusLine = sourceTarget ? `${sourceTarget} mirror` : "Terminal mirror";

  const mirrorLines = normalized
    .split("\n")
    .slice(-Math.max(8, Number(config.terminalMirrorLines) || 60));

  for (const line of mirrorLines) {
    cliView.logLines = pushLogLine(cliView.logLines, line);
  }

  broadcastCliSummary();
  broadcastCliLogTail();

  const options = extractPlanOptions(normalized);
  if (options.length === 0) {
    return;
  }
  const signature = options.join("\n");

  for (const client of wss.clients) {
    if (client.readyState !== WebSocket.OPEN || !client.clientState?.authenticated) {
      continue;
    }
    if (client.clientState.lastMirrorPlanSignature === signature) {
      continue;
    }
    client.clientState.lastMirrorPlanSignature = signature;
    applyPlanOptions(client, client.clientState, options);
  }
}

function updateCliSummaryFromTranscriptSnapshot(snapshot) {
  const userText = summarizeAssistantText(snapshot?.userText || "");
  const assistantText = summarizeAssistantText(snapshot?.assistantText || "");
  const statusLine = String(snapshot?.statusLine || "Claude mirror").trim();
  const normalized = normalizeTerminalSnapshot(snapshot?.text || "");

  const signature = [userText, assistantText, normalized].join("\n---\n");
  if (!signature.trim() || signature === terminalMirrorLastSnapshot) {
    return;
  }
  terminalMirrorLastSnapshot = signature;

  if (userText) {
    cliView.latestUserText = userText;
  }
  if (assistantText) {
    cliView.latestAssistantText = assistantText;
  }
  cliView.statusLine = statusLine;

  if (normalized) {
    const lines = normalized
      .split("\n")
      .slice(-Math.max(8, Number(config.terminalMirrorLines) || 60));
    for (const line of lines) {
      cliView.logLines = pushLogLine(cliView.logLines, line);
    }
  }

  broadcastCliSummary();
  broadcastCliLogTail();

  const optionsSource = assistantText || normalized;
  const options = extractPlanOptions(optionsSource);
  if (options.length === 0) {
    return;
  }
  const planSignature = options.join("\n");
  for (const client of wss.clients) {
    if (client.readyState !== WebSocket.OPEN || !client.clientState?.authenticated) {
      continue;
    }
    if (client.clientState.lastMirrorPlanSignature === planSignature) {
      continue;
    }
    client.clientState.lastMirrorPlanSignature = planSignature;
    applyPlanOptions(client, client.clientState, options);
  }
}
function pollTerminalMirrorOnce() {
  if (!config.terminalMirrorEnabled) {
    return;
  }

  if (!shouldUseTmuxMirror()) {
    try {
      const snapshot = readClaudeTranscriptSnapshot();
      if (!snapshot.text && !snapshot.assistantText) {
        if (terminalMirrorLastError !== "no_claude_transcript") {
          terminalMirrorLastError = "no_claude_transcript";
          setCliState({ phase: "idle", statusLine: snapshot.statusLine || "Claude mirror unavailable" });
        }
        return;
      }

      terminalMirrorLastError = "";
      cliView.cwd = config.claudeCwd || process.cwd();
      cliView.repoName = DISPLAY_REPO_NAME;
      setCliState({
        phase: "running",
        statusLine: snapshot.statusLine || "Claude mirror",
        threadId: ""
      });
      updateCliSummaryFromTranscriptSnapshot(snapshot);
      return;
    } catch {
      if (terminalMirrorLastError !== "transcript_failed") {
        terminalMirrorLastError = "transcript_failed";
        setCliState({ phase: "idle", statusLine: "Claude mirror polling failed" });
      }
      return;
    }
  }

  try {
    const targets = getTerminalMirrorPaneTargets();
    if (targets.length === 0) {
      if (terminalMirrorLastError !== "no_tmux_target") {
        terminalMirrorLastError = "no_tmux_target";
        setCliState({ phase: "idle", statusLine: "Terminal mirror unavailable" });
      }
      return;
    }

    let captured = "";
    let matchedTarget = null;
    for (const target of targets) {
      try {
        captured = readTmuxPaneLines(target.session, target.window, config.terminalMirrorLines);
      } catch {
        continue;
      }
      if (captured && captured.trim()) {
        matchedTarget = target;
        break;
      }
    }

    if (!matchedTarget) {
      if (terminalMirrorLastError !== "capture_failed") {
        terminalMirrorLastError = "capture_failed";
        setCliState({ phase: "idle", statusLine: "Terminal mirror waiting for tmux output" });
      }
      return;
    }

    terminalMirrorLastError = "";
    cliView.cwd = config.codexCwd;
    cliView.repoName = DISPLAY_REPO_NAME;
    setCliState({
      phase: "running",
      statusLine: `Terminal mirror ${matchedTarget.session}:${matchedTarget.window}`,
      threadId: ""
    });
    updateCliSummaryFromTerminalSnapshot(captured, "Ghostty");
  } catch {
    if (terminalMirrorLastError !== "poll_failed") {
      terminalMirrorLastError = "poll_failed";
      setCliState({ phase: "idle", statusLine: "Terminal mirror polling failed" });
    }
  }
}

function restartTerminalMirrorPolling() {
  if (terminalMirrorPollTimer) {
    clearInterval(terminalMirrorPollTimer);
    terminalMirrorPollTimer = null;
  }

  terminalMirrorLastSnapshot = "";
  terminalMirrorLastError = "";
  terminalMirrorPaneTargetsCache = { expiresAt: 0, targets: [] };

  if (!config.terminalMirrorEnabled) {
    return;
  }

  const intervalMs = Math.max(300, Number(config.terminalMirrorIntervalMs) || 800);
  terminalMirrorPollTimer = setInterval(() => {
    pollTerminalMirrorOnce();
  }, intervalMs);
  terminalMirrorPollTimer.unref?.();

  pollTerminalMirrorOnce();
}

function extractJsonObjectsFromText(text) {
  const source = String(text || "");
  const matches = source.match(/```json\s*([\s\S]*?)```/giu) || [];
  const jsonBlocks = matches
    .map((block) => block.replace(/^```json\s*/iu, "").replace(/```$/u, "").trim())
    .filter(Boolean);

  const candidates = [...jsonBlocks];
  const firstBrace = source.indexOf("{");
  const lastBrace = source.lastIndexOf("}");
  if (firstBrace >= 0 && lastBrace > firstBrace) {
    candidates.push(source.slice(firstBrace, lastBrace + 1));
  }

  const objects = [];
  for (const candidate of candidates) {
    try {
      const parsed = JSON.parse(candidate);
      if (Array.isArray(parsed)) {
        for (const item of parsed) {
          if (item && typeof item === "object") {
            objects.push(item);
          }
        }
      } else if (parsed && typeof parsed === "object") {
        objects.push(parsed);
      }
    } catch {
      // ignore
    }
  }
  return objects;
}

function extractPlanOptionsFromJsonText(text) {
  const objects = extractJsonObjectsFromText(text);
  if (objects.length === 0) {
    return [];
  }

  const candidates = [];
  for (const object of objects) {
    const planArray = Array.isArray(object.plan)
      ? object.plan
      : Array.isArray(object.Plan)
        ? object.Plan
        : null;
    if (planArray) {
      for (const item of planArray) {
        if (typeof item === "string") {
          candidates.push(item);
          continue;
        }
        if (item && typeof item === "object") {
          candidates.push(item.text || item.title || item.step || item.item || "");
        }
      }
    }

    const optionsArray = Array.isArray(object.options)
      ? object.options
      : Array.isArray(object.planOptions)
        ? object.planOptions
        : null;
    if (optionsArray) {
      for (const item of optionsArray) {
        if (typeof item === "string") {
          candidates.push(item);
          continue;
        }
        if (item && typeof item === "object") {
          candidates.push(item.text || item.title || item.step || item.item || "");
        }
      }
    }
  }

  return collectUniquePlanOptions(candidates);
}

function exceedsAudioDurationLimit(byteCount) {
  const maxMs = Math.max(1000, Number(config.lanAudioMaxMs) || 120000);
  const durationMs = (Number(byteCount || 0) / (PCM_SAMPLE_RATE * PCM_BYTES_PER_SAMPLE)) * 1000;
  return durationMs > maxMs;
}

function getVoiceMode(state) {
  const mode = String(state?.voiceMode || "").trim().toLowerCase();
  return VALID_VOICE_MODES.has(mode) ? mode : "normal";
}
function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

function normalizePlanOptionText(value) {
  return String(value || "")
    .replace(/\s+/g, " ")
    .trim();
}

function collectUniquePlanOptions(candidates) {
  const options = [];
  const seen = new Set();
  for (const candidate of candidates) {
    const normalized = normalizePlanOptionText(candidate);
    if (!normalized || seen.has(normalized)) {
      continue;
    }
    seen.add(normalized);
    options.push(normalized);
    if (options.length >= MAX_PLAN_OPTIONS) {
      break;
    }
  }
  return options;
}

function extractPlanOptions(text) {
  const fromJson = extractPlanOptionsFromJsonText(text);
  if (fromJson.length > 0) {
    return fromJson;
  }

  const rawLines = String(text || "")
    .split(/\r?\n/)
    .map((line) => String(line || "").trim())
    .filter(Boolean);

  if (rawLines.length === 0) {
    return [];
  }

  const checklist = [];
  for (const line of rawLines) {
    const match = line.match(/^[-*]\s*\[[ xX]\]\s+(.+)$/);
    if (match) {
      checklist.push(match[1]);
    }
  }
  if (checklist.length > 0) {
    return collectUniquePlanOptions(checklist);
  }

  const numbered = [];
  let inPlanSection = false;
  for (const line of rawLines) {
    if (/^(?:#{1,6}\s*)?(?:\*\*)?(?:plan|方案)(?:\*\*)?\s*[:：]?$/i.test(line)) {
      inPlanSection = true;
      continue;
    }

    if (/^#{1,6}\s+/.test(line)) {
      inPlanSection = false;
      continue;
    }

    const numberedMatch = line.match(/^\d+[.)]\s+(.+)$/);
    if (numberedMatch && (inPlanSection || numbered.length > 0)) {
      numbered.push(numberedMatch[1]);
      continue;
    }

    if (inPlanSection) {
      const bulletMatch = line.match(/^[-*]\s+(.+)$/);
      if (bulletMatch) {
        numbered.push(bulletMatch[1]);
      }
    }
  }

  return collectUniquePlanOptions(numbered);
}

function getPlanOptionsPayload(state) {
  const options = Array.isArray(state?.planOptions) ? state.planOptions : [];
  const selectedIndex =
    Number.isInteger(state?.planSelectedIndex) && state.planSelectedIndex >= 0
      ? state.planSelectedIndex
      : options.length > 0
        ? 0
        : -1;
  return {
    type: "plan_options",
    options,
    selectedIndex
  };
}

function emitPlanOptions(ws) {
  if (!ws?.clientState) {
    return;
  }
  sendJson(ws, getPlanOptionsPayload(ws.clientState));
}

function clearPlanOptions(ws, state) {
  if (!state) {
    return;
  }
  state.planOptions = [];
  state.planSelectedIndex = -1;
  if (ws?.readyState === WebSocket.OPEN && state.authenticated) {
    emitPlanOptions(ws);
  }
}

function applyPlanOptions(ws, state, options) {
  if (!state) {
    return;
  }
  state.planOptions = options;
  state.planSelectedIndex = options.length > 0 ? 0 : -1;
  if (ws?.readyState === WebSocket.OPEN && state.authenticated) {
    emitPlanOptions(ws);
  }
}

function buildPlanApplyPrompt(selectedOption) {
  const planLine = normalizePlanOptionText(selectedOption);
  return [
    "请按下面选中的方案执行。",
    "不要输出思考过程，只输出两个部分：",
    "## Plan",
    "- [ ] ...",
    "## Result",
    "- ...",
    "",
    `选中方案：${planLine}`
  ].join("\n");
}

function movePlanSelection(ws, state, delta) {
  const options = Array.isArray(state?.planOptions) ? state.planOptions : [];
  if (!state || options.length === 0) {
    return null;
  }

  const current =
    Number.isInteger(state.planSelectedIndex) && state.planSelectedIndex >= 0
      ? state.planSelectedIndex
      : 0;
  const next = (current + delta + options.length) % options.length;
  state.planSelectedIndex = next;
  emitPlanOptions(ws);
  return options[next] || null;
}

function getSelectedPlanOption(state) {
  const options = Array.isArray(state?.planOptions) ? state.planOptions : [];
  if (options.length === 0) {
    return "";
  }
  const index =
    Number.isInteger(state?.planSelectedIndex) && state.planSelectedIndex >= 0
      ? Math.min(state.planSelectedIndex, options.length - 1)
      : 0;
  return String(options[index] || "").trim();
}

function printBanner() {
  let version = "?";
  try {
    const pkg = JSON.parse(fs.readFileSync(new URL("../package.json", import.meta.url), "utf8"));
    version = pkg.version || version;
  } catch {
    // ignore
  }

  const sttLabel = config.mockTranscript
    ? "mock"
    : config.sttProvider ||
      (config.openaiApiKey ? `openai · ${config.openaiModel}` : "") ||
      (config.volcengineAppKey ? `volcengine · ${config.volcengineLanguage}` : "") ||
      "\x1b[33mnone — set OPENAI_API_KEY or VOLCENGINE_APP_KEY\x1b[0m";

  const targetLabel =
    config.sendTarget + (config.sendTargetAuto ? " \x1b[2m[auto]\x1b[0m" : "");

  const authLabel = config.lanSharedSecret
    ? "\x1b[32mon\x1b[0m"
    : "\x1b[33moff\x1b[0m (set LAN_SHARED_SECRET to enable)";

  console.log(`\nvibecoding-plus v${version}`);
  console.log(`  target     ${targetLabel}`);
  console.log(`  stt        ${sttLabel}`);
  console.log(`  todo       ${todoAssistant.label()}`);
  console.log(`  auth       ${authLabel}`);
  console.log(`  ws         ws://${config.bindHost}:${config.port}`);
  if (config.discoveryEnabled) {
    console.log(`  discovery  udp://${config.bindHost}:${config.discoveryPort}`);
  }
  process.stderr.write(`  cwd        ${config.claudeCwd || process.cwd()} (VIBE_INVOKE_CWD=${process.env.VIBE_INVOKE_CWD || "(not set)"})\n`);
  console.log(`\nRun with --doctor to check your environment.\n`);
}

function getTargetLabel(sendTarget) {
  if (sendTarget === "claude_code") {
    return "Claude";
  }
  if (sendTarget === "codex_exec") {
    return "Codex";
  }
  return "";
}

function getTargetCwd(sendTarget) {
  return sendTarget === "claude_code" ? config.claudeCwd : config.codexCwd;
}

function emitServerReady(ws) {
  sendJson(ws, {
    type: "server_ready",
    textInjectionMode: config.textInjectionMode,
    transcriptDeliveryMode: config.transcriptDeliveryMode,
    sendTarget: config.sendTarget,
    mode: getVoiceMode(ws.clientState),
    authRequired: Boolean(config.lanSharedSecret)
  });
}

function broadcastServerReady() {
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN && client.clientState?.authenticated) {
      emitServerReady(client);
    }
  }
}

function applySendTarget(nextTarget) {
  if (!VALID_SEND_TARGETS.has(nextTarget)) {
    throw new Error(`unsupported send target: ${nextTarget}`);
  }

  config.sendTarget = nextTarget;
  config.sendTargetAuto = false;

  const label = getTargetLabel(nextTarget);
  const cwd = getTargetCwd(nextTarget);
  cliView.cwd = cwd;
  cliView.repoName = DISPLAY_REPO_NAME;
  if (!cliView.latestAssistantText) {
    cliView.statusLine = label ? `${label} idle` : "Idle";
  }

  restartTerminalMirrorPolling();
  broadcastCliState();
  broadcastCliSummary();
  broadcastServerReady();
}

function applyCliCwd(target, nextCwd) {
  const resolvedCwd = path.resolve(String(nextCwd || "").trim());
  if (!resolvedCwd || !fs.existsSync(resolvedCwd)) {
    throw new Error(`invalid_cli_cwd:${nextCwd}`);
  }

  if (target === "codex_exec") {
    config.codexCwd = resolvedCwd;
  } else if (target === "claude_code") {
    config.claudeCwd = resolvedCwd;
  } else {
    throw new Error(`unsupported_cli_cwd_target:${target}`);
  }

  if (config.sendTarget === target) {
    cliView.cwd = resolvedCwd;
    cliView.repoName = DISPLAY_REPO_NAME;
    if (cliView.phase === "idle") {
      const label = getTargetLabel(target);
      cliView.statusLine = label ? `${label} idle` : "Idle";
    }
    broadcastCliState();
    broadcastCliSummary();
    broadcastServerReady();
  }

  return resolvedCwd;
}

function getTodoSnapshotPayload() {
  const snapshot = todoService.getSnapshot();
  return {
    type: "todo_state",
    items: snapshot.items,
    selectedIndex: snapshot.selectedIndex,
    lastActionText: snapshot.lastActionText
  };
}

function emitModeState(ws) {
  sendJson(ws, {
    type: "mode_state",
    mode: getVoiceMode(ws.clientState)
  });
}

function emitTodoState(ws) {
  sendJson(ws, getTodoSnapshotPayload());
}

function broadcastTodoState() {
  broadcastJson(getTodoSnapshotPayload());
}

function applyVoiceMode(ws, state, nextMode) {
  if (!VALID_VOICE_MODES.has(nextMode)) {
    throw new Error(`unsupported_voice_mode:${nextMode}`);
  }
  state.voiceMode = nextMode;
  emitModeState(ws);
}

function formatTodoErrorMessage(error) {
  const message = error instanceof Error ? error.message : String(error);
  switch (message) {
    case "todo_title_required":
      return "计划内容不能为空";
    case "todo_empty":
      return "暂无计划";
    case "todo_index_required":
      return "请先选择计划";
    case "todo_index_invalid":
      return "计划序号无效";
    case "todo_index_out_of_range":
      return "计划序号超出范围";
    case "todo_item_not_found":
      return "计划已不存在";
    default:
      return "待办操作失败";
  }
}

function sendTodoResult(ws, payload) {
  sendJson(ws, {
    type: "todo_result",
    ok: Boolean(payload?.ok),
    action: String(payload?.action || "unknown"),
    message: String(payload?.message || "")
  });
}

function clearPendingTodoIntent(state) {
  if (state?.pendingTodoTimer) {
    clearTimeout(state.pendingTodoTimer);
    state.pendingTodoTimer = null;
  }
  if (state) {
    const deviceId = String(state.deviceId || "").trim();
    if (deviceId) {
      pendingTodoIntentByDevice.delete(deviceId);
      persistPendingTodoIntentByDevice();
    }
    state.pendingTodoIntent = null;
    state.pendingTodoIntentExpiresAt = 0;
  }
}

function setPendingTodoIntent(ws, state, pendingIntent) {
  if (!state) {
    return;
  }

  clearPendingTodoIntent(state);
  if (!pendingIntent) {
    return;
  }

  state.pendingTodoIntent = pendingIntent;
  state.pendingTodoIntentExpiresAt = Date.now() + config.todoFollowupTimeoutMs;
  const deviceId = String(state.deviceId || "").trim();
  if (deviceId) {
    pendingTodoIntentByDevice.set(deviceId, {
      pendingIntent,
      expiresAt: state.pendingTodoIntentExpiresAt
    });
    persistPendingTodoIntentByDevice();
  }

  state.pendingTodoTimer = setTimeout(() => {
    if (!isWsReadyForJson(ws) || state.pendingTodoIntent !== pendingIntent) {
      return;
    }
    clearPendingTodoIntent(state);
    sendTodoResult(ws, {
      ok: true,
      action: "cancel",
      message: "已取消待办追问"
    });
  }, config.todoFollowupTimeoutMs);
  state.pendingTodoTimer.unref?.();
}

function runTodoCommand(command, { ws = null } = {}) {
  try {
    const result = todoService.runCommand(command);
    broadcastTodoState();
    if (ws) {
      sendTodoResult(ws, result);
    }
    return result;
  } catch (error) {
    const result = {
      ok: false,
      action: String(command?.action || "unknown"),
      message: formatTodoErrorMessage(error)
    };
    if (ws) {
      sendTodoResult(ws, result);
    }
    return result;
  }
}

async function dispatchTodoPrompt(ws, prompt, state) {
  if (state?.pendingTodoIntent && state.pendingTodoIntentExpiresAt <= Date.now()) {
    clearPendingTodoIntent(state);
  }
  const outcome = await todoAssistant.interpret(prompt, {
    pendingIntent: state?.pendingTodoIntent,
    snapshot: todoService.getSnapshot()
  });
  if (state) {
    setPendingTodoIntent(ws, state, outcome.pendingIntent || null);
  }

  if (!outcome.command) {
    sendTodoResult(ws, {
      ok: outcome.ok,
      action: outcome.action || "parse",
      message: outcome.message
    });
    return;
  }
  runTodoCommand(outcome.command, { ws });
}

function sendJson(ws, payload) {
  sendJsonIfOpen(ws, payload);
}

function broadcastJson(payload) {
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN && client.clientState?.authenticated) {
      sendJson(client, payload);
    }
  }
}

function createClientState() {
  return {
    deviceId: "unknown",
    authenticated: !config.lanSharedSecret,
    voiceMode: "normal",
    segmentActive: false,
    chunks: [],
    audioBytes: 0,
    pendingSegments: [],
    pendingTranscript: "",
    injectedSegments: [],
    pendingTodoIntent: null,
    pendingTodoIntentExpiresAt: 0,
    pendingTodoTimer: null,
    planOptions: [],
    planSelectedIndex: -1,
    lastMirrorPlanSignature: ""
  };
}

function joinPendingSegments(segments) {
  const normalized = segments
    .map((segment) => String(segment || "").replace(/\s+/g, " ").trim())
    .filter(Boolean);

  return normalized.reduce((combined, segment) => {
    if (!combined) {
      return segment;
    }

    const endsWithPunctuation = /[。！？!?；;：:，,、.]$/.test(combined);
    const startsWithPunctuation = /^[。！？!?；;：:，,、.]/.test(segment);
    return combined + (endsWithPunctuation || startsWithPunctuation ? "" : " ") + segment;
  }, "");
}

function updatePendingTranscript(state) {
  state.pendingTranscript = joinPendingSegments(state.pendingSegments);
  return state.pendingTranscript;
}

function joinInjectedSegments(segments) {
  const normalized = segments
    .map((segment) => String(segment || "").replace(/\s+/g, " ").trim())
    .filter(Boolean);

  return normalized.reduce((combined, segment) => {
    if (!combined) {
      return segment;
    }

    const endsWithPunctuation = /[。！？!?；;：:，,、.]$/.test(combined);
    const startsWithPunctuation = /^[。！？!?；;：:，,、.]/.test(segment);
    return combined + (endsWithPunctuation || startsWithPunctuation ? "" : " ") + segment;
  }, "");
}

function updateInjectedTranscript(state) {
  return joinInjectedSegments(state.injectedSegments || []);
}

function clearPendingAndInjectedTranscripts(state) {
  state.pendingTranscript = "";
  state.pendingSegments = [];
  state.injectedSegments = [];
}

function emitCliSnapshot(ws) {
  sendJson(ws, {
    type: "cli_session_state",
    phase: cliView.phase,
    statusLine: cliView.statusLine,
    threadId: cliView.threadId,
    repoName: cliView.repoName,
    cwd: cliView.cwd,
    quota5hRemainingPct: cliView.quota5hRemainingPct,
    quotaWeekRemainingPct: cliView.quotaWeekRemainingPct,
    quotaPlanType: cliView.quotaPlanType
  });
  sendJson(ws, {
    type: "cli_summary",
    latestUserText: cliView.latestUserText,
    latestAssistantText: cliView.latestAssistantText,
    statusLine: cliView.statusLine,
    threadId: cliView.threadId,
    repoName: cliView.repoName
  });
  sendJson(ws, {
    type: "cli_log_tail",
    lines: cliView.logLines
  });
  emitModeState(ws);
  emitTodoState(ws);
  emitPlanOptions(ws);
}

function broadcastCliState() {
  broadcastJson({
    type: "cli_session_state",
    phase: cliView.phase,
    statusLine: cliView.statusLine,
    threadId: cliView.threadId,
    repoName: cliView.repoName,
    cwd: cliView.cwd,
    quota5hRemainingPct: cliView.quota5hRemainingPct,
    quotaWeekRemainingPct: cliView.quotaWeekRemainingPct,
    quotaPlanType: cliView.quotaPlanType
  });
}

function broadcastCliSummary() {
  broadcastJson({
    type: "cli_summary",
    latestUserText: cliView.latestUserText,
    latestAssistantText: cliView.latestAssistantText,
    statusLine: cliView.statusLine,
    threadId: cliView.threadId,
    repoName: cliView.repoName
  });
}

function broadcastCliLogTail() {
  scheduleCliLogTailFlush();
}

function appendCliLog(line) {
  cliView.logLines = pushLogLine(cliView.logLines, line);
  broadcastCliLogTail();
}

function setCliState(patch) {
  Object.assign(cliView, patch);
  broadcastCliState();
}

function setCliSummary(patch) {
  Object.assign(cliView, patch);
  broadcastCliSummary();
}

function applyRateLimitSnapshot(snapshot) {
  if (!snapshot) {
    return;
  }

  cliView.quota5hRemainingPct = snapshot.primaryRemainingPct;
  cliView.quotaWeekRemainingPct = snapshot.secondaryRemainingPct;
  cliView.quotaPlanType = snapshot.planType || cliView.quotaPlanType || "";
}

function refreshRateLimits(threadId = "") {
  const snapshot =
    config.sendTarget === "claude_code"
      ? readLatestClaudeRateLimits()
      : readLatestRateLimits(threadId || cliView.threadId);
  if (!snapshot) {
    return;
  }

  applyRateLimitSnapshot(snapshot);
  broadcastCliState();
}

function pruneRecentHelloNonces(nowMs = Date.now()) {
  const ttlMs = Math.max(1, config.lanAuthWindowSec) * 1000;
  for (const [key, seenAtMs] of recentHelloNonces.entries()) {
    if (nowMs - seenAtMs > ttlMs) {
      recentHelloNonces.delete(key);
    }
  }
}

function markHelloNonce(deviceId, nonce, nowMs = Date.now()) {
  pruneRecentHelloNonces(nowMs);
  const cacheKey = `${deviceId}:${nonce}`;
  if (recentHelloNonces.has(cacheKey)) {
    return false;
  }

  recentHelloNonces.set(cacheKey, nowMs);
  return true;
}

function shouldCheckTimestampFreshness(ts) {
  const numericTs = Number(ts);
  return Number.isFinite(numericTs) && numericTs >= MIN_PLAUSIBLE_EPOCH_MS;
}

function closeWithAuthError(ws, state, error) {
  const message = String(error || "auth_failed");
  state.authenticated = false;
  sendJson(ws, { type: "error", error: message });
  ws.close(4001, message);
}

function validateHello(message, remoteAddress) {
  if (!config.lanSharedSecret) {
    return { ok: true };
  }

  const addr = String(remoteAddress || "");
  if (config.lanTrustLocalhost && LOCALHOST_REMOTE_ADDRESSES.has(addr)) {
    return { ok: true };
  }

  const ts = message.authTs;
  const deviceId = message.deviceId || "unknown";
  const nonce = String(message.authNonce || "").trim();
  const actualSig = String(message.authSig || "").trim();
  if (!nonce || !actualSig) {
    return { ok: false, error: "auth_missing" };
  }
  if (shouldCheckTimestampFreshness(ts) && !isFreshTimestamp(ts, config.lanAuthWindowSec)) {
    return { ok: false, error: "auth_stale" };
  }

  const expectedSig = signHelloPayload(
    {
      deviceId,
      boardType: message.boardType || "unknown",
      ts,
      nonce
    },
    config.lanSharedSecret
  );

  if (!signaturesMatch(expectedSig, actualSig)) {
    return { ok: false, error: "auth_invalid" };
  }

  if (!markHelloNonce(deviceId, nonce)) {
    return { ok: false, error: "auth_replayed" };
  }

  return { ok: true };
}

async function runCodexPrompt(prompt) {
  cliView.latestUserText = prompt;
  cliView.latestAssistantText = "";
  setCliState({
    phase: "running",
    statusLine: "Running Codex...",
    threadId: codexSession.getThreadId()
  });
  broadcastCliSummary();
  appendCliLog(`user: ${summarizeAssistantText(prompt)}`);

  await codexSession.sendPrompt(prompt, {
    onState(patch) {
      setCliState(patch);
    },
    onSummary(patch) {
      setCliSummary({
        ...patch,
        latestAssistantText: summarizeAssistantText(patch.latestAssistantText)
      });
    },
    onEvent(event) {
      appendCliLog(formatCodexEvent(event));
      if (event.type === "thread.started" && event.thread_id) {
        cliView.threadId = String(event.thread_id);
        broadcastCliState();
        broadcastCliSummary();
      }
    },
    onLogLine(line) {
      appendCliLog(line);
    }
  });

  refreshRateLimits(codexSession.getThreadId());
}

function launchCodexPrompt(prompt) {
  void runCodexPrompt(prompt).catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    log("codex error", message);
    appendCliLog(`error: ${message}`);
    setCliState({
      phase: "error",
      statusLine: message,
      threadId: codexSession.getThreadId()
    });
  });
}

async function runClaudePrompt(prompt, options = {}) {
  const shouldExtractPlanOptions = Boolean(options.extractPlanOptions);
  const planOptionsWs = options.planOptionsWs || null;
  const planOptionsState = options.planOptionsState || null;
  cliView.latestUserText = prompt;
  cliView.latestAssistantText = "";
  setCliState({
    phase: "running",
    statusLine: "Running Claude...",
    threadId: claudeSession.getThreadId()
  });
  broadcastCliSummary();
  appendCliLog(`user: ${summarizeAssistantText(prompt)}`);

  await claudeSession.sendPrompt(prompt, {
    onState(patch) {
      setCliState(patch);
    },
    onSummary(patch) {
      const normalizedAssistant = summarizeAssistantText(patch.latestAssistantText);
      setCliSummary({
        ...patch,
        latestAssistantText: normalizedAssistant
      });

      if (shouldExtractPlanOptions && planOptionsWs && planOptionsState) {
        const optionsFromSummary = extractPlanOptions(normalizedAssistant);
        if (optionsFromSummary.length > 0) {
          applyPlanOptions(planOptionsWs, planOptionsState, optionsFromSummary);
        }
      }
    },
    onEvent(event) {
      appendCliLog(formatCodexEvent(event));

      if (shouldExtractPlanOptions && planOptionsWs && planOptionsState && event?.type === "result") {
        const optionsFromResult = extractPlanOptions(event.result || "");
        if (optionsFromResult.length > 0) {
          applyPlanOptions(planOptionsWs, planOptionsState, optionsFromResult);
        }
      }
    },
    onLogLine(line) {
      appendCliLog(line);
    }
  });

  refreshRateLimits();
}

function launchClaudePrompt(prompt, options = {}) {
  void runClaudePrompt(prompt, options).catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    log("claude error", message);
    appendCliLog(`error: ${message}`);
    setCliState({
      phase: "error",
      statusLine: message,
      threadId: claudeSession.getThreadId()
    });
  });
}

async function finalizeSegment(ws, state) {
  const pcmBuffer = Buffer.concat(state.chunks);
  state.segmentActive = false;
  state.chunks = [];
  state.audioBytes = 0;
  const voiceMode = getVoiceMode(state);

  if (pcmBuffer.length === 0) {
    sendJson(ws, { type: "status", status: "empty_segment" });
    return;
  }

  sendJson(ws, {
    type: "status",
    status: "transcribing",
    bytes: pcmBuffer.length
  });

  const startedAt = Date.now();
  const transcript = String(await transcribePcm16Mono({ pcmBuffer, config }) || "").trim();
  const hadPendingTranscript = Boolean(String(state.pendingTranscript || "").trim());

  if (!transcript) {
    sendJson(ws, {
      type: "status",
      status: hadPendingTranscript ? "empty_segment" : "transcript_empty",
      text: state.pendingTranscript
    });
    return;
  }

  if (voiceMode === "todo") {
    sendJson(ws, {
      type: "transcript_final",
      text: transcript,
      latencyMs: Date.now() - startedAt,
      requiresAction: false
    });
    state.pendingTranscript = "";
    state.pendingSegments = [];
    await dispatchTodoPrompt(ws, transcript, state);
    return;
  }

  if (config.transcriptDeliveryMode === "confirm_on_device") {
    state.pendingSegments.push(transcript);
    const pendingTranscript = updatePendingTranscript(state);
    sendJson(ws, {
      type: "transcript_final",
      text: pendingTranscript,
      latencyMs: Date.now() - startedAt,
      requiresAction: true
    });
    sendJson(ws, { type: "status", status: "awaiting_action", text: pendingTranscript });
    return;
  }

  sendJson(ws, {
    type: "transcript_final",
    text: transcript,
    latencyMs: Date.now() - startedAt,
    requiresAction: false
  });

  if (config.sendTarget === "codex_exec") {
    if (codexSession.isRunning()) {
      throw new Error("Codex session is busy");
    }
    clearPendingAndInjectedTranscripts(state);
    sendJson(ws, { type: "status", status: "typed", text: transcript });
    launchCodexPrompt(transcript);
    return;
  }

  if (config.sendTarget === "claude_code") {
    if (claudeSession.isRunning()) {
      throw new Error("Claude session is busy");
    }
    clearPendingAndInjectedTranscripts(state);
    sendJson(ws, { type: "status", status: "typed", text: transcript });
    launchClaudePrompt(transcript, {
      extractPlanOptions: true,
      planOptionsWs: ws,
      planOptionsState: state
    });
    return;
  }

  await dispatchPrompt(transcript);
  state.injectedSegments.push(transcript);
  state.pendingSegments = [];
  sendJson(ws, { type: "status", status: "typed", text: transcript });
}

async function dispatchPrompt(prompt, options = {}) {
  return await queueCliDispatch(async () => {
    if (config.sendTarget === "codex_exec") {
      if (codexSession.isRunning()) {
        throw new Error("Codex session is busy");
      }
      await runCodexPrompt(prompt);
      return;
    }

    if (config.sendTarget === "claude_code") {
      if (claudeSession.isRunning()) {
        throw new Error("Claude session is busy");
      }
      await runClaudePrompt(prompt, options);
      return;
    }

    cliView.latestUserText = prompt;
    cliView.statusLine = config.terminalMirrorEnabled ? "Typed to terminal (mirror on)" : "Typed to terminal";
    broadcastCliSummary();
    broadcastCliState();
    await injectText(prompt, config.textInjectionMode, {
      dryRun: config.dryRunTextInjection
    });
    if (config.terminalMirrorEnabled) {
      pollTerminalMirrorOnce();
    }
  });
}

function dispatchUserPrompt(ws, prompt, state) {
  clearPlanOptions(ws, state);
  if (getVoiceMode(state) === "todo") {
    return dispatchTodoPrompt(ws, prompt, state).then(() => "todo");
  }

  return dispatchPrompt(prompt, {
    extractPlanOptions: true,
    planOptionsWs: ws,
    planOptionsState: state
  }).then(() => "normal");
}

async function sendPendingTranscript(ws, state) {
  const transcript = String(state.pendingTranscript || "").trim();
  const voiceMode = getVoiceMode(state);
  if (!transcript) {
    sendJson(ws, { type: "status", status: "no_pending" });
    return;
  }

  if (voiceMode === "todo") {
    clearPendingAndInjectedTranscripts(state);
    await dispatchTodoPrompt(ws, transcript, state);
    return;
  }

  try {
    await dispatchPrompt(transcript, {
      extractPlanOptions: true,
      planOptionsWs: ws,
      planOptionsState: state
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (/busy/i.test(message)) {
      sendJson(ws, { type: "status", status: "cli_busy" });
      return;
    }
    throw error;
  }

  if (voiceMode === "normal" && config.sendTarget === "text_injector") {
    state.injectedSegments.push(transcript);
  }
  state.pendingTranscript = "";
  state.pendingSegments = [];
  sendJson(ws, { type: "status", status: "typed", text: transcript });
}

async function undoPendingTranscript(ws, state) {
  if (state.pendingSegments.length > 0) {
    state.pendingSegments.pop();
    const transcript = updatePendingTranscript(state);
    if (transcript) {
      sendJson(ws, { type: "status", status: "awaiting_action", text: transcript });
      return;
    }

    sendJson(ws, { type: "transcript_cleared" });
    sendJson(ws, { type: "status", status: "undo_ok" });
    return;
  }

  if (getVoiceMode(state) !== "normal" || config.sendTarget !== "text_injector" || state.injectedSegments.length === 0) {
    sendJson(ws, { type: "status", status: "no_pending" });
    return;
  }

  const previousTranscript = updateInjectedTranscript(state);
  const removedSegment = state.injectedSegments.pop();
  const nextTranscript = updateInjectedTranscript(state);
  const previousLength = [...previousTranscript].length;
  const nextLength = [...nextTranscript].length;
  const charsToUndo =
    Math.max(0, previousLength - nextLength) + (config.textInjectionMode === "type_and_enter" ? 1 : 0);

  if (charsToUndo <= 0) {
    if (removedSegment !== undefined) {
      state.injectedSegments.push(removedSegment);
    }
    sendJson(ws, { type: "status", status: "no_pending" });
    return;
  }

  try {
    await undoLastInput(charsToUndo, {
      dryRun: config.dryRunTextInjection
    });
  } catch (error) {
    if (removedSegment !== undefined) {
      state.injectedSegments.push(removedSegment);
    }
    throw error;
  }

  if (!nextTranscript) {
    sendJson(ws, { type: "transcript_cleared" });
  }
  sendJson(ws, { type: "status", status: "undo_ok", text: nextTranscript });
}

const adminRoutes = createAdminRoutes({
  config,
  todoService,
  getUserTodoListPath,
  broadcastTodoState,
  shutdown
});

const KEEPALIVE_INTERVAL_MS = 30_000;
const KEEPALIVE_MISS_LIMIT = 2;

const server = createServer((req, res) => {
  adminRoutes.handleRequest(req, res);
});

const wss = new WebSocketServer({ server });
const discoveryServer = startDiscoveryServer(config, { log });

const keepaliveInterval = setInterval(() => {
  for (const client of wss.clients) {
    if (client.readyState !== WebSocket.OPEN) {
      continue;
    }
    if ((client.missedPings || 0) >= KEEPALIVE_MISS_LIMIT) {
      log("keepalive timeout", client.clientState?.deviceId || "unknown");
      client.terminate();
      continue;
    }
    client.missedPings = (client.missedPings || 0) + 1;
    client.ping();
  }
}, KEEPALIVE_INTERVAL_MS);

wss.on("connection", (ws, req) => {
  const state = createClientState();
  ws.clientState = state;
  ws.missedPings = 0;
  ws.on("pong", () => {
    ws.missedPings = 0;
  });
  log("client connected", req.socket.remoteAddress);

  ws.on("message", async (data, isBinary) => {
    try {
      if (!state.authenticated && isBinary) {
        closeWithAuthError(ws, state, "auth_required");
        return;
      }

      if (isBinary) {
        if (state.segmentActive) {
          const chunk = Buffer.from(data);
          const nextBytes = Number(state.audioBytes || 0) + chunk.length;
          if (nextBytes > config.lanAudioMaxBytes || exceedsAudioDurationLimit(nextBytes)) {
            state.segmentActive = false;
            state.chunks = [];
            state.audioBytes = 0;
            sendJson(ws, {
              type: "warning",
              warning: "audio_too_large"
            });
            sendJson(ws, {
              type: "status",
              status: "audio_too_large"
            });
            return;
          }
          state.audioBytes = nextBytes;
          state.chunks.push(chunk);
        }
        return;
      }

      const message = JSON.parse(Buffer.from(data).toString("utf8"));
      switch (message.type) {
        case "hello":
          state.deviceId = message.deviceId || "unknown";
          {
            const authResult = validateHello(message, req.socket.remoteAddress);
            if (!authResult.ok) {
              log("auth rejected", { deviceId: state.deviceId, error: authResult.error });
              closeWithAuthError(ws, state, authResult.error);
              break;
            }
          }
          state.authenticated = true;
          restorePendingTodoIntentForState(state);
          log("hello", { deviceId: state.deviceId, boardType: message.boardType || "unknown" });
          sendJson(ws, { type: "hello_ack", deviceId: state.deviceId });
          emitServerReady(ws);
          emitCliSnapshot(ws);
          break;
        case "ptt_start":
          if (!state.authenticated) {
            closeWithAuthError(ws, state, "auth_required");
            break;
          }
          log("ptt_start", state.deviceId);
          state.segmentActive = true;
          state.chunks = [];
          state.audioBytes = 0;
          sendJson(ws, { type: "status", status: "recording" });
          break;
        case "ptt_stop":
          if (!state.authenticated) {
            closeWithAuthError(ws, state, "auth_required");
            break;
          }
          log("ptt_stop", state.deviceId, state.chunks.length);
          await finalizeSegment(ws, state);
          break;
        case "action_send":
          if (!state.authenticated) {
            closeWithAuthError(ws, state, "auth_required");
            break;
          }
          log("action_send", state.deviceId);
          await sendPendingTranscript(ws, state);
          break;
        case "action_undo":
          if (!state.authenticated) {
            closeWithAuthError(ws, state, "auth_required");
            break;
          }
          log("action_undo", state.deviceId);
          await undoPendingTranscript(ws, state);
          break;
        case "plan_select": {
          if (!state.authenticated) {
            closeWithAuthError(ws, state, "auth_required");
            break;
          }
          const direction = String(message.direction || "").trim().toLowerCase();
          if (!(direction === "prev" || direction === "next")) {
            sendJson(ws, { type: "warning", warning: "invalid_plan_select_direction" });
            break;
          }
          const selected = movePlanSelection(ws, state, direction === "prev" ? -1 : 1);
          if (!selected) {
            sendJson(ws, { type: "status", status: "no_plan_options" });
          }
          break;
        }
        case "plan_apply": {
          if (!state.authenticated) {
            closeWithAuthError(ws, state, "auth_required");
            break;
          }
          if (config.sendTarget === "claude_code" && claudeSession.isRunning()) {
            sendJson(ws, { type: "status", status: "cli_busy" });
            break;
          }
          if (config.sendTarget === "codex_exec" && codexSession.isRunning()) {
            sendJson(ws, { type: "status", status: "cli_busy" });
            break;
          }

          const selectedOption = getSelectedPlanOption(state);
          if (!selectedOption) {
            sendJson(ws, { type: "status", status: "no_plan_options" });
            break;
          }

          const applyPrompt = buildPlanApplyPrompt(selectedOption);
          clearPlanOptions(ws, state);
          sendJson(ws, { type: "status", status: "typed", text: applyPrompt });
          if (config.sendTarget === "codex_exec") {
            launchCodexPrompt(applyPrompt);
          } else if (config.sendTarget === "claude_code") {
            launchClaudePrompt(applyPrompt, {
              extractPlanOptions: false,
              planOptionsWs: ws,
              planOptionsState: state
            });
          } else {
            await dispatchPrompt(applyPrompt, {
              extractPlanOptions: false,
              planOptionsWs: ws,
              planOptionsState: state
            });
          }
          break;
        }
        case "set_target": {
          if (!state.authenticated) {
            closeWithAuthError(ws, state, "auth_required");
            break;
          }
          const nextTarget = String(message.sendTarget || "").trim();
          if (!VALID_SEND_TARGETS.has(nextTarget)) {
            sendJson(ws, { type: "warning", warning: "invalid_send_target" });
            break;
          }
          if (codexSession.isRunning() || claudeSession.isRunning()) {
            sendJson(ws, { type: "status", status: "cli_busy" });
            break;
          }
          if (config.sendTarget !== nextTarget) {
            log("set_target", state.deviceId, nextTarget);
            applySendTarget(nextTarget);
          } else {
            emitServerReady(ws);
          }
          break;
        }
        case "set_cli_cwd": {
          if (!state.authenticated) {
            closeWithAuthError(ws, state, "auth_required");
            break;
          }
          const target = String(message.sendTarget || "").trim();
          const nextCwd = String(message.cwd || "").trim();
          if (!(target === "codex_exec" || target === "claude_code")) {
            sendJson(ws, { type: "warning", warning: "invalid_cli_cwd_target" });
            break;
          }
          if (!nextCwd) {
            sendJson(ws, { type: "warning", warning: "cli_cwd_empty" });
            break;
          }
          try {
            const resolvedCwd = applyCliCwd(target, nextCwd);
            log("set_cli_cwd", state.deviceId, target, resolvedCwd);
            sendJson(ws, {
              type: "cli_cwd_updated",
              sendTarget: target,
              cwd: resolvedCwd
            });
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            sendJson(ws, { type: "warning", warning: message });
          }
          break;
        }
        case "set_mode": {
          if (!state.authenticated) {
            closeWithAuthError(ws, state, "auth_required");
            break;
          }
          const nextMode = String(message.mode || "").trim().toLowerCase();
          if (!VALID_VOICE_MODES.has(nextMode)) {
            sendJson(ws, { type: "warning", warning: "invalid_voice_mode" });
            break;
          }
          if (getVoiceMode(state) !== nextMode) {
            log("set_mode", state.deviceId, nextMode);
            if (nextMode !== "todo") {
              clearPendingTodoIntent(state);
            }
            applyVoiceMode(ws, state, nextMode);
          } else {
            emitModeState(ws);
          }
          break;
        }
        case "todo_command": {
          if (!state.authenticated) {
            closeWithAuthError(ws, state, "auth_required");
            break;
          }
          const action = String(message.action || "").trim().toLowerCase();
          if (!action) {
            sendTodoResult(ws, {
              ok: false,
              action: "unknown",
              message: "缺少待办操作"
            });
            break;
          }
          log("todo_command", state.deviceId, action);
          clearPendingTodoIntent(state);
          runTodoCommand(
            {
              action,
              id: message.id,
              index: message.index,
              text: message.text,
              completed: message.completed
            },
            { ws }
          );
          break;
        }
        case "prompt": {
          if (!state.authenticated) { closeWithAuthError(ws, state, "auth_required"); break; }
          const promptText = String(message.text || "").trim();
          if (!promptText) { sendJson(ws, { type: "warning", warning: "prompt_empty" }); break; }
          log("prompt (console)", state.deviceId, promptText.slice(0, 80));
          if (getVoiceMode(state) === "normal") {
            if (config.sendTarget === "claude_code" && claudeSession.isRunning()) {
              sendJson(ws, { type: "status", status: "cli_busy" });
              break;
            }
            if (config.sendTarget === "codex_exec" && codexSession.isRunning()) {
              sendJson(ws, { type: "status", status: "cli_busy" });
              break;
            }
          }
          void dispatchUserPrompt(ws, promptText, state).then((route) => {
            if (route === "normal") {
              sendJson(ws, { type: "status", status: "typed", text: promptText });
            }
          }).catch((e) => {
            const msg = e instanceof Error ? e.message : String(e);
            appendCliLog(`error: ${msg}`);
            setCliState({ phase: "error", statusLine: msg });
          });
          break;
        }
        case "action_enter":
          if (!state.authenticated) {
            closeWithAuthError(ws, state, "auth_required");
            break;
          }
          await injectText("", config.textInjectionMode, {
            dryRun: config.dryRunTextInjection,
            forceEnter: true
          });
          sendJson(ws, { type: "status", status: "typed", text: "" });
          break;
        case "ping":
          sendJson(ws, { type: "pong", nowMs: Date.now() });
          break;
        default:
          sendJson(ws, { type: "warning", warning: `unknown_message_type:${message.type}` });
          break;
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      log("message error", message);
      sendJson(ws, { type: "error", error: message });
      const activeSession =
        config.sendTarget === "claude_code" ? claudeSession : codexSession;
      appendCliLog(`error: ${message}`);
      setCliState({
        phase: "error",
        statusLine: message,
        threadId: activeSession.getThreadId()
      });
    }
  });

  ws.on("close", () => {
    clearPendingTodoIntent(state);
    log("client disconnected", state.deviceId);
  });

  ws.on("error", (error) => {
    log("ws error", state.deviceId, error.message);
  });
});

server.listen(config.port, config.bindHost, () => {
  printBanner();
  restartTerminalMirrorPolling();
  log(`server ready`);
});

function shutdown() {
  log("shutting down");
  clearInterval(keepaliveInterval);
  if (terminalMirrorPollTimer) {
    clearInterval(terminalMirrorPollTimer);
    terminalMirrorPollTimer = null;
  }
  discoveryServer?.close();
  for (const client of wss.clients) {
    client.terminate();
  }
  wss.close();
  server.close(() => {
    process.exit(0);
  });
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);


