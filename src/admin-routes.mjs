import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";

import {
  listConfigFileCandidates,
  loadConfigFiles,
  readUserConfigValues,
  writeUserConfigValues
} from "./config.mjs";

const ADMIN_MAX_BODY_BYTES = 1024 * 1024;

export function createAdminRoutes(options) {
  const {
    config,
    todoService,
    getUserTodoListPath,
    broadcastTodoState,
    shutdown
  } = options;

  function buildAdminPage() {
    return `<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <title>vibecoding-plus admin</title>
    <style>
      :root {
        color-scheme: light;
        --bg: #fff;
        --fg: #111;
        --muted: #666;
        --line: #111;
        --line-soft: #ddd;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        background: var(--bg);
        color: var(--fg);
      }
      .wrap {
        max-width: 1080px;
        margin: 0 auto;
        padding: 20px;
      }
      .top {
        display: flex;
        justify-content: space-between;
        align-items: baseline;
        gap: 12px;
        margin-bottom: 12px;
      }
      h1 {
        margin: 0;
        font-size: 20px;
        letter-spacing: 0.2px;
      }
      .muted { color: var(--muted); font-size: 12px; }
      .tabs {
        display: flex;
        gap: 8px;
        margin: 12px 0 16px;
        border-bottom: 1px solid var(--line);
        padding-bottom: 8px;
      }
      .tab {
        border: 1px solid var(--line);
        background: #fff;
        color: #111;
        border-radius: 8px;
        padding: 6px 12px;
        cursor: pointer;
      }
      .tab.active {
        background: #111;
        color: #fff;
      }
      .panel { display: none; }
      .panel.active { display: block; }
      .row {
        display: flex;
        gap: 8px;
        align-items: center;
        flex-wrap: wrap;
      }
      input[type="text"], textarea {
        width: 100%;
        border: 1px solid var(--line);
        border-radius: 8px;
        padding: 8px 10px;
        font: inherit;
        background: #fff;
        color: #111;
      }
      textarea { min-height: 320px; resize: vertical; }
      button {
        border: 1px solid var(--line);
        border-radius: 8px;
        padding: 8px 12px;
        background: #fff;
        color: #111;
        cursor: pointer;
      }
      button.primary {
        background: #111;
        color: #fff;
      }
      .btn-done {
        min-width: 56px;
        min-height: 36px;
        font-weight: 600;
      }
      button:disabled { opacity: 0.5; cursor: not-allowed; }
      .card {
        border: 1px solid var(--line-soft);
        border-radius: 10px;
        padding: 12px;
        margin-bottom: 12px;
      }
      table {
        width: 100%;
        border-collapse: collapse;
      }
      th, td {
        border-bottom: 1px solid var(--line-soft);
        padding: 8px;
        text-align: left;
        vertical-align: middle;
      }
      tr.selected { background: #f4f4f4; }
      .todo-row { cursor: pointer; }
      .kbd {
        border: 1px solid var(--line);
        border-bottom-width: 2px;
        border-radius: 6px;
        padding: 1px 6px;
        font-size: 12px;
      }
      #status {
        min-height: 20px;
        margin-bottom: 8px;
        font-size: 13px;
      }
      #status.error { color: #b00020; }
      .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
      .split { display: grid; grid-template-columns: 1fr; gap: 10px; }
      @media (min-width: 900px) {
        .split { grid-template-columns: 1.6fr 1fr; }
      }
    </style>
  </head>
  <body>
    <div class="wrap">
      <div class="top">
        <h1>vibecoding-plus 管理页</h1>
        <div class="muted">黑白模式 · 快捷键支持</div>
      </div>
      <div id="status" class="muted"></div>

      <div class="tabs" id="tabs">
        <button class="tab active" data-tab="todos">Todo</button>
        <button class="tab" data-tab="env">ENV</button>
        <button class="tab" data-tab="service">Service</button>
      </div>

      <section id="panel-todos" class="panel active">
        <div class="card split">
          <div>
            <div class="row">
              <input id="newTodoTitle" type="text" placeholder="新增待办…" />
              <button id="addTodoBtn" class="primary">新增</button>
              <button id="refreshTodoBtn">刷新</button>
            </div>
            <div class="muted" style="margin-top:8px;">
              <span class="kbd">N</span> 聚焦新增，<span class="kbd">Delete</span> 删除选中，行点击即可选中
            </div>
          </div>
          <div class="muted mono" id="todoPath"></div>
        </div>

        <div class="card">
          <table>
            <thead>
              <tr>
                <th style="width:84px;">完成</th>
                <th>标题</th>
                <th style="width:180px;">操作</th>
              </tr>
            </thead>
            <tbody id="todoTableBody"></tbody>
          </table>
        </div>
      </section>

      <section id="panel-env" class="panel">
        <div class="card">
          <div class="muted mono" id="envPath"></div>
          <div class="muted" id="envCandidates" style="margin-top:4px;"></div>
        </div>
        <div class="card">
          <textarea id="envEditor" spellcheck="false"></textarea>
          <div class="row" style="margin-top:8px;">
            <button id="saveEnvBtn" class="primary">保存 ENV 文件</button>
            <button id="refreshEnvBtn">刷新</button>
          </div>
        </div>
      </section>

      <section id="panel-service" class="panel">
        <div class="card">
          <div class="muted">可直接重启当前 Node 服务进程。</div>
          <div class="row" style="margin-top:8px;">
            <button id="restartBtn" class="primary">重启服务</button>
          </div>
        </div>
      </section>

      <div class="muted" style="margin-top:10px;">
        快捷键：<span class="kbd">⌘/Ctrl+1/2/3</span> 切换 tab，<span class="kbd">⌘/Ctrl+S</span> 保存，<span class="kbd">⌘/Ctrl+R</span> 重启服务
      </div>
    </div>

    <script>
      const state = {
        tab: "todos",
        todos: [],
        selectedTodoId: "",
        envContent: "",
        envDirty: false,
        pollingTimer: null
      };

      const $ = (id) => document.getElementById(id);
      const statusEl = $("status");
      const todoBodyEl = $("todoTableBody");

      function setStatus(message, isError = false) {
        statusEl.textContent = message || "";
        statusEl.className = isError ? "error" : "muted";
      }

      async function api(path, options = {}) {
        const response = await fetch(path, {
          headers: { "content-type": "application/json" },
          ...options
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok || payload.ok === false) {
          throw new Error(payload.error || payload.message || "request_failed");
        }
        return payload;
      }

      function switchTab(nextTab) {
        if (!nextTab || !["todos", "env", "service"].includes(nextTab)) return;
        state.tab = nextTab;
        document.querySelectorAll(".tab").forEach((el) => {
          el.classList.toggle("active", el.dataset.tab === nextTab);
        });
        document.querySelectorAll(".panel").forEach((el) => {
          el.classList.toggle("active", el.id === "panel-" + nextTab);
        });
      }

      function renderTodos() {
        todoBodyEl.innerHTML = "";
        if (!Array.isArray(state.todos) || state.todos.length === 0) {
          const row = document.createElement("tr");
          row.innerHTML = '<td colspan="3" class="muted">暂无待办</td>';
          todoBodyEl.appendChild(row);
          return;
        }

        for (const item of state.todos) {
          const tr = document.createElement("tr");
          tr.className = "todo-row" + (item.id === state.selectedTodoId ? " selected" : "");
          tr.addEventListener("click", () => {
            state.selectedTodoId = item.id;
            renderTodos();
          });

          const doneTd = document.createElement("td");
          const doneBtn = document.createElement("button");
          doneBtn.className = "btn-done";
          doneBtn.textContent = item.completed ? "已完成" : "未完成";
          doneBtn.addEventListener("click", async (event) => {
            event.stopPropagation();
            try {
              await api("/api/admin/todos", {
                method: "PUT",
                body: JSON.stringify({ id: item.id, completed: !item.completed })
              });
              await loadTodos();
              setStatus("待办状态已更新");
            } catch (error) {
              setStatus(error.message, true);
            }
          });
          doneTd.appendChild(doneBtn);

          const titleTd = document.createElement("td");
          const titleInput = document.createElement("input");
          titleInput.type = "text";
          titleInput.value = item.title;
          titleInput.addEventListener("focus", () => {
            state.selectedTodoId = item.id;
            renderTodos();
          });
          titleTd.appendChild(titleInput);

          const actionTd = document.createElement("td");
          const saveBtn = document.createElement("button");
          saveBtn.textContent = "保存";
          saveBtn.addEventListener("click", async (event) => {
            event.stopPropagation();
            try {
              await api("/api/admin/todos", {
                method: "PUT",
                body: JSON.stringify({ id: item.id, title: titleInput.value })
              });
              await loadTodos();
              setStatus("待办标题已保存");
            } catch (error) {
              setStatus(error.message, true);
            }
          });

          const delBtn = document.createElement("button");
          delBtn.textContent = "删除";
          delBtn.addEventListener("click", async (event) => {
            event.stopPropagation();
            try {
              await api("/api/admin/todos", {
                method: "DELETE",
                body: JSON.stringify({ id: item.id })
              });
              await loadTodos();
              setStatus("待办已删除");
            } catch (error) {
              setStatus(error.message, true);
            }
          });

          actionTd.appendChild(saveBtn);
          actionTd.appendChild(delBtn);
          actionTd.className = "row";

          tr.appendChild(doneTd);
          tr.appendChild(titleTd);
          tr.appendChild(actionTd);
          todoBodyEl.appendChild(tr);
        }
      }

      async function loadTodos() {
        const payload = await api("/api/admin/todos");
        state.todos = payload.snapshot?.items || [];
        state.selectedTodoId = state.todos.some((item) => item.id === state.selectedTodoId)
          ? state.selectedTodoId
          : (state.todos[0]?.id || "");
        $("todoPath").textContent = "文件：" + (payload.storagePath || "");
        renderTodos();
      }

      async function addTodo() {
        const title = $("newTodoTitle").value.trim();
        if (!title) {
          setStatus("请输入待办标题", true);
          return;
        }
        await api("/api/admin/todos", {
          method: "POST",
          body: JSON.stringify({ title })
        });
        $("newTodoTitle").value = "";
        await loadTodos();
        setStatus("待办已新增");
      }

      async function deleteSelectedTodo() {
        if (!state.selectedTodoId) {
          setStatus("请先选中一条待办", true);
          return;
        }
        await api("/api/admin/todos", {
          method: "DELETE",
          body: JSON.stringify({ id: state.selectedTodoId })
        });
        await loadTodos();
        setStatus("待办已删除");
      }

      async function loadEnv(options = {}) {
        const payload = await api("/api/admin/env");
        if (!state.envDirty || options.force) {
          state.envContent = payload.content || "";
          $("envEditor").value = state.envContent;
          state.envDirty = false;
        }
        $("envPath").textContent = "文件：" + (payload.path || "");
        $("envCandidates").textContent = "加载候选：" + ((payload.candidates || []).join(" | "));
      }

      async function saveEnv() {
        const content = $("envEditor").value;
        await api("/api/admin/env", {
          method: "POST",
          body: JSON.stringify({ content })
        });
        state.envContent = content;
        state.envDirty = false;
        setStatus("ENV 文件已保存并重新加载");
      }

      async function restartService() {
        if (!confirm("确认重启当前服务吗？")) {
          return;
        }
        await api("/api/admin/restart", { method: "POST", body: "{}" });
        setStatus("服务重启中，页面会短暂断开", false);
      }

      function startPolling() {
        if (state.pollingTimer) {
          clearInterval(state.pollingTimer);
        }
        state.pollingTimer = setInterval(() => {
          if (state.tab === "todos") {
            void loadTodos().catch(() => {});
          } else if (state.tab === "env" && !state.envDirty) {
            void loadEnv().catch(() => {});
          }
        }, 2000);
      }

      document.querySelectorAll(".tab").forEach((btn) => {
        btn.addEventListener("click", () => switchTab(btn.dataset.tab));
      });

      $("addTodoBtn").addEventListener("click", () => void addTodo().catch((e) => setStatus(e.message, true)));
      $("refreshTodoBtn").addEventListener("click", () => void loadTodos().catch((e) => setStatus(e.message, true)));
      $("saveEnvBtn").addEventListener("click", () => void saveEnv().catch((e) => setStatus(e.message, true)));
      $("refreshEnvBtn").addEventListener("click", () => void loadEnv({ force: true }).catch((e) => setStatus(e.message, true)));
      $("restartBtn").addEventListener("click", () => void restartService().catch((e) => setStatus(e.message, true)));
      $("envEditor").addEventListener("input", () => { state.envDirty = true; });

      window.addEventListener("keydown", (event) => {
        const key = String(event.key || "").toLowerCase();
        const command = event.metaKey || event.ctrlKey;

        if (command && key === "1") {
          event.preventDefault();
          switchTab("todos");
          return;
        }
        if (command && key === "2") {
          event.preventDefault();
          switchTab("env");
          return;
        }
        if (command && key === "3") {
          event.preventDefault();
          switchTab("service");
          return;
        }

        if (command && key === "s") {
          event.preventDefault();
          if (state.tab === "env") {
            void saveEnv().catch((e) => setStatus(e.message, true));
          } else if (state.tab === "todos") {
            void addTodo().catch((e) => setStatus(e.message, true));
          }
          return;
        }

        if (command && key === "r") {
          event.preventDefault();
          void restartService().catch((e) => setStatus(e.message, true));
          return;
        }

        if (!command && key === "n" && state.tab === "todos") {
          event.preventDefault();
          $("newTodoTitle").focus();
          return;
        }

        if (!command && key === "delete" && state.tab === "todos") {
          event.preventDefault();
          void deleteSelectedTodo().catch((e) => setStatus(e.message, true));
        }
      });

      Promise.all([loadTodos(), loadEnv()])
        .then(() => {
          startPolling();
          setStatus("管理页已就绪");
        })
        .catch((error) => setStatus(error.message || String(error), true));
    </script>
  </body>
</html>`;
  }

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

  function getAdminEnvPath() {
    const preferred = String(config.cwdConfigPath || config.projectConfigPath || config.userConfigPath || "").trim();
    return preferred || config.userConfigPath;
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
        todoService.runCommand({ action: "create", text: title });
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
        if (!hasTitle && !hasCompleted) {
          sendJsonResponse(res, 400, { ok: false, error: "todo_update_payload_required" });
          return true;
        }
        if (hasTitle) {
          todoService.runCommand({ action: "update", id, index, text: body.title });
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
        todoService.runCommand({ action: "delete", id, index: body.index });
        broadcastTodoState();
        sendJsonResponse(res, 200, getTodoApiPayload());
        return true;
      }
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
          writeUserConfigValues(body.values);
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
      sendHtmlResponse(res, 200, buildAdminPage());
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
