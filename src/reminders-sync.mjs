import { execFile } from "node:child_process";

function parseBool(value) {
  if (typeof value === "boolean") {
    return value;
  }
  const text = String(value || "").trim().toLowerCase();
  return text === "1" || text === "true" || text === "yes" || text === "on";
}

function normalizeIso(value, fallback = "") {
  const text = String(value || "").trim();
  if (!text) {
    return fallback;
  }
  const parsed = Date.parse(text);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return new Date(parsed).toISOString();
}

function nowIso() {
  return new Date().toISOString();
}

function normalizeReminderRow(row) {
  if (!row || typeof row !== "object") {
    return null;
  }
  const id = String(row.id || "").trim();
  const title = String(row.title || "").trim();
  if (!id || !title) {
    return null;
  }

  const completed = Boolean(row.isCompleted ?? row.completed);
  const updatedAt = normalizeIso(
    row.updatedAt || row.modificationDate || row.lastModifiedAt || row.completionDate || row.createdAt,
    nowIso()
  );

  return {
    id,
    title,
    completed,
    listName: String(row.listName || row.list || "").trim(),
    notes: String(row.notes || "").trim(),
    dueDate: normalizeIso(row.dueDate || ""),
    updatedAt
  };
}

function runExecFile(command, args, { timeoutMs = 20_000, cwd = process.cwd() } = {}) {
  return new Promise((resolve, reject) => {
    execFile(command, args, { timeout: timeoutMs, cwd, encoding: "utf8" }, (error, stdout, stderr) => {
      if (error) {
        const message = String(stderr || stdout || error.message || "remindctl_failed").trim();
        reject(new Error(message));
        return;
      }
      resolve({ stdout: String(stdout || ""), stderr: String(stderr || "") });
    });
  });
}

export function createRemindctlClient(config) {
  const command = String(config.remindersRemindctlPath || "remindctl").trim() || "remindctl";
  const listName = String(config.remindersListName || "").trim();
  const timeoutMs = Math.max(3000, Number(config.remindersRemindctlTimeoutMs || 20_000));

  async function run(args) {
    return await runExecFile(command, args, {
      timeoutMs,
      cwd: process.cwd()
    });
  }

  async function listReminders() {
    const args = ["all", "--json"];
    if (listName) {
      args.push("--list", listName);
    }
    const { stdout } = await run(args);
    let parsed;
    try {
      parsed = JSON.parse(stdout || "[]");
    } catch {
      throw new Error("remindctl_json_parse_failed");
    }
    const rows = Array.isArray(parsed) ? parsed : [];
    return rows.map(normalizeReminderRow).filter(Boolean);
  }

  async function addReminder({ title, completed = false } = {}) {
    const normalizedTitle = String(title || "").trim();
    if (!normalizedTitle) {
      throw new Error("todo_title_required");
    }

    const args = ["add", normalizedTitle, "--json"];
    if (listName) {
      args.push("--list", listName);
    }
    if (parseBool(completed)) {
      args.push("--complete");
    }
    const { stdout } = await run(args);
    let parsed;
    try {
      parsed = JSON.parse(stdout || "{}");
    } catch {
      throw new Error("remindctl_json_parse_failed");
    }
    return normalizeReminderRow(parsed) || {
      id: "",
      title: normalizedTitle,
      completed: parseBool(completed),
      listName,
      notes: "",
      dueDate: "",
      updatedAt: nowIso()
    };
  }

  async function editReminder(id, { title, completed } = {}) {
    const normalizedId = String(id || "").trim();
    if (!normalizedId) {
      throw new Error("apple_reminder_id_required");
    }

    const args = ["edit", normalizedId, "--json"];
    if (title !== undefined) {
      const normalizedTitle = String(title || "").trim();
      if (!normalizedTitle) {
        throw new Error("todo_title_required");
      }
      args.push("--title", normalizedTitle);
    }
    if (typeof completed === "boolean") {
      args.push(completed ? "--complete" : "--incomplete");
    }

    const { stdout } = await run(args);
    let parsed;
    try {
      parsed = JSON.parse(stdout || "{}");
    } catch {
      throw new Error("remindctl_json_parse_failed");
    }
    return normalizeReminderRow(parsed) || {
      id: normalizedId,
      title: String(title || "").trim(),
      completed: Boolean(completed),
      listName,
      notes: "",
      dueDate: "",
      updatedAt: nowIso()
    };
  }

  async function deleteReminder(id) {
    const normalizedId = String(id || "").trim();
    if (!normalizedId) {
      throw new Error("apple_reminder_id_required");
    }
    await run(["delete", normalizedId, "--force"]);
    return true;
  }

  async function getStatus() {
    const { stdout } = await run(["status", "--json"]);
    try {
      const parsed = JSON.parse(stdout || "{}");
      return {
        authorized: Boolean(parsed.authorized ?? parsed.ok ?? false),
        raw: parsed
      };
    } catch {
      return {
        authorized: true,
        raw: { text: stdout.trim() }
      };
    }
  }

  return {
    command,
    listName,
    listReminders,
    addReminder,
    editReminder,
    deleteReminder,
    getStatus
  };
}
