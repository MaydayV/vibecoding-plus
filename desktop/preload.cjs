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
  adminApi: (method, path, body) => ipcRenderer.invoke("desktop:admin-api", method, path, body),
  onState: (callback) => {
    if (typeof callback !== "function") {
      return;
    }
    ipcRenderer.on("desktop:state", (_event, payload) => callback(payload));
  }
});
