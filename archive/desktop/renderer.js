/* ===== VibeCoding Plus — Renderer ===== */

const el = {
  statusPill: document.querySelector("#status-pill"),
  serviceMode: document.querySelector("#service-mode"),
  serviceModeDisplay: document.querySelector("#service-mode-display"),
  servicePort: document.querySelector("#service-port"),
  cliStatus: document.querySelector("#cli-status"),
  serviceMessage: document.querySelector("#service-message"),
  configIssues: document.querySelector("#config-issues"),
  deviceCount: document.querySelector("#device-count"),
  serviceUptime: document.querySelector("#service-uptime"),
  serviceStt: document.querySelector("#service-stt"),
  serviceDiscovery: document.querySelector("#service-discovery"),
  serviceClients: document.querySelector("#service-clients"),
  deviceList: document.querySelector("#device-list"),
  form: document.querySelector("#settings-form"),
  sendTarget: document.querySelector("#send-target"),
  sttProvider: document.querySelector("#stt-provider"),
  transcriptDeliveryMode: document.querySelector("#transcript-delivery-mode"),
  textInjectionMode: document.querySelector("#text-injection-mode"),
  openaiApiKey: document.querySelector("#openai-api-key"),
  openaiModel: document.querySelector("#openai-model"),
  volcengineAppKey: document.querySelector("#volcengine-app-key"),
  volcengineAccessKey: document.querySelector("#volcengine-access-key"),
  whisperCppModelPath: document.querySelector("#whisper-cpp-model-path"),
  whisperCppLanguage: document.querySelector("#whisper-cpp-language"),
  whisperCppThreads: document.querySelector("#whisper-cpp-threads"),
  whisperCppCommand: document.querySelector("#whisper-cpp-command"),
  whisperCppExtraArgs: document.querySelector("#whisper-cpp-extra-args"),
  qwenAsrApiKey: document.querySelector("#qwen-asr-api-key"),
  qwenAsrModel: document.querySelector("#qwen-asr-model"),
  qwenAsrLanguage: document.querySelector("#qwen-asr-language"),
  qwenAsrPrompt: document.querySelector("#qwen-asr-prompt"),
  qwenAsrSampleRate: document.querySelector("#qwen-asr-sample-rate"),
  qwenAsrRealtimeBaseUrl: document.querySelector("#qwen-asr-realtime-base-url"),
  lanSharedSecret: document.querySelector("#lan-shared-secret"),
  codexCwd: document.querySelector("#codex-cwd"),
  claudeCwd: document.querySelector("#claude-cwd"),
  autoLaunch: document.querySelector("#auto-launch"),
  launchToTray: document.querySelector("#launch-to-tray"),
  closeToTray: document.querySelector("#close-to-tray"),
  codexSkipGitRepoCheck: document.querySelector("#codex-skip-git-repo-check"),
  claudeDangerouslySkipPermissions: document.querySelector("#claude-dangerously-skip-permissions"),
  userConfigPath: document.querySelector("#user-config-path"),
  desktopSettingsPath: document.querySelector("#desktop-settings-path"),
  lastTranscript: document.querySelector("#last-transcript"),
  lastUserText: document.querySelector("#last-user-text"),
  lastAssistantText: document.querySelector("#last-assistant-text"),
  cliLogTail: document.querySelector("#cli-log-tail"),
  serviceLogTail: document.querySelector("#service-log-tail"),
  startBtn: document.querySelector("#start-service-button"),
  restartBtn: document.querySelector("#restart-service-button"),
  stopBtn: document.querySelector("#stop-service-button"),
  saveBtn: document.querySelector("#save-settings-button"),
  configBtn: document.querySelector("#open-config-folder-button"),
  pickCodexBtn: document.querySelector("#pick-codex-cwd-button"),
  pickClaudeBtn: document.querySelector("#pick-claude-cwd-button"),
  discoverBtn: document.querySelector("#discover-devices-button"),
  refreshBtn: document.querySelector("#refresh-devices-button"),
  navBadge: document.querySelector("#nav-device-badge"),
  logFilterCli: document.querySelector("#log-filter-cli"),
  logFilterSvc: document.querySelector("#log-filter-service"),
  todoInput: document.querySelector("#todo-input"),
  todoDueDate: document.querySelector("#todo-due-date"),
  todoAddBtn: document.querySelector("#todo-add-btn"),
  todoList: document.querySelector("#todo-list"),
  todoArchiveList: document.querySelector("#todo-archive-list"),
  todoStatus: document.querySelector("#todo-status"),
  syncNowBtn: document.querySelector("#sync-now-btn"),
  syncStatus: document.querySelector("#sync-status"),
  reminderLists: document.querySelector("#reminder-lists"),
  cfgTodoRefresh: document.querySelector("#cfg-todo-refresh"),
  cfgCodingRefresh: document.querySelector("#cfg-coding-refresh"),
  cfgStyle: document.querySelector("#cfg-style"),
  saveDisplayBtn: document.querySelector("#save-display-btn"),
  displayStatus: document.querySelector("#display-status"),
  envList: document.querySelector("#environment-list"),
  envStatus: document.querySelector("#environment-status"),
  envRefreshBtn: document.querySelector("#refresh-env-checks-btn"),
  installMissingBtn: document.querySelector("#install-missing-btn"),
  installLog: document.querySelector("#install-log"),
  settingsStatus: document.querySelector("#settings-status"),
};

