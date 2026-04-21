export function buildAdminPageTemplate() {
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
      input[type="text"], input[type="number"], select, textarea {
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
      .kv { display: grid; grid-template-columns: 160px 1fr; gap: 8px; align-items: center; }
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
        <button class="tab active" data-tab="todos">待办</button>
        <button class="tab" data-tab="sync">提醒事项同步</button>
        <button class="tab" data-tab="display">显示</button>
        <button class="tab" data-tab="archive">归档待办</button>
        <button class="tab" data-tab="env">环境变量</button>
        <button class="tab" data-tab="service">服务</button>
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

      <section id="panel-sync" class="panel">
        <div class="card">
          <div class="kv">
            <div>启用提醒事项同步</div>
            <div><label><input id="syncEnabled" type="checkbox" /> REMINDERS_SYNC_ENABLED</label></div>
            <div>remindctl 路径</div>
            <div><input id="syncCmd" type="text" placeholder="remindctl" /></div>
            <div>提醒事项列表</div>
            <div>
              <select id="syncList">
                <option value="">全部列表</option>
              </select>
            </div>
            <div></div>
            <div class="muted" id="syncListHint">正在加载列表...</div>
            <div>轮询秒数</div>
            <div><input id="syncPollSec" type="number" min="5" step="1" /></div>
          </div>
          <div class="row" style="margin-top:10px;">
            <button id="reloadListsBtn">刷新列表</button>
            <button id="saveSyncBtn" class="primary">保存同步配置</button>
            <button id="syncNowBtn">立即同步一次</button>
          </div>
        </div>

        <div class="card">
          <div class="muted" style="margin-bottom:8px;">同步状态</div>
          <div id="syncStatus"></div>
        </div>
      </section>

      <section id="panel-display" class="panel">
        <div class="card">
          <div class="kv">
            <div>待办模式刷新间隔 (ms)</div>
            <div><input id="displayTodoRefreshMs" type="number" min="200" max="10000" step="50" /></div>
            <div>编程模式刷新间隔 (ms)</div>
            <div><input id="displayCodingRefreshMs" type="number" min="200" max="10000" step="50" /></div>
            <div>显示样式</div>
            <div>
              <select id="displayStyle">
                <option value="light">白底黑字</option>
                <option value="dark">黑底白字</option>
              </select>
            </div>
          </div>
          <div class="row" style="margin-top:10px;">
            <button id="saveDisplayBtn" class="primary">保存显示配置</button>
            <button id="refreshDisplayBtn">刷新</button>
          </div>
        </div>
      </section>

      <section id="panel-archive" class="panel">
        <div class="card">
          <table>
            <thead>
              <tr>
                <th style="width:84px;">状态</th>
                <th>标题</th>
                <th style="width:180px;">操作</th>
              </tr>
            </thead>
            <tbody id="archiveTableBody"></tbody>
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
        快捷键：<span class="kbd">⌘/Ctrl+1/2/3/4/5/6</span> 切换 tab，<span class="kbd">⌘/Ctrl+S</span> 保存，<span class="kbd">⌘/Ctrl+R</span> 重启服务
      </div>
    </div>

    <script>
      const state = {
        tab: "todos",
        todos: [],
        archiveTodos: [],
        selectedTodoId: "",
        envContent: "",
        envDirty: false,
        pollingTimer: null,
        syncStatus: null,
        syncLists: [],
        syncConfigDirty: false,
        displayConfigDirty: false
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
        if (!nextTab || !["todos", "sync", "display", "archive", "env", "service"].includes(nextTab)) return;
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

      function renderArchiveTodos() {
        const archiveBodyEl = $("archiveTableBody");
        archiveBodyEl.innerHTML = "";
        if (!Array.isArray(state.archiveTodos) || state.archiveTodos.length === 0) {
          const row = document.createElement("tr");
          row.innerHTML = '<td colspan="3" class="muted">暂无归档待办</td>';
          archiveBodyEl.appendChild(row);
          return;
        }

        for (const item of state.archiveTodos) {
          const tr = document.createElement("tr");

          const stateTd = document.createElement("td");
          stateTd.textContent = "已完成";

          const titleTd = document.createElement("td");
          titleTd.textContent = item.title;

          const actionTd = document.createElement("td");
          actionTd.className = "row";

          const restoreBtn = document.createElement("button");
          restoreBtn.textContent = "恢复";
          restoreBtn.addEventListener("click", async () => {
            try {
              await api("/api/admin/todos", {
                method: "PUT",
                body: JSON.stringify({ id: item.id, completed: false })
              });
              await loadTodos();
              setStatus("待办已恢复到活动列表");
            } catch (error) {
              setStatus(error.message, true);
            }
          });

          const deleteBtn = document.createElement("button");
          deleteBtn.textContent = "删除";
          deleteBtn.addEventListener("click", async () => {
            try {
              await api("/api/admin/todos", {
                method: "DELETE",
                body: JSON.stringify({ id: item.id })
              });
              await loadTodos();
              setStatus("归档待办已删除");
            } catch (error) {
              setStatus(error.message, true);
            }
          });

          actionTd.appendChild(restoreBtn);
          actionTd.appendChild(deleteBtn);

          tr.appendChild(stateTd);
          tr.appendChild(titleTd);
          tr.appendChild(actionTd);
          archiveBodyEl.appendChild(tr);
        }
      }

      function formatSyncDate(value) {
        const text = String(value || "").trim();
        if (!text) {
          return "-";
        }
        const parsed = new Date(text);
        if (Number.isNaN(parsed.getTime())) {
          return text;
        }
        return new Intl.DateTimeFormat("zh-CN", {
          year: "numeric",
          month: "2-digit",
          day: "2-digit",
          hour: "2-digit",
          minute: "2-digit",
          second: "2-digit",
          hour12: false
        }).format(parsed);
      }

      function renderSyncStatus() {
        const el = $("syncStatus");
        const s = state.syncStatus;
        if (!s) {
          el.innerHTML = '<div class="muted">暂无同步状态</div>';
          return;
        }
        el.innerHTML = [
          '<div class="kv"><div>启用同步</div><div>' + (Boolean(s.enabled) ? "是" : "否") + '</div></div>',
          '<div class="kv"><div>命令路径</div><div class="mono">' + (s.command || "") + '</div></div>',
          '<div class="kv"><div>列表</div><div>' + (s.list || "(全部)") + '</div></div>',
          '<div class="kv"><div>轮询秒数</div><div>' + (s.pollSec || "") + '</div></div>',
          '<div class="kv"><div>正在同步</div><div>' + (Boolean(s.busy) ? "是" : "否") + '</div></div>',
          '<div class="kv"><div>上次同步时间</div><div>' + formatSyncDate(s.lastSyncAt) + '</div></div>',
          '<div class="kv"><div>累计同步次数</div><div>' + (s.syncCount || 0) + '</div></div>',
          '<div class="kv"><div>最近错误</div><div>' + (s.lastError || "-") + '</div></div>'
        ].join("\\n");
      }

      function renderSyncLists(selectedValue = "") {
        const select = $("syncList");
        const hint = $("syncListHint");
        select.innerHTML = "";

        const allOption = document.createElement("option");
        allOption.value = "";
        allOption.textContent = "全部列表";
        select.appendChild(allOption);

        for (const item of state.syncLists) {
          const option = document.createElement("option");
          option.value = item.title;
          option.textContent = item.title + " (" + (item.reminderCount || 0) + ")";
          select.appendChild(option);
        }

        const hasSelected = selectedValue && state.syncLists.some((item) => item.title === selectedValue);
        if (hasSelected) {
          select.value = selectedValue;
        } else if (selectedValue) {
          const custom = document.createElement("option");
          custom.value = selectedValue;
          custom.textContent = selectedValue + "（当前配置）";
          select.appendChild(custom);
          select.value = selectedValue;
        } else {
          select.value = "";
        }

        if (state.syncLists.length === 0) {
          hint.textContent = "未读取到列表，默认同步全部列表";
        } else {
          hint.textContent = "已读取到 " + state.syncLists.length + " 个列表";
        }
      }

      async function loadSyncLists() {
        const payload = await api("/api/admin/todo-sync/lists");
        state.syncLists = payload.lists || [];
        return state.syncLists;
      }

      async function loadTodos() {
        const payload = await api("/api/admin/todos");
        state.todos = payload.snapshot?.items || [];
        state.archiveTodos = payload.snapshot?.archiveItems || [];
        state.selectedTodoId = state.todos.some((item) => item.id === state.selectedTodoId)
          ? state.selectedTodoId
          : (state.todos[0]?.id || "");
        $("todoPath").textContent = "文件：" + (payload.storagePath || "");
        renderTodos();
        renderArchiveTodos();
      }

      async function loadSyncConfig(options = {}) {
        const payload = await api("/api/admin/todo-sync");
        const values = payload.values || {};
        if (!state.syncConfigDirty || options.force) {
          $("syncEnabled").checked = values.enabled === true;
          $("syncCmd").value = values.remindctlPath || "";
          $("syncPollSec").value = String(values.pollSec || 15);
        }
        try {
          await loadSyncLists();
        } catch {
          state.syncLists = [];
        }
        renderSyncLists((!state.syncConfigDirty || options.force) ? (values.list || "") : $("syncList").value);
        state.syncStatus = payload.status || null;
        renderSyncStatus();
      }

      async function saveSyncConfig() {
        const payload = {
          enabled: $("syncEnabled").checked,
          remindctlPath: $("syncCmd").value,
          list: $("syncList").value,
          pollSec: Number($("syncPollSec").value || 15)
        };
        const result = await api("/api/admin/todo-sync", {
          method: "POST",
          body: JSON.stringify(payload)
        });
        state.syncConfigDirty = false;
        state.syncStatus = result.status || state.syncStatus;
        renderSyncStatus();
        await loadSyncConfig({ force: true });
        setStatus(result.restartRequired ? "同步配置已保存，请重启服务生效" : "同步配置已保存并已生效");
      }

      async function loadDisplayConfig(options = {}) {
        const payload = await api("/api/admin/display-config");
        const values = payload.values || {};
        if (!state.displayConfigDirty || options.force) {
          $("displayTodoRefreshMs").value = String(values.todoRefreshMs || 800);
          $("displayCodingRefreshMs").value = String(values.codingRefreshMs || 800);
          $("displayStyle").value = values.style === "dark" ? "dark" : "light";
        }
      }

      async function saveDisplayConfig() {
        const payload = {
          todoRefreshMs: Number($("displayTodoRefreshMs").value || 800),
          codingRefreshMs: Number($("displayCodingRefreshMs").value || 800),
          style: $("displayStyle").value === "dark" ? "dark" : "light"
        };
        const result = await api("/api/admin/display-config", {
          method: "POST",
          body: JSON.stringify(payload)
        });
        state.displayConfigDirty = false;
        await loadDisplayConfig({ force: true });
        setStatus(result.restartRequired ? "显示配置已保存，请重启服务生效" : "显示配置已保存并已生效");
      }

      async function syncNow() {
        const payload = await api("/api/admin/todo-sync/run", {
          method: "POST",
          body: JSON.stringify({ reason: "admin_manual" })
        });
        state.syncStatus = payload.status || null;
        renderSyncStatus();
        await loadTodos();
        setStatus(payload.changed ? "同步完成，已有更新" : "同步完成，无变化");
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
          if (state.tab === "todos" || state.tab === "archive") {
            void loadTodos().catch(() => {});
          } else if (state.tab === "env" && !state.envDirty) {
            void loadEnv().catch(() => {});
          } else if (state.tab === "sync") {
            void loadSyncConfig().catch(() => {});
          } else if (state.tab === "display" && !state.displayConfigDirty) {
            void loadDisplayConfig().catch(() => {});
          }
        }, 2000);
      }

      document.querySelectorAll(".tab").forEach((btn) => {
        btn.addEventListener("click", () => switchTab(btn.dataset.tab));
      });

      $("addTodoBtn").addEventListener("click", () => void addTodo().catch((e) => setStatus(e.message, true)));
      $("refreshTodoBtn").addEventListener("click", () => void loadTodos().catch((e) => setStatus(e.message, true)));
      $("reloadListsBtn").addEventListener("click", () => void loadSyncConfig({ force: true }).catch((e) => setStatus(e.message, true)));
      $("saveSyncBtn").addEventListener("click", () => void saveSyncConfig().catch((e) => setStatus(e.message, true)));
      $("syncNowBtn").addEventListener("click", () => void syncNow().catch((e) => setStatus(e.message, true)));
      $("saveDisplayBtn").addEventListener("click", () => void saveDisplayConfig().catch((e) => setStatus(e.message, true)));
      $("refreshDisplayBtn").addEventListener("click", () => void loadDisplayConfig({ force: true }).catch((e) => setStatus(e.message, true)));
      $("saveEnvBtn").addEventListener("click", () => void saveEnv().catch((e) => setStatus(e.message, true)));
      $("refreshEnvBtn").addEventListener("click", () => void loadEnv({ force: true }).catch((e) => setStatus(e.message, true)));
      $("restartBtn").addEventListener("click", () => void restartService().catch((e) => setStatus(e.message, true)));
      $("syncEnabled").addEventListener("change", () => { state.syncConfigDirty = true; });
      $("syncCmd").addEventListener("input", () => { state.syncConfigDirty = true; });
      $("syncList").addEventListener("change", () => { state.syncConfigDirty = true; });
      $("syncPollSec").addEventListener("input", () => { state.syncConfigDirty = true; });
      $("displayTodoRefreshMs").addEventListener("input", () => { state.displayConfigDirty = true; });
      $("displayCodingRefreshMs").addEventListener("input", () => { state.displayConfigDirty = true; });
      $("displayStyle").addEventListener("change", () => { state.displayConfigDirty = true; });
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
          switchTab("sync");
          return;
        }
        if (command && key === "3") {
          event.preventDefault();
          switchTab("display");
          return;
        }
        if (command && key === "4") {
          event.preventDefault();
          switchTab("archive");
          return;
        }
        if (command && key === "5") {
          event.preventDefault();
          switchTab("env");
          return;
        }
        if (command && key === "6") {
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
          } else if (state.tab === "sync") {
            void saveSyncConfig().catch((e) => setStatus(e.message, true));
          } else if (state.tab === "display") {
            void saveDisplayConfig().catch((e) => setStatus(e.message, true));
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

      Promise.all([loadTodos(), loadSyncConfig(), loadDisplayConfig(), loadEnv()])
        .then(() => {
          startPolling();
          setStatus("管理页已就绪");
        })
        .catch((error) => setStatus(error.message || String(error), true));
    </script>
  </body>
</html>`;
}
