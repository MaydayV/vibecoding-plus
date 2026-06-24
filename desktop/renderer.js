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
  todoAddBtn: document.querySelector("#todo-add-btn"),
  todoList: document.querySelector("#todo-list"),
  syncNowBtn: document.querySelector("#sync-now-btn"),
  syncStatus: document.querySelector("#sync-status"),
  reminderLists: document.querySelector("#reminder-lists"),
  cfgTodoRefresh: document.querySelector("#cfg-todo-refresh"),
  cfgCodingRefresh: document.querySelector("#cfg-coding-refresh"),
  cfgStyle: document.querySelector("#cfg-style"),
  saveDisplayBtn: document.querySelector("#save-display-btn"),
};

const live = { transcript: "", userText: "", assistantText: "", cliStatus: "尚未连接", cliLogLines: [] };
const app = { bootstrap: null, service: null, socket: null, rt: null, sp: null };
let deviceTimer = null;

// ─── Helpers ───
const esc = (s) => String(s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const modeLabel = (m) => m === "claude_code" ? "Claude Code" : m === "codex_exec" ? "Codex" : "输入注入";
const statusLabel = (s) => ({ running: "运行中", starting: "启动中", needs_setup: "待配置", error: "异常" }[s] || "已停止");
const formatUp = (s) => { if (!s || s < 1) return "--"; const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60); return h > 0 ? `${h}小时${m}分` : `${m}分钟`; };
const formatTm = (ts) => { if (!ts) return ""; const d = new Date(ts); return isNaN(d) ? "" : `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`; };

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
    const res = await window.vibeApp.adminApi("GET", "/api/admin/todos");
    if (!res.ok) return;
    const items = res.snapshot?.items || [];
    el.todoList.innerHTML = items.length ? items.map((t, i) => `<div class="todo-item ${t.completed ? "completed" : ""}"><input class="todo-check" type="checkbox" ${t.completed ? "checked" : ""} data-idx="${i}" /><span class="todo-text">${esc(t.title)}</span><span class="todo-due">${t.dueAt ? formatTm(t.dueAt) : ""}</span><button class="todo-del" data-idx="${i}">×</button></div>`).join("") : '<div class="empty-state">暂无待办</div>';
    el.todoList.querySelectorAll(".todo-check").forEach((cb) => cb.addEventListener("change", async () => { await window.vibeApp.adminApi("PUT", "/api/admin/todos", { index: Number(cb.dataset.idx), completed: cb.checked }); loadTodos(); }));
    el.todoList.querySelectorAll(".todo-del").forEach((btn) => btn.addEventListener("click", async () => { await window.vibeApp.adminApi("DELETE", "/api/admin/todos", { index: Number(btn.dataset.idx) }); loadTodos(); }));
  } catch {}
}

el.todoAddBtn?.addEventListener("click", async () => {
  const title = el.todoInput.value.trim();
  if (!title) return;
  await window.vibeApp.adminApi("POST", "/api/admin/todos", { title });
  el.todoInput.value = "";
  loadTodos();
});
el.todoInput?.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); el.todoAddBtn.click(); } });

// ─── Reminders sync (native) ───
async function loadSyncStatus() {
  try {
    const res = await window.vibeApp.adminApi("GET", "/api/admin/todo-sync");
    if (res.ok) {
      const st = res.status || {};
      el.syncStatus.innerHTML = `同步状态：${st.enabled ? "已启用" : "已禁用"} · 上次同步：${st.lastSyncAt ? formatTm(st.lastSyncAt) : "从未"} · 同步次数：${st.syncCount ?? 0}${st.lastError ? ` · <span style="color:var(--danger)">错误：${esc(st.lastError)}</span>` : ""}`;
    }
    const lists = await window.vibeApp.adminApi("GET", "/api/admin/todo-sync/lists");
    if (lists.ok) {
      el.reminderLists.innerHTML = (lists.lists || []).map((l) => `<div class="todo-item"><span class="todo-text">📋 ${esc(l.title)}</span><span class="todo-due">${l.reminderCount} 条</span></div>`).join("") || '<div class="empty-state">无提醒列表</div>';
    }
  } catch {}
}

el.syncNowBtn?.addEventListener("click", async () => {
  el.syncNowBtn.disabled = true; el.syncNowBtn.textContent = "同步中...";
  try { await window.vibeApp.adminApi("POST", "/api/admin/todo-sync/run"); } catch {}
  el.syncNowBtn.textContent = "立即同步"; el.syncNowBtn.disabled = false;
  loadSyncStatus();
});

// ─── Display config (native) ───
async function loadDisplayConfig() {
  try {
    const res = await window.vibeApp.adminApi("GET", "/api/admin/display-config");
    if (res.ok) { el.cfgTodoRefresh.value = res.values?.todoRefreshMs ?? 2000; el.cfgCodingRefresh.value = res.values?.codingRefreshMs ?? 2000; el.cfgStyle.value = res.values?.style || "light"; }
  } catch {}
}

el.saveDisplayBtn?.addEventListener("click", async () => {
  el.saveDisplayBtn.disabled = true;
  try {
    await window.vibeApp.adminApi("POST", "/api/admin/display-config", {
      todoRefreshMs: Number(el.cfgTodoRefresh.value), codingRefreshMs: Number(el.cfgCodingRefresh.value), style: el.cfgStyle.value,
    });
  } catch {}
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
el.form.addEventListener("submit", async (e) => { e.preventDefault(); el.saveBtn.disabled = true; try { const b = await window.vibeApp.saveConfig(collect()); app.bootstrap = b; app.service = b.service; fill(b.form, b.desktopSettingsPath); renderService(); connectWs(); } finally { el.saveBtn.disabled = false; } });
el.startBtn.addEventListener("click", async () => { const b = await window.vibeApp.startService(); app.bootstrap = b; app.service = b.service; renderService(); connectWs(); });
el.restartBtn.addEventListener("click", async () => { const b = await window.vibeApp.restartService(); app.bootstrap = b; app.service = b.service; renderService(); connectWs(); });
el.stopBtn.addEventListener("click", async () => { const b = await window.vibeApp.stopService(); app.bootstrap = b; app.service = b.service; renderService(); connectWs(); });
el.configBtn.addEventListener("click", async () => { const b = await window.vibeApp.openConfigFolder(); app.bootstrap = b; app.service = b.service; renderService(); });
el.pickCodexBtn.addEventListener("click", async () => { const v = await window.vibeApp.pickDirectory(el.codexCwd.value); if (v) el.codexCwd.value = v; });
el.pickClaudeBtn.addEventListener("click", async () => { const v = await window.vibeApp.pickDirectory(el.claudeCwd.value); if (v) el.claudeCwd.value = v; });
el.refreshBtn?.addEventListener("click", () => refreshDevices());
el.discoverBtn?.addEventListener("click", async () => { el.discoverBtn.disabled = true; el.discoverBtn.textContent = "发送中..."; try { await window.vibeApp.adminApi("POST", "/api/admin/discover"); setTimeout(() => refreshDevices(), 3000); } catch {} el.discoverBtn.textContent = "重新发现"; el.discoverBtn.disabled = false; });
el.logFilterCli?.addEventListener("change", renderLive);
el.logFilterSvc?.addEventListener("change", renderService);
window.vibeApp.onState((p) => { app.service = p.service; renderService(); connectWs(); });

// ─── Init ───
(async () => {
  const b = await window.vibeApp.getBootstrap();
  app.bootstrap = b; app.service = b.service;
  fill(b.form, b.desktopSettingsPath);
  renderService(); renderLive(); connectWs();
})();