const live = { transcript: "", userText: "", assistantText: "", cliStatus: "尚未连接", cliLogLines: [] };
const app = { bootstrap: null, service: null, socket: null, rt: null, sp: null };
let deviceTimer = null;
let environmentReport = null;

// ─── Helpers ───
const esc = (s) => String(s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const escAttr = (s) => esc(s).replace(/"/g, "&quot;");
const modeLabel = (m) => m === "claude_code" ? "Claude Code" : m === "codex_exec" ? "Codex" : "输入注入";
const statusLabel = (s) => ({ running: "运行中", starting: "启动中", needs_setup: "待配置", error: "异常" }[s] || "已停止");
const formatUp = (s) => { if (!s || s < 1) return "--"; const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60); return h > 0 ? `${h}小时${m}分` : `${m}分钟`; };
const formatTm = (ts) => { if (!ts) return ""; const d = new Date(ts); return isNaN(d) ? "" : `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`; };
const formatDateTime = (ts) => {
  if (!ts) return "";
  const d = new Date(ts);
  if (isNaN(d)) return "";
  return `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")} ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
};

function setInlineStatus(target, message, isError = false) {
  if (!target) return;
  target.textContent = message || "";
  target.classList.toggle("hidden", !message);
  target.classList.toggle("is-error", Boolean(isError));
}

async function adminApi(method, path, body) {
  const res = await window.vibeApp.adminApi(method, path, body);
  if (!res?.ok) {
    throw new Error(res?.error || "操作失败，请确认服务已启动");
  }
  return res;
}

function dateInputToDueAt(value) {
  const text = String(value || "").trim();
  if (!text) return "";
  const parsed = new Date(`${text}T00:00:00`);
  return Number.isNaN(parsed.getTime()) ? "" : parsed.toISOString();
}

function renderTodoItem(item, { archived = false } = {}) {
  const due = item.dueAt ? `<span class="todo-due">${esc(formatDateTime(item.dueAt))}</span>` : '<span class="todo-due"></span>';
  const source = item.appleId ? '<span class="todo-source">提醒</span>' : "";
  const primary = archived
    ? `<button class="todo-action" data-action="restore" data-id="${escAttr(item.id)}">恢复</button>`
    : `<input class="todo-check" type="checkbox" ${item.completed ? "checked" : ""} data-id="${escAttr(item.id)}" />`;
  return `<div class="todo-item ${item.completed ? "completed" : ""}" data-id="${escAttr(item.id)}">${primary}<span class="todo-text">${esc(item.title)}</span>${source}${due}<button class="todo-del" title="删除" data-action="delete" data-id="${escAttr(item.id)}">×</button></div>`;
}

function envStatusLabel(status) {
  if (status === "ok") return "正常";
  if (status === "missing") return "缺失";
  if (status === "optional") return "可选";
  return "提示";
}

function envActionButtons(item) {
  const buttons = [];
  if (item.installable) {
    buttons.push(`<button class="btn btn-sm btn-primary env-install" data-tool="${escAttr(item.id)}">${esc(item.installLabel || "安装")}</button>`);
  }
  if ((item.id === "codex" || item.id === "claude") && item.status === "ok") {
    buttons.push(`<button class="btn btn-sm env-login" data-tool="${escAttr(item.id)}">登录/检查</button>`);
  }
  if (item.id === "macos_permissions") {
    buttons.push('<button class="btn btn-sm env-permissions">打开权限设置</button>');
  }
  return buttons.join("");
}

function renderEnvironment(report) {
  environmentReport = report;
  const checks = report?.checks || [];
  if (!checks.length) {
    el.envList.innerHTML = '<div class="empty-state">暂无环境检测结果</div>';
    return;
  }

  el.envList.innerHTML = checks.map((item) => {
    const detail = item.path || item.version || item.note || "";
    return `<div class="env-item env-${escAttr(item.status)}">
      <div class="env-main">
        <span class="env-name">${esc(item.label)}</span>
        <span class="env-purpose">${esc(item.purpose || "")}</span>
        ${detail ? `<code class="env-detail">${esc(detail)}</code>` : ""}
        ${item.note ? `<span class="env-note">${esc(item.note)}</span>` : ""}
      </div>
      <div class="env-actions">
        <span class="env-badge">${envStatusLabel(item.status)}</span>
        ${envActionButtons(item)}
      </div>
    </div>`;
  }).join("");

  el.envList.querySelectorAll(".env-install").forEach((btn) => {
    btn.addEventListener("click", () => installTool(btn.dataset.tool));
  });
  el.envList.querySelectorAll(".env-login").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const result = await window.vibeApp.openToolLogin(btn.dataset.tool);
      setInlineStatus(el.envStatus, result.ok ? "已打开终端，请按提示完成登录或检查。" : (result.error || "打开终端失败"), !result.ok);
    });
  });
  el.envList.querySelectorAll(".env-permissions").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const result = await window.vibeApp.openMacosPermissions();
      setInlineStatus(el.envStatus, result.ok ? "已打开系统设置。请允许 VibeCoding Plus 控制辅助功能/自动化。" : (result.error || "打开系统设置失败"), !result.ok);
    });
  });

  const missing = checks.filter((item) => item.status === "missing");
  setInlineStatus(
    el.envStatus,
    missing.length ? `发现 ${missing.length} 个缺失项，安装后请重新检测。` : "环境检测通过；可直接启动服务。",
    missing.length > 0
  );
}

async function loadEnvironmentChecks() {
  el.envRefreshBtn.disabled = true;
  try {
    const report = await window.vibeApp.getEnvironmentChecks();
    if (report.error) {
      setInlineStatus(el.envStatus, report.error, true);
    }
    renderEnvironment(report);
  } catch (error) {
    setInlineStatus(el.envStatus, error.message || String(error), true);
  } finally {
    el.envRefreshBtn.disabled = false;
  }
}

async function installTool(toolId) {
  const item = (environmentReport?.checks || []).find((entry) => entry.id === toolId);
  const label = item?.label || toolId;
  const needsBrew = ["remindctl", "whisper_cpp"].includes(toolId);
  const brewMissing = !(environmentReport?.checks || []).some((entry) => entry.id === "brew" && entry.status === "ok");
  const message = needsBrew && brewMissing
    ? `将先安装 Homebrew，再安装 ${label}。过程中可能需要系统密码或较长时间，确认继续？`
    : `确认安装 ${label}？过程中会联网下载官方安装脚本或 Homebrew 包。`;
  if (!confirm(message)) return;

  el.installLog.classList.remove("hidden");
  el.installLog.textContent = `开始安装 ${label}...\n`;
  setInlineStatus(el.envStatus, `正在安装 ${label}...`);
  document.querySelectorAll(".env-install").forEach((btn) => { btn.disabled = true; });
  el.installMissingBtn.disabled = true;
  try {
    const result = await window.vibeApp.installTool(toolId);
    el.installLog.textContent = result.log || result.error || "安装命令没有输出。";
    if (result.report) {
      renderEnvironment(result.report);
    } else {
      await loadEnvironmentChecks();
    }
    setInlineStatus(el.envStatus, result.ok ? `${label} 安装完成。` : `${label} 安装失败：${result.error || "请查看日志"}`, !result.ok);
  } catch (error) {
    setInlineStatus(el.envStatus, error.message || String(error), true);
  } finally {
    document.querySelectorAll(".env-install").forEach((btn) => { btn.disabled = false; });
    el.installMissingBtn.disabled = false;
  }
}

async function installMissingTools() {
  const missing = (environmentReport?.checks || []).filter((item) => item.status === "missing" && item.installable);
  if (!missing.length) {
    setInlineStatus(el.envStatus, "没有需要安装的缺失项。");
    return;
  }
  for (const item of missing) {
    await installTool(item.id);
    const stillMissing = (environmentReport?.checks || []).some((entry) => entry.id === item.id && entry.status === "missing");
    if (stillMissing) {
      break;
    }
  }
}

// ─── Navigation ───
document.querySelectorAll(".nav-item").forEach((item) => {
  item.addEventListener("click", () => {
    const t = item.dataset.nav;
    document.querySelectorAll(".nav-item").forEach((n) => n.classList.toggle("is-active", n === item));
    document.querySelectorAll(".page").forEach((p) => p.classList.toggle("is-active", p.dataset.page === t));
    // Auto-refresh on page switch
    if (t === "devices") refreshDevices();
    if (t === "todo") loadTodos();
    if (t === "reminders") loadSyncStatus();
    if (t === "display") loadDisplayConfig();
    if (t === "environment") loadEnvironmentChecks();
  });
});

document.querySelectorAll(".stab").forEach((tab) => {
  tab.addEventListener("click", () => {
    document.querySelectorAll(".stab").forEach((t) => t.classList.toggle("is-active", t === tab));
    document.querySelectorAll(".stab-panel").forEach((p) => { p.classList.toggle("is-active", p.dataset.stabPanel === tab.dataset.stab); p.classList.toggle("hidden", p.dataset.stabPanel !== tab.dataset.stab); });
  });
});

// ─── Visibility ───
function updateVis() {
  const prov = el.sttProvider.value;
  document.querySelectorAll("[data-provider-section]").forEach((s) => { s.classList.toggle("is-visible", s.dataset.providerSection === prov); s.classList.toggle("hidden", s.dataset.providerSection !== prov); });
  const mode = el.sendTarget.value;
  document.querySelectorAll("[data-mode-visible]").forEach((s) => s.classList.toggle("hidden", s.dataset.modeVisible !== mode));
}

// ─── Render service ───
function renderService() {
  const svc = app.service || app.bootstrap?.service;
  if (!svc) return;
  el.statusPill.textContent = statusLabel(svc.status);
  el.statusPill.className = `status-pill status-${svc.status}`;
  el.serviceMode.textContent = modeLabel(svc.mode);
  el.serviceModeDisplay.textContent = modeLabel(svc.mode);
  el.servicePort.textContent = String(svc.port || 8765);
  el.serviceMessage.textContent = svc.message || "";
  el.cliStatus.textContent = live.cliStatus;
  const f = el.logFilterSvc?.value || "all";
  const logs = (svc.logs || []).filter((l) => f === "all" || (f === "device" ? /client|hello|device|discovery/i.test(l) : /\[bridge\]/.test(l)));
  el.serviceLogTail.textContent = logs.length ? logs.join("\n") : "等待启动。";
  el.startBtn.disabled = svc.status === "running" || svc.status === "starting";
  el.restartBtn.disabled = svc.status === "starting";
  el.stopBtn.disabled = svc.status === "stopped" || svc.status === "needs_setup";
  if (svc.status === "running") {
    refreshDevices();
    if (!deviceTimer) deviceTimer = setInterval(refreshDevices, 5000);
  } else {
    el.deviceCount.textContent = "0"; el.serviceUptime.textContent = "--"; el.serviceStt.textContent = "--";
    el.serviceDiscovery.textContent = "--"; el.serviceClients.textContent = "--"; el.navBadge.classList.add("hidden");
    if (deviceTimer) { clearInterval(deviceTimer); deviceTimer = null; }
  }
}

function renderLive() {
  el.lastTranscript.textContent = live.transcript || "还没有收到语音";
  el.lastUserText.textContent = live.userText || "等待中";
  el.lastAssistantText.textContent = live.assistantText || "等待中";
  const f = el.logFilterCli?.value || "all";
  const lines = live.cliLogLines.filter((l) => f === "all" || (f === "transcript" ? /转写|transcript/i.test(l) : f === "user" ? /user|用户/i.test(l) : /assistant|AI|回复/i.test(l)));
  el.cliLogTail.textContent = lines.length ? lines.join("\n") : "尚未连接。";
}

// ─── Devices ───
async function refreshDevices() {
  try {
    const [dev, st] = await Promise.all([window.vibeApp.getDevices(), window.vibeApp.getServiceStatus()]);
    if (dev.ok) {
      const d = dev.devices || [];
      el.deviceCount.textContent = String(d.length);
      if (d.length > 0) { el.navBadge.textContent = String(d.length); el.navBadge.classList.remove("hidden"); } else { el.navBadge.classList.add("hidden"); }
      el.deviceList.innerHTML = d.length ? d.map((x) => `<div class="device-card"><span class="device-id">${esc(x.deviceId)}</span><span class="device-meta">${esc(x.boardType || x.voiceMode || "")}</span><span class="device-ip">${esc(x.remoteAddress || "")}</span><span class="device-time">${formatTm(x.connectedAt)}</span></div>`).join("") : '<div class="empty-state">暂无设备连接</div>';
    }
    if (st.ok) { el.serviceUptime.textContent = formatUp(st.uptime); el.serviceStt.textContent = st.sttProvider || "--"; el.serviceDiscovery.textContent = st.discoveryEnabled ? "已启用" : "已禁用"; el.serviceClients.textContent = String(st.clientCount ?? 0); }
  } catch {}
}

// ─── Todo (native) ───
async function loadTodos() {
  try {
    const res = await adminApi("GET", "/api/admin/todos");
    const items = res.snapshot?.items || [];
    const archiveItems = res.snapshot?.archiveItems || [];
    el.todoList.innerHTML = items.length ? items.map((t) => renderTodoItem(t)).join("") : '<div class="empty-state">暂无待办</div>';
    el.todoArchiveList.innerHTML = archiveItems.length ? archiveItems.map((t) => renderTodoItem(t, { archived: true })).join("") : '<div class="empty-state">暂无归档待办</div>';
    el.todoList.querySelectorAll(".todo-check").forEach((cb) => cb.addEventListener("change", async () => {
      cb.disabled = true;
      try {
        await adminApi("PUT", "/api/admin/todos", { id: cb.dataset.id, completed: cb.checked });
        await loadTodos();
        setInlineStatus(el.todoStatus, cb.checked ? "已完成，设备列表会在下一次刷新时更新" : "已恢复为未完成");
      } catch (error) {
        cb.checked = !cb.checked;
        setInlineStatus(el.todoStatus, error.message, true);
      } finally {
        cb.disabled = false;
      }
    }));
    el.todoList.querySelectorAll(".todo-del").forEach((btn) => btn.addEventListener("click", () => deleteTodo(btn.dataset.id)));
    el.todoArchiveList.querySelectorAll("[data-action='restore']").forEach((btn) => btn.addEventListener("click", () => restoreTodo(btn.dataset.id)));
    el.todoArchiveList.querySelectorAll("[data-action='delete']").forEach((btn) => btn.addEventListener("click", () => deleteTodo(btn.dataset.id)));
  } catch (error) {
    setInlineStatus(el.todoStatus, error.message, true);
  }
}

el.todoAddBtn?.addEventListener("click", async () => {
  const title = el.todoInput.value.trim();
  if (!title) {
    setInlineStatus(el.todoStatus, "请输入待办内容", true);
    return;
  }
  el.todoAddBtn.disabled = true;
  try {
    await adminApi("POST", "/api/admin/todos", { title, dueAt: dateInputToDueAt(el.todoDueDate.value) });
    el.todoInput.value = "";
    el.todoDueDate.value = "";
    await loadTodos();
    setInlineStatus(el.todoStatus, "待办已添加，设备会在下一次待办刷新时显示");
  } catch (error) {
    setInlineStatus(el.todoStatus, error.message, true);
  } finally {
    el.todoAddBtn.disabled = false;
  }
});
el.todoInput?.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); el.todoAddBtn.click(); } });

async function restoreTodo(id) {
  if (!id) return;
  try {
    await adminApi("PUT", "/api/admin/todos", { id, completed: false });
    await loadTodos();
    setInlineStatus(el.todoStatus, "待办已恢复");
  } catch (error) {
    setInlineStatus(el.todoStatus, error.message, true);
  }
}

async function deleteTodo(id) {
  if (!id) {
    setInlineStatus(el.todoStatus, "待办不存在或已刷新", true);
    return;
  }
  if (!confirm("确认删除这条待办吗？已同步到苹果提醒的项目也会尝试同步删除。")) {
    return;
  }
  try {
    const result = await adminApi("DELETE", "/api/admin/todos", { id });
    await loadTodos();
    const remoteDelete = result.remoteDelete || {};
    if (remoteDelete.failed > 0) {
      setInlineStatus(el.todoStatus, `本地已删除，提醒事项删除失败 ${remoteDelete.failed} 条`, true);
    } else if (remoteDelete.deleted > 0) {
      setInlineStatus(el.todoStatus, `待办已删除，并同步删除提醒事项 ${remoteDelete.deleted} 条`);
    } else {
      setInlineStatus(el.todoStatus, "待办已删除");
    }
  } catch (error) {
    setInlineStatus(el.todoStatus, error.message, true);
  }
}

// ─── Reminders sync (native) ───
async function loadSyncStatus() {
  try {
    const res = await adminApi("GET", "/api/admin/todo-sync");
    if (res.ok) {
      const st = res.status || {};
      el.syncStatus.innerHTML = `同步状态：${st.enabled ? "已启用" : "已禁用"} · 上次同步：${st.lastSyncAt ? formatTm(st.lastSyncAt) : "从未"} · 同步次数：${st.syncCount ?? 0}${st.lastError ? ` · <span style="color:var(--danger)">错误：${esc(st.lastError)}</span>` : ""}`;
    }
    const lists = await adminApi("GET", "/api/admin/todo-sync/lists");
    if (lists.ok) {
      el.reminderLists.innerHTML = (lists.lists || []).map((l) => `<div class="todo-item"><span class="todo-text">📋 ${esc(l.title)}</span><span class="todo-due">${l.reminderCount} 条</span></div>`).join("") || '<div class="empty-state">无提醒列表</div>';
    }
  } catch (error) {
    el.syncStatus.textContent = error.message;
  }
}

el.syncNowBtn?.addEventListener("click", async () => {
  el.syncNowBtn.disabled = true; el.syncNowBtn.textContent = "同步中...";
  try {
    const result = await adminApi("POST", "/api/admin/todo-sync/run");
    const message = result.changed ? "同步完成，已有更新" : "同步完成，无变化";
    await loadSyncStatus();
    el.syncStatus.innerHTML = `${esc(message)} · ${el.syncStatus.innerHTML}`;
  } catch (error) {
    el.syncStatus.textContent = error.message;
    await loadSyncStatus();
    el.syncStatus.innerHTML = `${esc(error.message)} · ${el.syncStatus.innerHTML}`;
  } finally {
    el.syncNowBtn.textContent = "立即同步"; el.syncNowBtn.disabled = false;
  }
});

// ─── Display config (native) ───
async function loadDisplayConfig() {
  try {
    const res = await adminApi("GET", "/api/admin/display-config");
    if (res.ok) { el.cfgTodoRefresh.value = res.values?.todoRefreshMs ?? 2000; el.cfgCodingRefresh.value = res.values?.codingRefreshMs ?? 2000; el.cfgStyle.value = res.values?.style || "light"; }
  } catch (error) {
    setInlineStatus(el.displayStatus, error.message, true);
  }
}

el.saveDisplayBtn?.addEventListener("click", async () => {
  el.saveDisplayBtn.disabled = true;
  try {
    const result = await adminApi("POST", "/api/admin/display-config", {
      todoRefreshMs: Number(el.cfgTodoRefresh.value), codingRefreshMs: Number(el.cfgCodingRefresh.value), style: el.cfgStyle.value,
    });
    const message = result.restartRequired
      ? "显示配置已保存；需重启服务后生效"
      : "显示配置已保存并已立即生效，设备会在下一次刷新周期更新";
    setInlineStatus(el.displayStatus, result.error ? `${message}；${result.error}` : message, Boolean(result.error));
    await loadDisplayConfig();
  } catch (error) {
    setInlineStatus(el.displayStatus, error.message, true);
  }
  el.saveDisplayBtn.disabled = false;
});

// ─── WebSocket ───
function resetWs() { if (app.socket) { app.socket.close(); app.socket = null; } app.sp = null; if (app.rt) { clearTimeout(app.rt); app.rt = null; } }
function schedReconnect() { if (app.rt) return; app.rt = setTimeout(() => { app.rt = null; connectWs(); }, 1200); }

function handleMsg(m) {
  if (m.type === "server_ready") { live.cliStatus = `已连接 · ${modeLabel(m.sendTarget)}`; renderService(); }
  else if (m.type === "cli_session_state") { live.cliStatus = m.statusLine || m.phase || "待命"; renderService(); }
  else if (m.type === "cli_summary") { if (m.latestUserText !== undefined) live.userText = m.latestUserText || ""; if (m.latestAssistantText !== undefined) live.assistantText = m.latestAssistantText || ""; renderLive(); }
  else if (m.type === "cli_log_tail") { live.cliLogLines = Array.isArray(m.lines) ? m.lines : []; renderLive(); }
  else if (m.type === "transcript_final") { live.transcript = m.text || ""; renderLive(); }
  else if (m.type === "status" && m.text) { live.transcript = m.text; renderLive(); }
  else if (m.type === "device_event") { refreshDevices(); if (m.event === "disconnected" && m.deviceId) try { window.vibeApp.notify({ title: "设备断开", body: `${m.deviceId} 已断开` }); } catch {} }
}

function connectWs() {
  const svc = app.service || app.bootstrap?.service;
  if (!svc || (svc.status !== "running" && svc.status !== "starting")) { resetWs(); live.cliStatus = "服务未连接"; renderService(); return; }
  const port = svc.port || 8765;
  if (app.socket && app.sp === port && (app.socket.readyState === WebSocket.OPEN || app.socket.readyState === WebSocket.CONNECTING)) return;
  resetWs();
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  app.socket = ws; app.sp = port;
  ws.addEventListener("open", () => ws.send(JSON.stringify({ type: "hello", deviceId: "desktop-window", boardType: "desktop-window" })));
  ws.addEventListener("message", (e) => { try { handleMsg(JSON.parse(String(e.data))); } catch {} });
  ws.addEventListener("close", () => { if (app.socket === ws) { app.socket = null; app.sp = null; } live.cliStatus = "连接已断开"; renderService(); schedReconnect(); });
  ws.addEventListener("error", () => { live.cliStatus = "无法连接"; renderService(); });
}

// ─── Settings form ───
function collect() {
  return {
    form: { sendTarget: el.sendTarget.value, sttProvider: el.sttProvider.value, transcriptDeliveryMode: el.transcriptDeliveryMode.value, textInjectionMode: el.textInjectionMode.value, openaiApiKey: el.openaiApiKey.value, openaiModel: el.openaiModel.value, volcengineAppKey: el.volcengineAppKey.value, volcengineAccessKey: el.volcengineAccessKey.value, whisperCppModelPath: el.whisperCppModelPath.value, whisperCppLanguage: el.whisperCppLanguage.value, whisperCppThreads: el.whisperCppThreads.value, whisperCppCommand: el.whisperCppCommand.value, whisperCppExtraArgs: el.whisperCppExtraArgs.value, qwenAsrApiKey: el.qwenAsrApiKey.value, qwenAsrModel: el.qwenAsrModel.value, qwenAsrLanguage: el.qwenAsrLanguage.value, qwenAsrPrompt: el.qwenAsrPrompt.value, qwenAsrSampleRate: el.qwenAsrSampleRate.value, qwenAsrRealtimeBaseUrl: el.qwenAsrRealtimeBaseUrl.value, lanSharedSecret: el.lanSharedSecret.value, codexCwd: el.codexCwd.value, claudeCwd: el.claudeCwd.value, codexSkipGitRepoCheck: el.codexSkipGitRepoCheck.checked, claudeDangerouslySkipPermissions: el.claudeDangerouslySkipPermissions.checked },
    desktopSettings: { autoLaunch: el.autoLaunch.checked, launchToTray: el.launchToTray.checked, closeToTray: el.closeToTray.checked },
  };
}

function fill(f, dsp) {
  el.sendTarget.value = f.sendTarget; el.sttProvider.value = f.sttProvider; el.transcriptDeliveryMode.value = f.transcriptDeliveryMode; el.textInjectionMode.value = f.textInjectionMode;
  el.openaiApiKey.value = f.openaiApiKey || ""; el.openaiModel.value = f.openaiModel || ""; el.volcengineAppKey.value = f.volcengineAppKey || ""; el.volcengineAccessKey.value = f.volcengineAccessKey || "";
  el.whisperCppModelPath.value = f.whisperCppModelPath || ""; el.whisperCppLanguage.value = f.whisperCppLanguage || ""; el.whisperCppThreads.value = f.whisperCppThreads || ""; el.whisperCppCommand.value = f.whisperCppCommand || ""; el.whisperCppExtraArgs.value = f.whisperCppExtraArgs || "";
  el.qwenAsrApiKey.value = f.qwenAsrApiKey || ""; el.qwenAsrModel.value = f.qwenAsrModel || ""; el.qwenAsrLanguage.value = f.qwenAsrLanguage || ""; el.qwenAsrPrompt.value = f.qwenAsrPrompt || ""; el.qwenAsrSampleRate.value = f.qwenAsrSampleRate || ""; el.qwenAsrRealtimeBaseUrl.value = f.qwenAsrRealtimeBaseUrl || "";
  el.lanSharedSecret.value = f.lanSharedSecret || ""; el.codexCwd.value = f.codexCwd || ""; el.claudeCwd.value = f.claudeCwd || "";
  el.autoLaunch.checked = Boolean(f.desktopSettings?.autoLaunch); el.launchToTray.checked = Boolean(f.desktopSettings?.launchToTray); el.closeToTray.checked = Boolean(f.desktopSettings?.closeToTray);
  el.codexSkipGitRepoCheck.checked = Boolean(f.codexSkipGitRepoCheck); el.claudeDangerouslySkipPermissions.checked = Boolean(f.claudeDangerouslySkipPermissions);
  el.userConfigPath.textContent = f.userConfigPath || ""; el.desktopSettingsPath.textContent = dsp || "";
  updateVis();
}

// ─── Events ───
el.sttProvider.addEventListener("change", updateVis);
el.sendTarget.addEventListener("change", updateVis);
el.form.addEventListener("submit", async (e) => {
  e.preventDefault();
  el.saveBtn.disabled = true;
  setInlineStatus(el.settingsStatus, "正在保存并应用...");
  try {
    const b = await window.vibeApp.saveConfig(collect());
    app.bootstrap = b; app.service = b.service;
    fill(b.form, b.desktopSettingsPath); renderService(); connectWs();
    const needsSetup = b.service?.status === "needs_setup";
    setInlineStatus(el.settingsStatus, needsSetup ? `已保存；仍需配置：${b.service?.message || ""}` : "已保存并应用；后台服务通常会在几秒内重启完成", needsSetup);
  } catch (error) {
    setInlineStatus(el.settingsStatus, error.message || String(error), true);
  } finally {
    el.saveBtn.disabled = false;
  }
});
el.startBtn.addEventListener("click", async () => { const b = await window.vibeApp.startService(); app.bootstrap = b; app.service = b.service; renderService(); connectWs(); el.serviceMessage.textContent = b.service?.message || "服务启动中"; });
el.restartBtn.addEventListener("click", async () => { const b = await window.vibeApp.restartService(); app.bootstrap = b; app.service = b.service; renderService(); connectWs(); el.serviceMessage.textContent = "服务重启中，设备可能需要几秒重新连接"; });
el.stopBtn.addEventListener("click", async () => { const b = await window.vibeApp.stopService(); app.bootstrap = b; app.service = b.service; renderService(); connectWs(); el.serviceMessage.textContent = "服务已停止"; });
el.configBtn.addEventListener("click", async () => { const b = await window.vibeApp.openConfigFolder(); app.bootstrap = b; app.service = b.service; renderService(); });
el.pickCodexBtn.addEventListener("click", async () => { const v = await window.vibeApp.pickDirectory(el.codexCwd.value); if (v) el.codexCwd.value = v; });
el.pickClaudeBtn.addEventListener("click", async () => { const v = await window.vibeApp.pickDirectory(el.claudeCwd.value); if (v) el.claudeCwd.value = v; });
el.refreshBtn?.addEventListener("click", () => refreshDevices());
el.envRefreshBtn?.addEventListener("click", () => loadEnvironmentChecks());
el.installMissingBtn?.addEventListener("click", () => installMissingTools());
el.discoverBtn?.addEventListener("click", async () => { el.discoverBtn.disabled = true; el.discoverBtn.textContent = "发送中..."; try { await adminApi("POST", "/api/admin/discover"); el.serviceMessage.textContent = "已发送发现请求，等待设备重新连接"; setTimeout(() => refreshDevices(), 3000); } catch (error) { el.serviceMessage.textContent = error.message; } el.discoverBtn.textContent = "重新发现"; el.discoverBtn.disabled = false; });
el.logFilterCli?.addEventListener("change", renderLive);
el.logFilterSvc?.addEventListener("change", renderService);
window.vibeApp.onState((p) => { app.service = p.service; renderService(); connectWs(); });

// ─── Init ───
(async () => {
  const b = await window.vibeApp.getBootstrap();
  app.bootstrap = b; app.service = b.service;
  fill(b.form, b.desktopSettingsPath);
  renderService(); renderLive(); connectWs(); loadEnvironmentChecks();
})();
