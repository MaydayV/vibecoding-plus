/* ===== VibeCoding Plus — Renderer (sidebar + e-paper theme) ===== */

// ─── Element refs ───
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
  startServiceButton: document.querySelector("#start-service-button"),
  restartServiceButton: document.querySelector("#restart-service-button"),
  stopServiceButton: document.querySelector("#stop-service-button"),
  saveSettingsButton: document.querySelector("#save-settings-button"),
  openConfigFolderButton: document.querySelector("#open-config-folder-button"),
  pickCodexCwdButton: document.querySelector("#pick-codex-cwd-button"),
  pickClaudeCwdButton: document.querySelector("#pick-claude-cwd-button"),
  discoverDevicesButton: document.querySelector("#discover-devices-button"),
  refreshDevicesButton: document.querySelector("#refresh-devices-button"),
  navDeviceBadge: document.querySelector("#nav-device-badge"),
  logFilterCli: document.querySelector("#log-filter-cli"),
  logFilterService: document.querySelector("#log-filter-service"),
};

// ─── State ───
const live = { transcript: "", userText: "", assistantText: "", cliStatus: "尚未连接", cliLogLines: [] };
const app = { bootstrap: null, service: null, socket: null, reconnectTimer: null, socketPort: null };
let deviceRefreshTimer = null;

// ─── Helpers ───
function esc(s) { return String(s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }

function modeLabel(m) {
  if (m === "claude_code") return "Claude Code";
  if (m === "codex_exec") return "Codex";
  return "输入注入";
}

function providerLabel(p) {
  if (p === "openai") return "OpenAI";
  if (p === "whisper_cpp") return "whisper.cpp";
  if (p === "qwen_asr") return "Qwen3-ASR";
  return "Volcengine";
}

function statusLabel(s) {
  if (s === "running") return "运行中";
  if (s === "starting") return "启动中";
  if (s === "needs_setup") return "待配置";
  if (s === "error") return "异常";
  return "已停止";
}

function formatUptime(sec) {
  if (!sec || sec < 1) return "--";
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60);
  return h > 0 ? `${h}小时${m}分` : `${m}分钟`;
}

