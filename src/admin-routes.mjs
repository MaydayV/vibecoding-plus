import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";

import {
  listConfigFileCandidates,
  loadConfigFiles,
  readUserConfigValues
} from "./config.mjs";
import { buildAdminPageTemplate } from "./admin-page-template.mjs";
import { createRemindctlClient } from "./reminders-sync.mjs";


const ADMIN_MAX_BODY_BYTES = 1024 * 1024;

function parseBooleanInput(value) {
  if (typeof value === "boolean") {
    return value;
  }
  const text = String(value || "").trim().toLowerCase();
  return text === "1" || text === "true" || text === "yes" || text === "on";
}

function normalizeReminderListOptions(lists) {
  if (!Array.isArray(lists)) {
    return [];
  }
  return lists
    .map((item) => ({
      id: String(item?.id || "").trim(),
      title: String(item?.title || "").trim(),
      reminderCount: Number(item?.reminderCount || 0),
      overdueCount: Number(item?.overdueCount || 0)
    }))
    .filter((item) => item.id && item.title);
}

function parseEnvContent(content) {
  const values = {};
  for (const rawLine of String(content || "").split(/\r?\n/)) {
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

export function createAdminRoutes(options) {
  const {
    config,
    todoService,
    getUserTodoListPath,
    broadcastTodoState,
    getTodoSyncStatus,
    runTodoSyncNow,
    applyTodoSyncConfig = async () => ({ ok: false, applied: false, restartRequired: true }),
    applyDisplayConfig = async () => ({ ok: false, applied: false, restartRequired: true }),
    deleteTodoRemindersByItems = async () => ({ ok: false, skipped: true, reason: "delete_unavailable" }),
    shutdown
  } = options;

  function sendJsonResponse(res, statusCode, payload) {
    const body = `${JSON.stringify(payload)}\n`;
    res.writeHead(statusCode, {
      "content-type": "application/json; charset=utf-8",
      "content-length": Buffer.byteLength(body)
    });
    res.end(body);
  }

  function sendHtmlResponse(res, statusCode, html) {
    const body = String(html || "");
    res.writeHead(statusCode, {
      "content-type": "text/html; charset=utf-8",
      "content-length": Buffer.byteLength(body)
    });
    res.end(body);
  }

  function sendTextResponse(res, statusCode, text) {
    const body = String(text || "");
    res.writeHead(statusCode, {
      "content-type": "text/plain; charset=utf-8",
      "content-length": Buffer.byteLength(body)
    });
    res.end(body);
  }

  async function readRequestBody(req, maxBytes = ADMIN_MAX_BODY_BYTES) {
    return await new Promise((resolve, reject) => {
      const chunks = [];
      let total = 0;
      req.on("data", (chunk) => {
        total += chunk.length;
        if (total > maxBytes) {
          reject(new Error("request_body_too_large"));
          req.destroy();
          return;
        }
        chunks.push(chunk);
      });
      req.on("end", () => {
        resolve(Buffer.concat(chunks).toString("utf8"));
      });
      req.on("error", reject);
    });
  }

  async function readJsonBody(req) {
    const raw = await readRequestBody(req);
    const text = String(raw || "").trim();
    if (!text) {
      return {};
    }
    try {
      return JSON.parse(text);
    } catch {
      throw new Error("invalid_json_body");
    }
  }

  function getTodoApiPayload() {
    return {
      ok: true,
      snapshot: todoService.getSnapshot(),
      storagePath: getUserTodoListPath()
    };
  }

  function getCurrentSyncValues() {
    return {
      enabled: parseBooleanInput(process.env.REMINDERS_SYNC_ENABLED),
      remindctlPath: String(process.env.REMINDCTL_PATH || "remindctl").trim() || "remindctl",
      list: String(process.env.REMINDERS_LIST || "").trim(),
      pollSec: Math.max(5, Number(process.env.REMINDERS_POLL_SEC || 15))
    };
  }

  function getSyncApiPayload() {
    const values = getCurrentSyncValues();
    return {
      ok: true,
      values,
      status: typeof getTodoSyncStatus === "function" ? getTodoSyncStatus() : null
    };
  }

  function getCurrentDisplayValues() {
    return {
      todoRefreshMs: Math.min(10_000, Math.max(200, Number(process.env.DISPLAY_TODO_REFRESH_MS || config.displayTodoRefreshMs || 800))),
      codingRefreshMs: Math.min(10_000, Math.max(200, Number(process.env.DISPLAY_CODING_REFRESH_MS || config.displayCodingRefreshMs || 800))),
      style: String(process.env.DISPLAY_STYLE || config.displayStyle || "light").trim().toLowerCase() === "dark" ? "dark" : "light"
    };
  }

  function getDisplayApiPayload() {
    return {
      ok: true,
      values: getCurrentDisplayValues()
    };
  }

  async function getSyncListsApiPayload() {
    const values = getCurrentSyncValues();
    const localConfig = {
      remindersRemindctlPath: values.remindctlPath,
      remindersListName: "",
      remindersRemindctlTimeoutMs: Number(config.remindersRemindctlTimeoutMs || 20_000)
    };
    const client = createRemindctlClient(localConfig);
    const lists = await client.listReminderLists();
    return {
      ok: true,
      lists: normalizeReminderListOptions(lists)
    };
  }

  function getAdminEnvPath() {
    const preferred = String(config.cwdConfigPath || config.projectConfigPath || config.userConfigPath || "").trim();
    return preferred || config.userConfigPath;
  }

  function writeAdminConfigValues(updates) {
    const envPath = getAdminEnvPath();
    const currentValues = fs.existsSync(envPath)
      ? parseEnvContent(fs.readFileSync(envPath, "utf8"))
      : {};
    const nextValues = { ...currentValues };

    for (const [key, value] of Object.entries(updates)) {
      if (value === undefined) {
        continue;
      }
      if (value === null) {
        delete nextValues[key];
        continue;
      }
      nextValues[key] = String(value).replace(/\r?\n/g, " ").trim();
    }

    const keys = Object.keys(nextValues).sort((left, right) => left.localeCompare(right));
    const content = `${keys.map((key) => `${key}=${nextValues[key]}`).join("\n")}\n`;

    fs.mkdirSync(path.dirname(envPath), { recursive: true });
    fs.writeFileSync(envPath, content, "utf8");
    return envPath;
  }

  function getEnvApiPayload() {
    const envPath = getAdminEnvPath();
    const content = fs.existsSync(envPath) ? fs.readFileSync(envPath, "utf8") : "";
    return {
      ok: true,
      path: envPath,
      candidates: listConfigFileCandidates(),
      values: readUserConfigValues(),
      content
    };
  }

  function applyEnvFileContent(content) {
    const normalized = String(content || "");
    const envPath = getAdminEnvPath();
    fs.mkdirSync(path.dirname(envPath), { recursive: true });
    fs.writeFileSync(envPath, normalized, "utf8");
    loadConfigFiles({ quietMissing: true });
    return envPath;
  }

  async function handleAdminApi(req, res, pathname) {
    if (pathname === "/api/admin/todos") {
      if (req.method === "GET") {
        sendJsonResponse(res, 200, getTodoApiPayload());
        return true;
      }

      if (req.method === "POST") {
        const body = await readJsonBody(req);
        const title = String(body.title || "").trim();
        if (!title) {
          sendJsonResponse(res, 400, { ok: false, error: "todo_title_required" });
          return true;
        }
        todoService.runCommand({ action: "create", text: title, dueAt: body.dueAt });
        broadcastTodoState();
        sendJsonResponse(res, 200, getTodoApiPayload());
        return true;
      }

      if (req.method === "PUT") {
        const body = await readJsonBody(req);
        const id = String(body.id || "").trim();
        const index = body.index;
        const hasTitle = body.title !== undefined;
        const hasCompleted = typeof body.completed === "boolean";
        const hasDueAt = body.dueAt !== undefined;
        if (!hasTitle && !hasCompleted && !hasDueAt) {
          sendJsonResponse(res, 400, { ok: false, error: "todo_update_payload_required" });
          return true;
        }
        if (hasTitle || hasDueAt) {
          todoService.runCommand({ action: "update", id, index, text: body.title, dueAt: body.dueAt });
        }
        if (hasCompleted) {
          todoService.runCommand({ action: "toggle", id, index, completed: body.completed });
        }
        broadcastTodoState();
        sendJsonResponse(res, 200, getTodoApiPayload());
        return true;
      }


      if (req.method === "DELETE") {
        const body = await readJsonBody(req);
        const id = String(body.id || "").trim();
        const beforeItems = todoService.getAppleLinkedItemsByIds(id ? [id] : []);
        const deleteResult = todoService.runCommand({ action: "delete", id, index: body.index });

        const deletedItems = Array.isArray(deleteResult?.deletedItems) ? deleteResult.deletedItems : [];
        const linkedDeletedItems = beforeItems.length > 0
          ? beforeItems
          : deletedItems.filter((item) => item?.appleId);

        let remoteDelete = { ok: true, skipped: true, reason: "no_remote_link", deleted: 0, failed: 0, errors: [] };
        if (linkedDeletedItems.length > 0) {
          remoteDelete = await deleteTodoRemindersByItems(linkedDeletedItems);
        }

        broadcastTodoState();
        sendJsonResponse(res, 200, {
          ...getTodoApiPayload(),
          remoteDelete
        });
        return true;
      }
    }

    if (pathname === "/api/admin/todo-sync") {
      if (req.method === "GET") {
        sendJsonResponse(res, 200, getSyncApiPayload());
        return true;
      }

      if (req.method === "POST") {
        const body = await readJsonBody(req);
        const updates = {
          REMINDERS_SYNC_ENABLED: parseBooleanInput(body.enabled) ? "1" : "0",
          REMINDCTL_PATH: String(body.remindctlPath || "").trim() || "remindctl",
          REMINDERS_LIST: String(body.list || "").trim(),
          REMINDERS_POLL_SEC: String(Math.max(5, Number(body.pollSec || 15)))
        };
        writeAdminConfigValues(updates);
        loadConfigFiles({ quietMissing: true });

        let applyResult = { ok: false, applied: false, restartRequired: true, status: null, error: "" };
        try {
          applyResult = await applyTodoSyncConfig();
        } catch (error) {
          applyResult = {
            ok: false,
            applied: false,
            restartRequired: true,
            status: typeof getTodoSyncStatus === "function" ? getTodoSyncStatus() : null,
            error: error instanceof Error ? error.message : String(error)
          };
        }

        sendJsonResponse(res, 200, {
          ok: true,
          saved: true,
          applied: Boolean(applyResult.applied),
          restartRequired: Boolean(applyResult.restartRequired),
          values: updates,
          status: applyResult.status || (typeof getTodoSyncStatus === "function" ? getTodoSyncStatus() : null),
          error: String(applyResult.error || "")
        });
        return true;
      }
    }

    if (pathname === "/api/admin/display-config") {
      if (req.method === "GET") {
        sendJsonResponse(res, 200, getDisplayApiPayload());
        return true;
      }

      if (req.method === "POST") {
        const body = await readJsonBody(req);
        const nextValues = {
          todoRefreshMs: Math.min(10_000, Math.max(200, Number(body.todoRefreshMs || 800))),
          codingRefreshMs: Math.min(10_000, Math.max(200, Number(body.codingRefreshMs || 800))),
          style: String(body.style || "light").trim().toLowerCase() === "dark" ? "dark" : "light"
        };

        const updates = {
          DISPLAY_TODO_REFRESH_MS: String(nextValues.todoRefreshMs),
          DISPLAY_CODING_REFRESH_MS: String(nextValues.codingRefreshMs),
          DISPLAY_STYLE: nextValues.style
        };
        writeAdminConfigValues(updates);
        loadConfigFiles({ quietMissing: true });

        let applyResult = { ok: false, applied: false, restartRequired: true, error: "" };
        try {
          applyResult = await applyDisplayConfig(nextValues);
        } catch (error) {
          applyResult = {
            ok: false,
            applied: false,
            restartRequired: true,
            error: error instanceof Error ? error.message : String(error)
          };
        }

        sendJsonResponse(res, 200, {
          ok: true,
          saved: true,
          applied: Boolean(applyResult.applied),
          restartRequired: Boolean(applyResult.restartRequired),
          values: nextValues,
          error: String(applyResult.error || "")
        });
        return true;
      }
    }

    if (pathname === "/api/admin/todo-sync/lists" && req.method === "GET") {
      const payload = await getSyncListsApiPayload();
      sendJsonResponse(res, 200, payload);
      return true;
    }

    if (pathname === "/api/admin/todo-sync/run" && req.method === "POST") {
      const body = await readJsonBody(req);
      const reason = String(body.reason || "manual").trim() || "manual";
      const result = typeof runTodoSyncNow === "function"
        ? await runTodoSyncNow(reason)
        : { ok: false, skipped: true, reason: "sync_unavailable" };
      sendJsonResponse(res, 200, {
        ok: Boolean(result?.ok),
        changed: Boolean(result?.changed),
        skipped: Boolean(result?.skipped),
        reason: String(result?.reason || reason),
        error: result?.error || "",
        status: result?.status || (typeof getTodoSyncStatus === "function" ? getTodoSyncStatus() : null)
      });
      return true;
    }

    if (pathname === "/api/admin/env") {
      if (req.method === "GET") {
        sendJsonResponse(res, 200, getEnvApiPayload());
        return true;
      }

      if (req.method === "POST") {
        const body = await readJsonBody(req);
        if (body.content !== undefined) {
          applyEnvFileContent(body.content);
        } else if (body.values && typeof body.values === "object") {
          writeAdminConfigValues(body.values);
          loadConfigFiles({ quietMissing: true });
        } else {
          sendJsonResponse(res, 400, { ok: false, error: "env_payload_required" });
          return true;
        }
        sendJsonResponse(res, 200, getEnvApiPayload());
        return true;
      }
    }

    if (pathname === "/api/admin/restart" && req.method === "POST") {
      const nextArgs = process.argv.slice(1);
      try {
        const child = spawn(process.execPath, nextArgs, {
          cwd: process.cwd(),
          env: process.env,
          detached: true,
          stdio: "ignore"
        });
        child.unref();
        sendJsonResponse(res, 200, { ok: true, restarting: true, pid: process.pid });
        setTimeout(() => {
          shutdown();
        }, 80).unref?.();
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        sendJsonResponse(res, 500, { ok: false, error: message || "restart_failed" });
      }
      return true;
    }

    return false;
  }

  function handleRequest(req, res) {
    const method = String(req.method || "GET").toUpperCase();
    const requestUrl = new URL(req.url || "/", "http://localhost");
    const pathname = requestUrl.pathname;

    if (method === "GET" && pathname === "/admin") {
      sendHtmlResponse(res, 200, buildAdminPageTemplate());
      return;
    }

    if (pathname.startsWith("/api/admin/")) {
      void handleAdminApi(req, res, pathname)
        .then((handled) => {
          if (!handled) {
            sendJsonResponse(res, 404, { ok: false, error: "not_found" });
          }
        })
        .catch((error) => {
          const message = error instanceof Error ? error.message : String(error);
          sendJsonResponse(res, 500, { ok: false, error: message || "internal_error" });
        });
      return;
    }

    if (method === "GET" && pathname === "/healthz") {
      sendTextResponse(res, 200, "ok\n");
      return;
    }

    sendJsonResponse(res, 404, { ok: false, error: "not_found" });
  }

  return { handleRequest };
}
