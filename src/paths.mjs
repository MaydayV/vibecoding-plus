import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const currentFilePath = fileURLToPath(import.meta.url);
const srcDir = path.dirname(currentFilePath);

export const projectRoot = path.resolve(srcDir, "..");

export function resolveProjectPath(...segments) {
  return path.join(projectRoot, ...segments);
}

export function getUserConfigDir() {
  if (process.platform === "win32") {
    const appData = process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming");
    return path.join(appData, "vibecoding-plus");
  }

  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Application Support", "vibecoding-plus");
  }

  const xdgConfigHome = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config");
  return path.join(xdgConfigHome, "vibecoding-plus");
}

export function getUserConfigPath() {
  return path.join(getUserConfigDir(), "config.env");
}

export function getUserDataPath(filename) {
  return path.join(getUserConfigDir(), filename);
}

export function getUserTodoListPath() {
  return getUserDataPath("todo-list.json");
}
