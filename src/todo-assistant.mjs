import { parseTodoVoiceCommand, formatTodoDueShort } from "./todo-service.mjs";

const TODO_ACTIONS = new Set(["list", "create", "update", "delete", "clear", "toggle"]);
const CHINESE_DIGITS = new Map([
  ["零", 0],
  ["一", 1],
  ["二", 2],
  ["两", 2],
  ["三", 3],
  ["四", 4],
  ["五", 5],
  ["六", 6],
  ["七", 7],
  ["八", 8],
  ["九", 9]
]);

function collapseWhitespace(value) {
  return String(value || "")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeProvider(value) {
  return collapseWhitespace(value).toLowerCase();
}

function normalizeBaseUrl(value) {
  return collapseWhitespace(value).replace(/\/+$/, "");
}

function chatCompletionsUrl(baseUrl) {
  const normalized = normalizeBaseUrl(baseUrl || "https://api.deepseek.com");
  return normalized.endsWith("/chat/completions")
    ? normalized
    : `${normalized}/chat/completions`;
}

function parseChineseNumber(value) {
  const text = collapseWhitespace(value).replace(/[第个项号计划待办\s]/gu, "");
  if (!text) {
    return null;
  }

  if (/^[0-9]+$/u.test(text)) {
    const number = Number.parseInt(text, 10);
    return Number.isInteger(number) && number > 0 ? number : null;
  }

  if (CHINESE_DIGITS.has(text)) {
    return CHINESE_DIGITS.get(text);
  }

  if (text === "十") {
    return 10;
  }

  const teenMatch = text.match(/^十([一二两三四五六七八九])$/u);
  if (teenMatch) {
    return 10 + CHINESE_DIGITS.get(teenMatch[1]);
  }

  const tensMatch = text.match(/^([一二两三四五六七八九])十([一二两三四五六七八九])?$/u);
  if (tensMatch) {
    return CHINESE_DIGITS.get(tensMatch[1]) * 10 + (tensMatch[2] ? CHINESE_DIGITS.get(tensMatch[2]) : 0);
  }

  return null;
}

function extractIndex(text) {
  const digitMatch = text.match(/[0-9]+/u);
  if (digitMatch) {
    return Number.parseInt(digitMatch[0], 10);
  }

  const chineseMatch = text.match(/[一二两三四五六七八九十]+/u);
  return chineseMatch ? parseChineseNumber(chineseMatch[0]) : null;
}

function normalizeIndex(value) {
  if (Number.isInteger(value) && value > 0) {
    return value;
  }
  return extractIndex(String(value || ""));
}

function normalizeOptionalBoolean(value) {
  if (typeof value === "boolean") {
    return value;
  }
  const text = collapseWhitespace(value).toLowerCase();
  if (text === "true" || text === "yes" || text === "完成" || text === "已完成") {
    return true;
  }
  if (text === "false" || text === "no" || text === "未完成" || text === "取消完成") {
    return false;
  }
  return undefined;
}

function normalizeActionAlias(value) {
  const action = collapseWhitespace(value).toLowerCase();
  if (!action) {
    return "";
  }
  const aliasMap = new Map([
    ["add", "create"],
    ["insert", "create"],
    ["new", "create"],
    ["新增", "create"],
    ["添加", "create"],
    ["create", "create"],
    ["list", "list"],
    ["show", "list"],
    ["查看", "list"],
    ["query", "list"],
    ["update", "update"],
    ["edit", "update"],
    ["modify", "update"],
    ["修改", "update"],
    ["delete", "delete"],
    ["remove", "delete"],
    ["删", "delete"],
    ["clear", "clear"],
    ["reset", "clear"],
    ["清空", "clear"],
    ["toggle", "toggle"],
    ["check", "toggle"],
    ["uncheck", "toggle"],
    ["complete", "toggle"],
    ["completed", "toggle"],
    ["完成", "toggle"],
    ["取消完成", "toggle"]
  ]);
  return aliasMap.get(action) || action;
}

function normalizeModelTextFields(payload) {
  if (!payload || typeof payload !== "object") {
    return "";
  }
  return collapseWhitespace(
    payload.text ||
    payload.title ||
    payload.task ||
    payload.todo ||
    payload.content ||
    payload.value ||
    ""
  );
}

function normalizeModelIndexFields(payload) {
  if (!payload || typeof payload !== "object") {
    return null;
  }
  return (
    normalizeIndex(payload.index) ||
    normalizeIndex(payload.id) ||
    normalizeIndex(payload.item) ||
    normalizeIndex(payload.item_index) ||
    normalizeIndex(payload.itemIndex) ||
    null
  );
}

function inferCompletedFromPayload(payload) {
  const completed = normalizeOptionalBoolean(payload?.completed ?? payload?.done ?? payload?.checked ?? payload?.is_done ?? payload?.isDone);
  if (typeof completed === "boolean") {
    return completed;
  }
  const actionText = collapseWhitespace(payload?.action || "").toLowerCase();
  if (/uncheck|取消完成|取消勾选|未完成/u.test(actionText)) {
    return false;
  }
  if (/check|complete|完成|勾选/u.test(actionText)) {
    return true;
  }
  return undefined;
}

function parseFollowupDueAt(text) {
  const normalized = collapseWhitespace(text);
  if (!normalized) {
    return "";
  }
  const now = new Date();
  const minuteMatch = normalized.match(/(\d{1,2})[:：点](\d{1,2})/u);
  const hourOnlyMatch = minuteMatch ? null : normalized.match(/(\d{1,2})点(?:整)?/u);
  const amHint = /上午|早上|清晨/u.test(normalized);
  const pmHint = /下午|今晚|晚上|夜里|傍晚/u.test(normalized);
  const tomorrowHint = /明天/u.test(normalized);
  const dayAfterHint = /后天/u.test(normalized);

  if (!minuteMatch && !hourOnlyMatch) {
    return "";
  }

  let hour = 0;
  let minute = 0;
  if (minuteMatch) {
    hour = Number.parseInt(minuteMatch[1], 10);
    minute = Number.parseInt(minuteMatch[2], 10);
  } else if (hourOnlyMatch) {
    hour = Number.parseInt(hourOnlyMatch[1], 10);
  }

  if (!Number.isInteger(hour) || hour < 0 || hour > 23 || !Number.isInteger(minute) || minute < 0 || minute > 59) {
    return "";
  }

  if (pmHint && hour >= 1 && hour <= 11) {
    hour += 12;
  }
  if (amHint && hour === 12) {
    hour = 0;
  }

  const due = new Date(now);
  due.setSeconds(0, 0);
  due.setHours(hour, minute, 0, 0);
  if (tomorrowHint) {
    due.setDate(due.getDate() + 1);
  } else if (dayAfterHint) {
    due.setDate(due.getDate() + 2);
  } else if (due.getTime() < now.getTime() - 60_000) {
    due.setDate(due.getDate() + 1);
  }
  return due.toISOString();
}

function normalizeDueAt(value) {
  const text = collapseWhitespace(value);
  if (!text) {
    return "";
  }
  const timestamp = Date.parse(text);
  if (Number.isFinite(timestamp)) {
    return new Date(timestamp).toISOString();
  }
  return parseFollowupDueAt(text);
}

function normalizeModelDueAtFields(payload) {
  if (!payload || typeof payload !== "object") {
    return "";
  }
  const direct = collapseWhitespace(payload.dueAt || payload.due_at || payload.time || payload.datetime || payload.dateTime || "");
  if (direct) {
    return normalizeDueAt(direct);
  }
  return parseFollowupDueAt(normalizeModelTextFields(payload));
}

function normalizeLlmPayloadShape(payload) {
  if (!payload || typeof payload !== "object") {
    return payload;
  }
  const normalized = { ...payload };
  const rawAction = collapseWhitespace(normalized.action);
  normalized.type = collapseWhitespace(normalized.type).toLowerCase() || "command";
  normalized.action = normalizeActionAlias(rawAction);
  normalized.text = normalizeModelTextFields(normalized);
  normalized.index = normalizeModelIndexFields(normalized);
  normalized.dueAt = normalizeModelDueAtFields(normalized);
  normalized.completed = inferCompletedFromPayload({ ...normalized, action: rawAction });

  if (normalized.type === "ask" && (!normalized.pending || typeof normalized.pending !== "object")) {
    const pendingAction = TODO_ACTIONS.has(normalized.action) ? normalized.action : "create";
    const missing = pendingAction === "create"
      ? (!normalized.text ? "text" : "dueAt")
      : (normalized.text ? "index" : "text");
    normalized.pending = {
      action: pendingAction,
      missing,
      index: normalized.index,
      completed: normalized.completed,
      text: normalized.text,
      dueAt: normalized.dueAt
    };
  }

  return normalized;
}

function isCancelText(text) {
  return /^(?:取消|算了|不用了|停止|退出)$/iu.test(collapseWhitespace(text));
}

function askResult(message, pendingIntent) {
  return {
    ok: true,
    action: "ask",
    message,
    pendingIntent
  };
}

function messageResult(action, message) {
  return {
    ok: true,
    action,
    message,
    pendingIntent: null
  };
}

function commandResult(command, source = "rules") {
  return {
    ok: true,
    source,
    command,
    pendingIntent: null
  };
}

function parseExplicitFollowup(text) {
  const normalized = collapseWhitespace(text);
  if (!normalized) {
    return null;
  }

  if (/^(?:添加|新增)(?:计划|待办|todo)?$/iu.test(normalized)) {
    return askResult("计划内容是什么？", { action: "create", missing: "text" });
  }

  if (/^(?:删除|删掉)(?:计划|待办|todo)?$/iu.test(normalized)) {
    return askResult("要删除第几个计划？", { action: "delete", missing: "index" });
  }

  const updateIndexOnly = normalized.match(/^(?:修改|更新)(?:计划|待办|todo)\s*(?:第)?([0-9一二两三四五六七八九十]+)(?:项)?$/iu);
  if (updateIndexOnly) {
    const index = parseChineseNumber(updateIndexOnly[1]);
    return index
      ? askResult("新的计划内容是什么？", { action: "update", index, missing: "text" })
      : askResult("要修改第几个计划？", { action: "update", missing: "index" });
  }

  if (/^(?:修改|更新)(?:计划|待办|todo)?$/iu.test(normalized)) {
    return askResult("要修改第几个计划？", { action: "update", missing: "index" });
  }

  if (/^(?:完成|勾选)(?:计划|待办|todo)?$/iu.test(normalized)) {
    return askResult("要完成第几个计划？", { action: "toggle", completed: true, missing: "index" });
  }

  if (/^(?:取消完成|取消勾选)(?:计划|待办|todo)?$/iu.test(normalized)) {
    return askResult("要取消完成第几个计划？", { action: "toggle", completed: false, missing: "index" });
  }

  return null;
}

function resolvePendingIntent(pendingIntent, text) {
  if (!pendingIntent || typeof pendingIntent !== "object") {
    return null;
  }

  const normalized = collapseWhitespace(text);
  if (isCancelText(normalized)) {
    return messageResult("cancel", "已取消");
  }

  const action = collapseWhitespace(pendingIntent.action).toLowerCase();
  if (!TODO_ACTIONS.has(action)) {
    return null;
  }

  if (pendingIntent.missing === "text") {
    if (!normalized) {
      return askResult("计划内容是什么？", pendingIntent);
    }
    const parsedDueAt = action === "create" ? parseFollowupDueAt(normalized) : "";
    if (action === "create" && !parsedDueAt) {
      return askResult("提醒时间是什么？例如 明天早上9点", {
        ...pendingIntent,
        text: normalized,
        missing: "dueAt"
      });
    }
    return commandResult({
      action,
      index: pendingIntent.index,
      text: normalized,
      completed: pendingIntent.completed
    });
  }

  if (pendingIntent.missing === "dueat" || pendingIntent.missing === "dueAt") {
    const parsedDueAt = parseFollowupDueAt(normalized);
    if (!parsedDueAt) {
      return askResult("请说提醒时间，例如 明天晚上8点", pendingIntent);
    }
    return commandResult({
      action,
      index: pendingIntent.index,
      text: collapseWhitespace(pendingIntent.text),
      dueAt: parsedDueAt,
      completed: pendingIntent.completed
    });
  }

  if (pendingIntent.missing === "index") {
    const index = extractIndex(normalized);
    if (!index) {
      return askResult("请说计划序号，比如：第 2 个", pendingIntent);
    }
    if (action === "update") {
      return askResult("新的计划内容是什么？", { ...pendingIntent, index, missing: "text" });
    }
    return commandResult({ action, index, completed: pendingIntent.completed });
  }

  return null;
}

function buildSystemPrompt() {
  return [
    "你是一个 Todo List 语义解析器，只输出 JSON，不要输出 Markdown。",
    "你只负责把中文口语解析成结构化命令，不要执行命令。",
    "支持的 action 只有 list, create, update, delete, clear, toggle。",
    "如果用户只是查看待办，输出 {\"type\":\"command\",\"action\":\"list\"}。",
    "如果用户想新增待办，输出 {\"type\":\"command\",\"action\":\"create\",\"text\":\"待办内容\",\"dueAt\":\"ISO时间\"}。",
    "如果用户想删除全部或清空待办，输出 {\"type\":\"command\",\"action\":\"clear\"}。",
    "如果用户想修改、删除、完成或取消完成某条待办，必须给出 1-based index；没有序号就输出 ask。",
    "create 必须包含 dueAt；如果缺少时间，输出 ask，pending.missing=dueAt，并带上 pending.text。",
    "如果用户只说添加/新增但没有内容，输出 {\"type\":\"ask\",\"question\":\"计划内容是什么？\",\"pending\":{\"action\":\"create\",\"missing\":\"text\"}}。",
    "如果缺少序号，pending.missing 必须是 index；如果缺少新内容，pending.missing 必须是 text。",
    "toggle 的 completed 为 true 表示完成，false 表示取消完成。",
    "现在只做待办，不做提醒、日历、时间调度；时间仅作为待办 dueAt 字段。",
    "输出 JSON 形状只能是 command、ask 或 unsupported。"
  ].join("\n");
}

function buildUserPrompt(text, snapshot) {
  const items = Array.isArray(snapshot?.items) ? snapshot.items : [];
  const itemLines = items.length
    ? items.map((item, index) => `${index + 1}. [${item.completed ? "x" : " "}] ${item.title}${item.dueAt ? ` (${formatTodoDueShort(item.dueAt)})` : ""}`).join("\n")
    : "空";
  const selectedIndex = Number.isInteger(snapshot?.selectedIndex) ? snapshot.selectedIndex + 1 : null;

  return [
    `用户原话：${collapseWhitespace(text)}`,
    `当前选中序号：${selectedIndex && selectedIndex > 0 ? selectedIndex : "无"}`,
    "当前待办列表：",
    itemLines
  ].join("\n");
}

function extractJsonPayload(content) {
  const text = collapseWhitespace(content).replace(/^```(?:json)?/iu, "").replace(/```$/u, "").trim();
  try {
    return JSON.parse(text);
  } catch {
    const start = text.indexOf("{");
    const end = text.lastIndexOf("}");
    if (start >= 0 && end > start) {
      return JSON.parse(text.slice(start, end + 1));
    }
    throw new Error("todo_intent_invalid_json");
  }
}

function normalizeLlmPending(pending) {
  if (!pending || typeof pending !== "object") {
    return null;
  }
  const action = collapseWhitespace(pending.action).toLowerCase();
  const missing = collapseWhitespace(pending.missing);
  if (!TODO_ACTIONS.has(action) || !(missing === "text" || missing === "index" || missing === "dueAt" || missing === "dueat")) {
    return null;
  }
  return {
    action,
    missing,
    index: normalizeIndex(pending.index) || undefined,
    text: collapseWhitespace(pending.text),
    dueAt: collapseWhitespace(pending.dueAt),
    completed: normalizeOptionalBoolean(pending.completed)
  };
}

function normalizeLlmCommand(payload) {
  if (!payload || typeof payload !== "object") {
    return { ok: false, action: "parse", message: "没有识别出待办命令" };
  }

  const normalizedPayload = normalizeLlmPayloadShape(payload);
  const type = collapseWhitespace(normalizedPayload.type).toLowerCase();
  if (type === "ask") {
    const pendingIntent = normalizeLlmPending(normalizedPayload.pending);
    return askResult(collapseWhitespace(normalizedPayload.question) || "请补充待办信息", pendingIntent);
  }

  if (type === "unsupported") {
    return {
      ok: false,
      action: "parse",
      message: collapseWhitespace(normalizedPayload.message) || "现在只支持待办增删改查",
      pendingIntent: null
    };
  }

  if (type !== "command") {
    return { ok: false, action: "parse", message: "没有识别出待办命令", pendingIntent: null };
  }

  const action = collapseWhitespace(normalizedPayload.action).toLowerCase();
  if (!TODO_ACTIONS.has(action)) {
    return { ok: false, action: "parse", message: "不支持这个待办操作", pendingIntent: null };
  }

  if (action === "list" || action === "clear") {
    return commandResult({ action }, "deepseek");
  }

  const text = collapseWhitespace(normalizedPayload.text);
  const index = normalizeIndex(normalizedPayload.index);
  const dueAt = parseFollowupDueAt(normalizedPayload.dueAt);
  const completed = normalizeOptionalBoolean(normalizedPayload.completed);
  if (action === "create") {
    if (!text) {
      return askResult("计划内容是什么？", { action, missing: "text" });
    }
    if (!dueAt) {
      return askResult("提醒时间是什么？例如 明天早上9点", { action, missing: "dueAt", text });
    }
    return commandResult({ action, text, dueAt }, "deepseek");
  }

  if (!index) {
    const question = action === "delete"
      ? "要删除第几个计划？"
      : action === "toggle"
        ? "要操作第几个计划？"
        : "要修改第几个计划？";
    return askResult(question, { action, missing: "index", completed });
  }

  if (action === "update" && !text) {
    return askResult("新的计划内容是什么？", { action, index, missing: "text" });
  }

  return commandResult({
    action,
    index,
    text,
    completed
  }, "deepseek");
}

export class TodoAssistant {
  constructor(config) {
    this.provider = normalizeProvider(config.todoIntentProvider || "rules");
    this.apiKey = collapseWhitespace(config.todoIntentApiKey || config.deepseekApiKey);
    this.model = collapseWhitespace(config.todoIntentModel) || "deepseek-chat";
    this.baseUrl = normalizeBaseUrl(config.todoIntentBaseUrl || "https://api.deepseek.com");
    this.timeoutMs = Number.isFinite(config.todoIntentTimeoutMs) ? config.todoIntentTimeoutMs : 8000;
  }

  isLlmEnabled() {
    return this.provider === "deepseek";
  }

  label() {
    if (!this.isLlmEnabled()) {
      return "rules";
    }
    return this.apiKey ? `deepseek · ${this.model}` : "deepseek — TODO_INTENT_API_KEY missing";
  }

  async interpret(text, { pendingIntent = null, snapshot = null } = {}) {
    const normalized = collapseWhitespace(text);
    const pendingResult = resolvePendingIntent(pendingIntent, normalized);
    if (pendingResult) {
      return pendingResult;
    }

    const localCommand = parseTodoVoiceCommand(normalized);
    if (localCommand.ok) {
      if (localCommand.action === "create" && !localCommand.dueAt) {
        return askResult("提醒时间是什么？例如 明天早上9点", {
          action: "create",
          missing: "dueAt",
          text: collapseWhitespace(localCommand.text)
        });
      }
      return commandResult(localCommand);
    }

    const explicitFollowup = parseExplicitFollowup(normalized);
    if (explicitFollowup) {
      return explicitFollowup;
    }

    if (!this.isLlmEnabled()) {
      return {
        ok: false,
        action: "parse",
        message: localCommand.message,
        pendingIntent: null
      };
    }

    if (!this.apiKey) {
      return {
        ok: false,
        action: "parse",
        message: "Todo 语义模型未配置，请设置 TODO_INTENT_API_KEY",
        pendingIntent: null
      };
    }

    try {
      return await this.#interpretWithDeepSeek(normalized, snapshot);
    } catch {
      return {
        ok: false,
        action: "parse",
        message: localCommand.message || "请说：查看计划、添加计划 XXX、删除计划 2、修改计划 2 改成 XXX",
        pendingIntent: null
      };
    }
  }

  async #interpretWithDeepSeek(text, snapshot) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await fetch(chatCompletionsUrl(this.baseUrl), {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${this.apiKey}`
        },
        signal: controller.signal,
        body: JSON.stringify({
          model: this.model,
          messages: [
            { role: "system", content: buildSystemPrompt() },
            { role: "user", content: buildUserPrompt(text, snapshot) }
          ],
          temperature: 0,
          stream: false
        })
      });

      if (!response.ok) {
        throw new Error(`todo_intent_http_${response.status}`);
      }

      const payload = await response.json();
      const content = payload?.choices?.[0]?.message?.content;
      return normalizeLlmCommand(extractJsonPayload(content));
    } finally {
      clearTimeout(timer);
    }
  }
}

export function createTodoAssistant(config) {
  return new TodoAssistant(config);
}
