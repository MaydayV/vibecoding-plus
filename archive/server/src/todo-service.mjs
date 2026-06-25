import { randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export const VALID_VOICE_MODES = new Set(["normal", "todo"]);

const TODO_FILE_VERSION = 1;
const DEFAULT_TODO_ITEMS = [
  "示例：按住 BOOT 说“添加计划 喝水”",
  "示例：UP/DN 移动选中项",
  "示例：短按 BOOT 完成或删除当前计划",
  "示例：双击 UP 切换 Todo / Live"
];

function collapseWhitespace(value) {
  return String(value || "")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeTitle(value) {
  return collapseWhitespace(value);
}

function normalizePositiveInteger(value) {
  const numeric = Number.parseInt(String(value || "").trim(), 10);
  return Number.isInteger(numeric) && numeric > 0 ? numeric : null;
}

function normalizeTimestamp(value, fallback = "") {
  const text = collapseWhitespace(value);
  if (!text) {
    return fallback;
  }
  const timestamp = Date.parse(text);
  if (!Number.isFinite(timestamp)) {
    return fallback;
  }
  return new Date(timestamp).toISOString();
}

function parseLooseDueAt(text) {
  const input = collapseWhitespace(text);
  if (!input) {
    return "";
  }

  const now = new Date();
  const minuteMatch = input.match(/(\d{1,2})[:：点](\d{1,2})/u);
  const hourOnlyMatch = minuteMatch ? null : input.match(/(\d{1,2})点(?:整)?/u);
  const amHint = /上午|早上|清晨/u.test(input);
  const pmHint = /下午|今晚|晚上|夜里|傍晚/u.test(input);
  const tomorrowHint = /明天/u.test(input);
  const dayAfterHint = /后天/u.test(input);

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
    minute = 0;
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
function timestampMs(value) {
  const ms = Date.parse(String(value || ""));
  return Number.isFinite(ms) ? ms : 0;
}

function cloneItem(item) {
  return {
    id: item.id,
    title: item.title,
    completed: Boolean(item.completed),
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
    dueAt: item.dueAt || "",
    appleId: item.appleId || "",
    source: item.source || "local",
    syncUpdatedAt: item.syncUpdatedAt || item.updatedAt
  };
}

function splitItemsByCompletion(items) {
  const activeItems = [];
  const archiveItems = [];
  for (const item of Array.isArray(items) ? items : []) {
    if (item?.completed) {
      archiveItems.push(item);
    } else {
      activeItems.push(item);
    }
  }
  return { activeItems, archiveItems };
}

function sanitizePersistedState(rawState) {
  const source = rawState && typeof rawState === "object" ? rawState : {};
  const rawItems = Array.isArray(source.items) ? source.items : [];
  const items = rawItems
    .map((item) => {
      if (!item || typeof item !== "object") {
        return null;
      }

      const title = normalizeTitle(item.title);
      if (!title) {
        return null;
      }

      const createdAt = normalizeTimestamp(item.createdAt, new Date().toISOString());
      const updatedAt = normalizeTimestamp(item.updatedAt, createdAt);
      const syncUpdatedAt = normalizeTimestamp(item.syncUpdatedAt, updatedAt);

      const dueAt = normalizeTimestamp(item.dueAt, "");

      return {
        id: collapseWhitespace(item.id) || randomUUID(),
        title,
        completed: Boolean(item.completed),
        createdAt,
        updatedAt,
        dueAt,
        appleId: collapseWhitespace(item.appleId),
        source: collapseWhitespace(item.source) || "local",
        syncUpdatedAt
      };
    })
    .filter(Boolean);

  const selectedIndex = Number.isInteger(source.selectedIndex)
    ? Math.min(Math.max(source.selectedIndex, 0), Math.max(items.length - 1, 0))
    : items.length > 0
      ? 0
      : -1;

  return {
    version: TODO_FILE_VERSION,
    items,
    selectedIndex: items.length === 0 ? -1 : selectedIndex
  };
}

function createDefaultTodoState() {
  const now = new Date().toISOString();
  return {
    version: TODO_FILE_VERSION,
    items: DEFAULT_TODO_ITEMS.map((title) => ({
      id: randomUUID(),
      title,
      completed: false,
      createdAt: now,
      updatedAt: now,
      dueAt: "",
      appleId: "",
      source: "seed",
      syncUpdatedAt: now
    })),
    selectedIndex: 0
  };
}

function writeJsonAtomic(filePath, payload) {
  const directory = path.dirname(filePath);
  fs.mkdirSync(directory, { recursive: true });
  const tempPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tempPath, payload, "utf8");
  fs.renameSync(tempPath, filePath);
}

export function formatTodoDueShort(value) {
  const iso = normalizeTimestamp(value, "");
  if (!iso) {
    return "";
  }
  const date = new Date(iso);
  const now = new Date();
  const isToday =
    date.getFullYear() === now.getFullYear() &&
    date.getMonth() === now.getMonth() &&
    date.getDate() === now.getDate();
  const hour = String(date.getHours()).padStart(2, "0");
  const minute = String(date.getMinutes()).padStart(2, "0");
  if (isToday) {
    return `${hour}:${minute}`;
  }
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${month}/${day} ${hour}:${minute}`;
}

export function parseTodoVoiceCommand(input) {
  const text = collapseWhitespace(input);
  if (!text) {
    return {
      ok: false,
      message: "请说：查看计划、添加计划 XXX、删除计划 2、修改计划 2 改成 XXX"
    };
  }

  if (/^(?:查看|显示|列出)(?:计划|待办|todo)(?:列表)?$/iu.test(text)) {
    return { ok: true, action: "list" };
  }

  if (/^(?:(?:删除|删掉|清空)(?:全部|所有|全都)?(?:计划|待办|todo)(?:列表)?|(?:全部|全都|所有)(?:删除|删掉))$/iu.test(text)) {
    return { ok: true, action: "clear" };
  }

  const createMatch = text.match(/^(?:添加(?:一个)?|新增|增加|加一个)(?:计划|待办|todo)?\s*(.*)$/iu);
  if (createMatch) {
    const title = normalizeTitle(createMatch[1]);
    if (!title) {
      return { ok: false, message: "请说：添加计划 XXX" };
    }
    const dueAt = parseLooseDueAt(title);
    return dueAt
      ? { ok: true, action: "create", text: title, dueAt }
      : { ok: true, action: "create", text: title };
  }

  const deleteMatch = text.match(/^(?:删除|删掉)(?:计划|待办|todo)\s*(?:第)?([0-9]+)(?:项)?$/iu);
  if (deleteMatch) {
    return { ok: true, action: "delete", index: Number.parseInt(deleteMatch[1], 10) };
  }
  if (/^(?:删除|删掉)(?:计划|待办|todo)$/iu.test(text)) {
    return { ok: false, message: "请说：删除计划 2" };
  }

  const updateMatch = text.match(
    /^(?:修改|更新)(?:计划|待办|todo)\s*(?:第)?([0-9]+)(?:项)?\s*(?:改成|为|成)\s*(.*)$/iu
  );
  if (updateMatch) {
    const title = normalizeTitle(updateMatch[2]);
    return title
      ? {
          ok: true,
          action: "update",
          index: Number.parseInt(updateMatch[1], 10),
          text: title
        }
      : { ok: false, message: "请说：修改计划 2 改成 XXX" };
  }
  if (/^(?:修改|更新)(?:计划|待办|todo)\s*(?:第)?[0-9]+(?:项)?$/iu.test(text)) {
    return { ok: false, message: "请说：修改计划 2 改成 XXX" };
  }

  const completeMatch = text.match(/^(?:完成|勾选)(?:计划|待办|todo)\s*(?:第)?([0-9]+)(?:项)?$/iu);
  if (completeMatch) {
    return {
      ok: true,
      action: "toggle",
      index: Number.parseInt(completeMatch[1], 10),
      completed: true
    };
  }

  const uncompleteMatch = text.match(
    /^(?:取消完成|取消勾选)(?:计划|待办|todo)\s*(?:第)?([0-9]+)(?:项)?$/iu
  );
  if (uncompleteMatch) {
    return {
      ok: true,
      action: "toggle",
      index: Number.parseInt(uncompleteMatch[1], 10),
      completed: false
    };
  }

  return {
    ok: false,
    message: "请说：查看计划、添加计划 XXX、删除计划 2、修改计划 2 改成 XXX"
  };
}

export class TodoService {
  constructor({ storagePath, seedDefaultItems = true }) {
    this.storagePath = storagePath;
    this.seedDefaultItems = seedDefaultItems;
    this.lastActionText = "";
    this.changeListeners = new Set();
    const loaded = this.#loadState();
    this.items = loaded.items;
    this.selectedIndex = loaded.selectedIndex;
    if (loaded.seeded && this.storagePath) {
      this.#persist();
    }
  }

  onChange(listener) {
    if (typeof listener !== "function") {
      return () => {};
    }
    this.changeListeners.add(listener);
    return () => {
      this.changeListeners.delete(listener);
    };
  }

  getSnapshot() {
    const items = this.items.map(cloneItem);
    const { activeItems, archiveItems } = splitItemsByCompletion(items);
    const selectedId = this.items[this.selectedIndex]?.id || "";
    const matchedIndex = selectedId
      ? activeItems.findIndex((item) => item.id === selectedId)
      : -1;
    const activeSelectedIndex = matchedIndex >= 0 ? matchedIndex : (activeItems.length > 0 ? 0 : -1);
    return {
      items: activeItems,
      archiveItems,
      selectedIndex: activeSelectedIndex,
      lastActionText: this.lastActionText
    };
  }

  getDirtySyncItems({ includeSeed = false } = {}) {
    return this.items
      .filter((item) => {
        const source = item.source || "local";
        if (!includeSeed && source === "seed") {
          return false;
        }
        if (!item.appleId) {
          return source === "local";
        }
        return source === "local" || timestampMs(item.updatedAt) > timestampMs(item.syncUpdatedAt);
      })
      .map(cloneItem);
  }

  runCommand(command) {
    const action = collapseWhitespace(command?.action).toLowerCase();
    switch (action) {
      case "list":
        return this.list();
      case "create":
        return this.create(command?.text, { dueAt: command?.dueAt });
      case "update": {
        const hasDueAt = command && Object.prototype.hasOwnProperty.call(command, "dueAt");
        return this.update(command?.index, command?.text, command?.id, {
          hasDueAt,
          dueAt: command?.dueAt
        });
      }
      case "delete":
        return this.delete(command?.index, command?.id);
      case "clear":
        return this.clear();
      case "toggle":
        return this.toggle(command?.index, command?.completed, command?.id);
      case "select_next":
        return this.selectNext();
      case "select_prev":
        return this.selectPrev();
      default:
        throw new Error(`unsupported_todo_action:${action || "unknown"}`);
    }
  }

  list() {
    const count = this.items.length;
    this.lastActionText = count === 0 ? "暂无计划" : `共有 ${count} 条计划`;
    return {
      ok: true,
      action: "list",
      changed: false,
      message: this.lastActionText,
      snapshot: this.getSnapshot()
    };
  }

  create(text, options = {}) {
    const title = normalizeTitle(text);
    if (!title) {
      throw new Error("todo_title_required");
    }

    const now = new Date().toISOString();
    const item = {
      id: randomUUID(),
      title,
      completed: false,
      createdAt: now,
      updatedAt: now,
      dueAt: normalizeTimestamp(options?.dueAt, ""),
      appleId: "",
      source: "local",
      syncUpdatedAt: ""
    };
    this.items.push(item);
    this.selectedIndex = this.items.length - 1;
    this.lastActionText = `已添加计划 ${this.items.length}`;
    this.#persist();

    const result = {
      ok: true,
      action: "create",
      changed: true,
      message: this.lastActionText,
      item: cloneItem(item),
      snapshot: this.getSnapshot()
    };
    this.#emitChange(result);
    return result;
  }

  update(index, text, id, options = {}) {
    const resolvedIndex = this.#resolveIndex(index, id);
    const hasTitle = text !== undefined;
    const hasDueAt = Boolean(options?.hasDueAt);
    if (!hasTitle && !hasDueAt) {
      throw new Error("todo_update_payload_required");
    }

    const item = this.items[resolvedIndex];

    if (hasTitle) {
      const title = normalizeTitle(text);
      if (!title) {
        throw new Error("todo_title_required");
      }
      item.title = title;
    }

    if (hasDueAt) {
      item.dueAt = normalizeTimestamp(options?.dueAt, "");
    }

    item.updatedAt = new Date().toISOString();
    item.source = "local";
    this.selectedIndex = resolvedIndex;
    this.lastActionText = `已更新计划 ${resolvedIndex + 1}`;
    this.#persist();

    const result = {
      ok: true,
      action: "update",
      changed: true,
      message: this.lastActionText,
      item: cloneItem(item),
      snapshot: this.getSnapshot()
    };
    this.#emitChange(result);
    return result;
  }


  delete(index, id) {
    const resolvedIndex = this.#resolveIndex(index, id);
    const deletedItem = cloneItem(this.items[resolvedIndex]);
    this.items.splice(resolvedIndex, 1);
    if (this.items.length === 0) {
      this.selectedIndex = -1;
    } else {
      this.selectedIndex = Math.min(resolvedIndex, this.items.length - 1);
    }
    this.lastActionText = `已删除计划 ${resolvedIndex + 1}`;
    this.#persist();

    const result = {
      ok: true,
      action: "delete",
      changed: true,
      message: this.lastActionText,
      deletedItems: [deletedItem],
      snapshot: this.getSnapshot()
    };
    this.#emitChange(result);
    return result;
  }

  clear() {
    const count = this.items.length;
    const deletedItems = this.items.map(cloneItem);
    this.items = [];
    this.selectedIndex = -1;
    this.lastActionText = count === 0 ? "暂无计划可删除" : `已删除全部 ${count} 条计划`;
    this.#persist();

    const result = {
      ok: true,
      action: "clear",
      changed: count > 0,
      message: this.lastActionText,
      deletedItems,
      snapshot: this.getSnapshot()
    };
    if (count > 0) {
      this.#emitChange(result);
    }
    return result;
  }

  toggle(index, completed, id) {
    const resolvedIndex = this.#resolveIndex(index, id);
    const item = this.items[resolvedIndex];
    item.completed = typeof completed === "boolean" ? completed : !item.completed;
    item.updatedAt = new Date().toISOString();
    item.source = "local";
    this.selectedIndex = resolvedIndex;
    this.lastActionText = item.completed
      ? `已完成计划 ${resolvedIndex + 1}`
      : `已恢复计划 ${resolvedIndex + 1}`;
    this.#persist();

    const result = {
      ok: true,
      action: "toggle",
      changed: true,
      message: this.lastActionText,
      item: cloneItem(item),
      snapshot: this.getSnapshot()
    };
    this.#emitChange(result);
    return result;
  }

  selectNext() {
    if (this.items.length === 0) {
      this.lastActionText = "暂无计划";
      return {
        ok: true,
        action: "select_next",
        changed: false,
        message: this.lastActionText,
        snapshot: this.getSnapshot()
      };
    }

    const current = this.selectedIndex < 0
      ? 0
      : Math.min(Math.max(this.selectedIndex, 0), this.items.length - 1);
    const nextIndex = (current + 1) % this.items.length;
    const changed = nextIndex !== this.selectedIndex;
    this.selectedIndex = nextIndex;
    this.lastActionText = `当前计划 ${this.selectedIndex + 1}`;
    this.#persist();
    return {
      ok: true,
      action: "select_next",
      changed,
      message: this.lastActionText,
      snapshot: this.getSnapshot()
    };
  }

  selectPrev() {
    if (this.items.length === 0) {
      this.lastActionText = "暂无计划";
      return {
        ok: true,
        action: "select_prev",
        changed: false,
        message: this.lastActionText,
        snapshot: this.getSnapshot()
      };
    }

    const current = this.selectedIndex < 0
      ? 0
      : Math.min(Math.max(this.selectedIndex, 0), this.items.length - 1);
    const nextIndex = (current - 1 + this.items.length) % this.items.length;
    const changed = nextIndex !== this.selectedIndex;
    this.selectedIndex = nextIndex;
    this.lastActionText = `当前计划 ${this.selectedIndex + 1}`;
    this.#persist();
    return {
      ok: true,
      action: "select_prev",
      changed,
      message: this.lastActionText,
      snapshot: this.getSnapshot()
    };
  }

  applyRemoteReminder(reminder) {
    const appleId = collapseWhitespace(reminder?.appleId || reminder?.id);
    if (!appleId) {
      throw new Error("apple_reminder_id_required");
    }
    const title = normalizeTitle(reminder?.title);
    if (!title) {
      throw new Error("todo_title_required");
    }

    const remoteUpdatedAt = normalizeTimestamp(reminder?.updatedAt, new Date().toISOString());
    const remoteCompleted = Boolean(reminder?.completed);

    let item = this.items.find((candidate) => candidate.appleId === appleId);
    if (!item) {
      item = {
        id: randomUUID(),
        title,
        completed: remoteCompleted,
        createdAt: remoteUpdatedAt,
        updatedAt: remoteUpdatedAt,
        dueAt: normalizeTimestamp(reminder?.dueDate || reminder?.dueAt, ""),
        appleId,
        source: "apple",
        syncUpdatedAt: remoteUpdatedAt
      };
      this.items.push(item);
      if (this.selectedIndex < 0) {
        this.selectedIndex = 0;
      }
      this.lastActionText = "苹果待办已同步";
      this.#persist();
      return { changed: true, item: cloneItem(item), created: true };
    }

    const remoteIsNewer = timestampMs(remoteUpdatedAt) >= timestampMs(item.updatedAt);
    if (!remoteIsNewer && item.source === "local") {
      return { changed: false, item: cloneItem(item), created: false };
    }

    const nextDueAt = normalizeTimestamp(reminder?.dueDate || reminder?.dueAt, "");
    const changed =
      item.title !== title ||
      item.completed !== remoteCompleted ||
      item.dueAt !== nextDueAt ||
      item.appleId !== appleId ||
      item.source !== "apple" ||
      item.syncUpdatedAt !== remoteUpdatedAt ||
      item.updatedAt !== remoteUpdatedAt;

    if (!changed) {
      return { changed: false, item: cloneItem(item), created: false };
    }

    item.title = title;
    item.completed = remoteCompleted;
    item.dueAt = nextDueAt;
    item.appleId = appleId;
    item.source = "apple";
    item.updatedAt = remoteUpdatedAt;
    item.syncUpdatedAt = remoteUpdatedAt;
    this.lastActionText = "苹果待办已同步";
    this.#persist();

    return { changed: true, item: cloneItem(item), created: false };
  }

  pruneRemoteMissingAppleIds(presentAppleIds) {
    const present = presentAppleIds instanceof Set ? presentAppleIds : new Set(presentAppleIds || []);
    const before = this.items.length;
    this.items = this.items.filter((item) => {
      if (!item.appleId) {
        return true;
      }
      if (item.source === "local") {
        return true;
      }
      return present.has(item.appleId);
    });
    if (this.items.length === before) {
      return { changed: false };
    }
    if (this.items.length === 0) {
      this.selectedIndex = -1;
    } else {
      this.selectedIndex = Math.min(Math.max(this.selectedIndex, 0), this.items.length - 1);
    }
    this.lastActionText = "苹果待办已同步";
    this.#persist();
    return { changed: true };
  }

  markItemSynced(localId, { appleId = "", syncedAt = "" } = {}) {
    const normalizedLocalId = collapseWhitespace(localId);
    if (!normalizedLocalId) {
      return { changed: false, item: null };
    }
    const item = this.items.find((candidate) => candidate.id === normalizedLocalId);
    if (!item) {
      return { changed: false, item: null };
    }

    const syncAt = normalizeTimestamp(syncedAt, new Date().toISOString());
    const nextAppleId = collapseWhitespace(appleId) || item.appleId;
    const changed =
      item.appleId !== nextAppleId ||
      item.syncUpdatedAt !== syncAt ||
      item.updatedAt !== syncAt ||
      item.source !== "apple";

    if (!changed) {
      return { changed: false, item: cloneItem(item) };
    }

    item.appleId = nextAppleId;
    item.syncUpdatedAt = syncAt;
    item.updatedAt = syncAt;
    item.source = "apple";
    this.#persist();
    return { changed: true, item: cloneItem(item) };
  }

  getAppleLinkedItemsByIds(ids) {
    const idSet = new Set(Array.isArray(ids) ? ids.map((item) => collapseWhitespace(item)) : []);
    if (idSet.size === 0) {
      return [];
    }
    return this.items
      .filter((item) => idSet.has(item.id) && item.appleId)
      .map(cloneItem);
  }

  #loadState() {
    if (!this.storagePath || !fs.existsSync(this.storagePath)) {
      return this.seedDefaultItems
        ? { ...createDefaultTodoState(), seeded: true }
        : sanitizePersistedState(null);
    }

    try {
      const parsed = JSON.parse(fs.readFileSync(this.storagePath, "utf8"));
      return sanitizePersistedState(parsed);
    } catch {
      this.#backupCorruptFile();
      return sanitizePersistedState(null);
    }
  }

  #backupCorruptFile() {
    if (!this.storagePath || !fs.existsSync(this.storagePath)) {
      return;
    }

    const backupPath = `${this.storagePath}.corrupt-${Date.now()}`;
    try {
      fs.renameSync(this.storagePath, backupPath);
    } catch {
      // ignore
    }
  }

  #persist() {
    writeJsonAtomic(
      this.storagePath,
      JSON.stringify(
        {
          version: TODO_FILE_VERSION,
          selectedIndex: this.selectedIndex,
          items: this.items.map(cloneItem)
        },
        null,
        2
      )
    );
  }

  #emitChange(result) {
    for (const listener of this.changeListeners) {
      try {
        listener(result);
      } catch {
        // ignore
      }
    }
  }

  #resolveIndex(index, id) {
    if (this.items.length === 0) {
      throw new Error("todo_empty");
    }

    const normalizedId = collapseWhitespace(id);
    if (normalizedId) {
      const resolvedIndex = this.items.findIndex((item) => item.id === normalizedId);
      if (resolvedIndex === -1) {
        throw new Error("todo_item_not_found");
      }
      return resolvedIndex;
    }

    if (index === undefined || index === null || String(index).trim() === "") {
      if (this.selectedIndex < 0 || this.selectedIndex >= this.items.length) {
        throw new Error("todo_index_required");
      }
      return this.selectedIndex;
    }

    const numericIndex = normalizePositiveInteger(index);
    if (numericIndex == null) {
      throw new Error("todo_index_invalid");
    }

    const resolvedIndex = numericIndex - 1;
    if (resolvedIndex < 0 || resolvedIndex >= this.items.length) {
      throw new Error("todo_index_out_of_range");
    }
    return resolvedIndex;
  }
}

export function createTodoService(options) {
  return new TodoService(options);
}