function formatTime(ts) {
  if (!ts) return "";
  const d = new Date(ts);
  if (isNaN(d.getTime())) return "";
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

// ─── Navigation ───
document.querySelectorAll(".nav-item").forEach((item) => {
  item.addEventListener("click", () => {
    const target = item.dataset.nav;
    document.querySelectorAll(".nav-item").forEach((n) => n.classList.remove("is-active"));
    item.classList.add("is-active");
    document.querySelectorAll(".page").forEach((p) => {
      p.classList.toggle("is-active", p.dataset.page === target);
    });
    // Lazy-load admin iframe
    if (target === "admin") {
      const iframe = el.adminIframe || document.querySelector("#admin-iframe");
      if (iframe && iframe.src === "about:blank") {
        const port = app.bootstrap?.form?.port || app.service?.port || 8765;
        iframe.src = `http://127.0.0.1:${port}/admin`;
      }
    }
  });
});

// Settings sub-tabs
document.querySelectorAll(".stab").forEach((tab) => {
  tab.addEventListener("click", () => {
    const target = tab.dataset.stab;
    document.querySelectorAll(".stab").forEach((t) => t.classList.toggle("is-active", t === tab));
    document.querySelectorAll(".stab-panel").forEach((p) => {
      p.classList.toggle("is-active", p.dataset.stabPanel === target);
      p.classList.toggle("hidden", p.dataset.stabPanel !== target);
    });
  });
});

// ─── Provider / mode visibility ───
function updateVisibility() {
  const provider = el.sttProvider.value;
  document.querySelectorAll("[data-provider-section]").forEach((s) => {
    s.classList.toggle("is-visible", s.dataset.providerSection === provider);
    s.classList.toggle("hidden", s.dataset.providerSection !== provider);
  });
  const mode = el.sendTarget.value;
  document.querySelectorAll("[data-mode-visible]").forEach((s) => {
    s.classList.toggle("hidden", s.dataset.modeVisible !== mode);
  });
}

// ─── Render service state ───
function renderService() {
  const svc = app.service || app.bootstrap?.service;
  if (!svc) return;

  const status = svc.status;
  el.statusPill.textContent = statusLabel(status);
  el.statusPill.className = `status-pill status-${status}`;
  el.serviceMode.textContent = modeLabel(svc.mode);
  el.serviceModeDisplay.textContent = modeLabel(svc.mode);
  el.servicePort.textContent = String(svc.port || 8765);
  el.serviceMessage.textContent = svc.message || "";
  el.cliStatus.textContent = live.cliStatus;

  // Service log with filter
  const filter = el.logFilterService?.value || "all";
  const logs = (svc.logs || []).filter((line) => {
    if (filter === "all") return true;
    if (filter === "device") return /client|hello|device|discovery/i.test(line);
    if (filter === "bridge") return /\[bridge\]/.test(line);
    return true;
  });
  el.serviceLogTail.textContent = logs.length ? logs.join("\n") : "等待启动。";

  el.startServiceButton.disabled = status === "running" || status === "starting";
  el.restartServiceButton.disabled = status === "starting";
  el.stopServiceButton.disabled = status === "stopped" || status === "needs_setup";

  if (status === "running") {
    refreshDeviceAndStatus();
    if (!deviceRefreshTimer) deviceRefreshTimer = setInterval(refreshDeviceAndStatus, 5000);
  } else {
    el.deviceCount.textContent = "0";
    el.serviceUptime.textContent = "--";
    el.serviceStt.textContent = "--";
    el.serviceDiscovery.textContent = "--";
    el.serviceClients.textContent = "--";
    el.navDeviceBadge.classList.add("hidden");
    if (deviceRefreshTimer) { clearInterval(deviceRefreshTimer); deviceRefreshTimer = null; }
  }
}

// ─── Render live feed ───
function renderLive() {
  el.lastTranscript.textContent = live.transcript || "还没有收到语音";
  el.lastUserText.textContent = live.userText || "等待中";
  el.lastAssistantText.textContent = live.assistantText || "等待中";
  const filter = el.logFilterCli?.value || "all";
  const lines = live.cliLogLines.filter((line) => {
    if (filter === "all") return true;
    if (filter === "transcript") return /转写|transcript/i.test(line);
    if (filter === "user") return /user|用户/i.test(line);
    if (filter === "assistant") return /assistant|AI|回复/i.test(line);
    return true;
  });
  el.cliLogTail.textContent = lines.length ? lines.join("\n") : "尚未连接。";
}

// ─── Device list ───
async function refreshDeviceAndStatus() {
  try {
    const [devRes, stRes] = await Promise.all([window.vibeApp.getDevices(), window.vibeApp.getServiceStatus()]);
    if (devRes.ok) {
      const devices = devRes.devices || [];
      el.deviceCount.textContent = String(devices.length);
      if (devices.length > 0) {
        el.navDeviceBadge.textContent = String(devices.length);
        el.navDeviceBadge.classList.remove("hidden");
      } else {
        el.navDeviceBadge.classList.add("hidden");
      }
      el.deviceList.innerHTML = devices.length
        ? devices.map((d) => `
          <div class="device-card">
            <span class="device-id">${esc(d.deviceId)}</span>
            <span class="device-meta">${esc(d.boardType || d.voiceMode || "")}</span>
            <span class="device-ip">${esc(d.remoteAddress || "")}</span>
            <span class="device-time">${formatTime(d.connectedAt)}</span>
          </div>
        `).join("")
        : '<div class="empty-state">暂无设备连接</div>';
    }
    if (stRes.ok) {
      el.serviceUptime.textContent = formatUptime(stRes.uptime);
      el.serviceStt.textContent = stRes.sttProvider || "--";
      el.serviceDiscovery.textContent = stRes.discoveryEnabled ? "已启用" : "已禁用";
      el.serviceClients.textContent = String(stRes.clientCount ?? 0);
    }
  } catch { /* ignore */ }
}

// ─── WebSocket live connection ───
function resetSocket() {
  if (app.socket) { app.socket.close(); app.socket = null; }
  app.socketPort = null;
  if (app.reconnectTimer) { clearTimeout(app.reconnectTimer); app.reconnectTimer = null; }
}

function scheduleReconnect() {
  if (app.reconnectTimer) return;
  app.reconnectTimer = setTimeout(() => { app.reconnectTimer = null; connectSocket(); }, 1200);
}

function handleMessage(msg) {
  if (msg.type === "server_ready") {
    live.cliStatus = `已连接 · ${modeLabel(msg.sendTarget)}`;
    if (msg.sendTarget) el.serviceMode.textContent = modeLabel(msg.sendTarget);
    renderService();
  } else if (msg.type === "cli_session_state") {
    live.cliStatus = msg.statusLine || msg.phase || "待命";
    renderService();
  } else if (msg.type === "cli_summary") {
    if (msg.latestUserText !== undefined) live.userText = msg.latestUserText || "";
    if (msg.latestAssistantText !== undefined) live.assistantText = msg.latestAssistantText || "";
    renderLive();
  } else if (msg.type === "cli_log_tail") {
    live.cliLogLines = Array.isArray(msg.lines) ? msg.lines : [];
    renderLive();
  } else if (msg.type === "transcript_final") {
    live.transcript = msg.text || "";
    renderLive();
  } else if (msg.type === "status" && msg.text) {
    live.transcript = msg.text;
    renderLive();
  } else if (msg.type === "device_event") {
    refreshDeviceAndStatus();
    if (msg.event === "disconnected" && msg.deviceId) {
      try { window.vibeApp.notify({ title: "设备断开", body: `${msg.deviceId} 已断开` }); } catch {}
    }
  }
}

function connectSocket() {
  const svc = app.service || app.bootstrap?.service;
  if (!svc || (svc.status !== "running" && svc.status !== "starting")) {
    resetSocket(); live.cliStatus = "服务未连接"; renderService(); return;
  }
  const port = svc.port || 8765;
  if (app.socket && app.socketPort === port && (app.socket.readyState === WebSocket.OPEN || app.socket.readyState === WebSocket.CONNECTING)) return;
  resetSocket();
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  app.socket = ws; app.socketPort = port;
  ws.addEventListener("open", () => ws.send(JSON.stringify({ type: "hello", deviceId: "desktop-window", boardType: "desktop-window" })));
  ws.addEventListener("message", (e) => { try { handleMessage(JSON.parse(String(e.data))); } catch {} });
  ws.addEventListener("close", () => { if (app.socket === ws) { app.socket = null; app.socketPort = null; } live.cliStatus = "连接已断开"; renderService(); scheduleReconnect(); });
  ws.addEventListener("error", () => { live.cliStatus = "无法连接到本地服务"; renderService(); });
}

// ─── Form ───
function collectForm() {
  return {
    form: {
      sendTarget: el.sendTarget.value, sttProvider: el.sttProvider.value,
      transcriptDeliveryMode: el.transcriptDeliveryMode.value, textInjectionMode: el.textInjectionMode.value,
      openaiApiKey: el.openaiApiKey.value, openaiModel: el.openaiModel.value,
      volcengineAppKey: el.volcengineAppKey.value, volcengineAccessKey: el.volcengineAccessKey.value,
      whisperCppModelPath: el.whisperCppModelPath.value, whisperCppLanguage: el.whisperCppLanguage.value,
      whisperCppThreads: el.whisperCppThreads.value, whisperCppCommand: el.whisperCppCommand.value,
      whisperCppExtraArgs: el.whisperCppExtraArgs.value,
      qwenAsrApiKey: el.qwenAsrApiKey.value, qwenAsrModel: el.qwenAsrModel.value,
      qwenAsrLanguage: el.qwenAsrLanguage.value, qwenAsrPrompt: el.qwenAsrPrompt.value,
      qwenAsrSampleRate: el.qwenAsrSampleRate.value, qwenAsrRealtimeBaseUrl: el.qwenAsrRealtimeBaseUrl.value,
      lanSharedSecret: el.lanSharedSecret.value,
      codexCwd: el.codexCwd.value, claudeCwd: el.claudeCwd.value,
      codexSkipGitRepoCheck: el.codexSkipGitRepoCheck.checked,
      claudeDangerouslySkipPermissions: el.claudeDangerouslySkipPermissions.checked,
    },
    desktopSettings: { autoLaunch: el.autoLaunch.checked, launchToTray: el.launchToTray.checked, closeToTray: el.closeToTray.checked },
  };
}

function fillForm(f, dsp) {
  el.sendTarget.value = f.sendTarget; el.sttProvider.value = f.sttProvider;
  el.transcriptDeliveryMode.value = f.transcriptDeliveryMode; el.textInjectionMode.value = f.textInjectionMode;
  el.openaiApiKey.value = f.openaiApiKey || ""; el.openaiModel.value = f.openaiModel || "";
  el.volcengineAppKey.value = f.volcengineAppKey || ""; el.volcengineAccessKey.value = f.volcengineAccessKey || "";
  el.whisperCppModelPath.value = f.whisperCppModelPath || ""; el.whisperCppLanguage.value = f.whisperCppLanguage || "";
  el.whisperCppThreads.value = f.whisperCppThreads || ""; el.whisperCppCommand.value = f.whisperCppCommand || "";
  el.whisperCppExtraArgs.value = f.whisperCppExtraArgs || "";
  el.qwenAsrApiKey.value = f.qwenAsrApiKey || ""; el.qwenAsrModel.value = f.qwenAsrModel || "";
  el.qwenAsrLanguage.value = f.qwenAsrLanguage || ""; el.qwenAsrPrompt.value = f.qwenAsrPrompt || "";
  el.qwenAsrSampleRate.value = f.qwenAsrSampleRate || ""; el.qwenAsrRealtimeBaseUrl.value = f.qwenAsrRealtimeBaseUrl || "";
  el.lanSharedSecret.value = f.lanSharedSecret || "";
  el.codexCwd.value = f.codexCwd || ""; el.claudeCwd.value = f.claudeCwd || "";
  el.autoLaunch.checked = Boolean(f.desktopSettings?.autoLaunch);
  el.launchToTray.checked = Boolean(f.desktopSettings?.launchToTray);
  el.closeToTray.checked = Boolean(f.desktopSettings?.closeToTray);
  el.codexSkipGitRepoCheck.checked = Boolean(f.codexSkipGitRepoCheck);
  el.claudeDangerouslySkipPermissions.checked = Boolean(f.claudeDangerouslySkipPermissions);
  el.userConfigPath.textContent = f.userConfigPath || "";
  el.desktopSettingsPath.textContent = dsp || "";
  updateVisibility();
}

// ─── Event wiring ───
el.sttProvider.addEventListener("change", updateVisibility);
el.sendTarget.addEventListener("change", updateVisibility);

el.form.addEventListener("submit", async (e) => {
  e.preventDefault();
  el.saveSettingsButton.disabled = true;
  try {
    const b = await window.vibeApp.saveConfig(collectForm());
    app.bootstrap = b; app.service = b.service;
    fillForm(b.form, b.desktopSettingsPath);
    renderService(); connectSocket();
  } finally { el.saveSettingsButton.disabled = false; }
});

el.startServiceButton.addEventListener("click", async () => {
  const b = await window.vibeApp.startService(); app.bootstrap = b; app.service = b.service; renderService(); connectSocket();
});
el.restartServiceButton.addEventListener("click", async () => {
  const b = await window.vibeApp.restartService(); app.bootstrap = b; app.service = b.service; renderService(); connectSocket();
});
el.stopServiceButton.addEventListener("click", async () => {
  const b = await window.vibeApp.stopService(); app.bootstrap = b; app.service = b.service; renderService(); connectSocket();
});
el.openConfigFolderButton.addEventListener("click", async () => {
  const b = await window.vibeApp.openConfigFolder(); app.bootstrap = b; app.service = b.service; renderService();
});
el.pickCodexCwdButton.addEventListener("click", async () => {
  const v = await window.vibeApp.pickDirectory(el.codexCwd.value); if (v) el.codexCwd.value = v;
});
el.pickClaudeCwdButton.addEventListener("click", async () => {
  const v = await window.vibeApp.pickDirectory(el.claudeCwd.value); if (v) el.claudeCwd.value = v;
});

if (el.refreshDevicesButton) el.refreshDevicesButton.addEventListener("click", () => refreshDeviceAndStatus());
if (el.discoverDevicesButton) {
  el.discoverDevicesButton.addEventListener("click", async () => {
    el.discoverDevicesButton.disabled = true; el.discoverDevicesButton.textContent = "发送中...";
    try { await window.vibeApp.adminApi("POST", "/api/admin/discover"); setTimeout(() => refreshDeviceAndStatus(), 3000); } catch {}
    el.discoverDevicesButton.textContent = "重新发现"; el.discoverDevicesButton.disabled = false;
  });
}

el.logFilterCli?.addEventListener("change", renderLive);
el.logFilterService?.addEventListener("change", renderService);

window.vibeApp.onState((payload) => { app.service = payload.service; renderService(); connectSocket(); });

// ─── Init ───
async function init() {
  const b = await window.vibeApp.getBootstrap();
  app.bootstrap = b; app.service = b.service;
  fillForm(b.form, b.desktopSettingsPath);
  renderService(); renderLive(); connectSocket();
}

init();
