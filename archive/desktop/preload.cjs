const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("vibeApp", {
  getBootstrap: () => ipcRenderer.invoke("desktop:get-bootstrap"),
  startService: () => ipcRenderer.invoke("desktop:start-service"),
  stopService: () => ipcRenderer.invoke("desktop:stop-service"),
  restartService: () => ipcRenderer.invoke("desktop:restart-service"),
  saveConfig: (payload) => ipcRenderer.invoke("desktop:save-config", payload),
  setMode: (mode) => ipcRenderer.invoke("desktop:set-mode", mode),
  updateDesktopSettings: (patch) => ipcRenderer.invoke("desktop:update-desktop-settings", patch),
  pickDirectory: (currentPath) => ipcRenderer.invoke("desktop:pick-directory", currentPath),
  openConfigFolder: () => ipcRenderer.invoke("desktop:open-config-folder"),
  getDevices: () => ipcRenderer.invoke("desktop:get-devices"),
  getServiceStatus: () => ipcRenderer.invoke("desktop:get-service-status"),
  getEnvironmentChecks: () => ipcRenderer.invoke("desktop:get-environment-checks"),
  installTool: (toolId) => ipcRenderer.invoke("desktop:install-tool", toolId),
  openMacosPermissions: () => ipcRenderer.invoke("desktop:open-macos-permissions"),
  openToolLogin: (toolId) => ipcRenderer.invoke("desktop:open-tool-login", toolId),
  adminApi: (method, path, body) => ipcRenderer.invoke("desktop:admin-api", method, path, body),
  notify: (opts) => ipcRenderer.invoke("desktop:notify", opts),
  onState: (callback) => {
    if (typeof callback !== "function") {
      return;
    }
    ipcRenderer.on("desktop:state", (_event, payload) => callback(payload));
  }
});
