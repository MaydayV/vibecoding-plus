import fs from "node:fs";
import { spawn } from "node:child_process";
import path from "node:path";

import { projectRoot } from "./paths.mjs";

function encodePowerShellCommand(command) {
  return Buffer.from(command, "utf16le").toString("base64");
}

function escapePowerShellSingleQuoted(value) {
  return String(value).replace(/'/g, "''");
}

function buildPowerShellInvocation(scriptContent, namedArgs = {}) {
  const renderedArgs = Object.entries(namedArgs)
    .filter(([, value]) => value !== undefined && value !== null)
    .map(([name, value]) => `-${name} '${escapePowerShellSingleQuoted(value)}'`)
    .join(" ");

  return `$ProgressPreference = 'SilentlyContinue'\n& {\n${scriptContent.trim()}\n}${renderedArgs ? ` ${renderedArgs}` : ""}`;
}

function runPowerShellScript(scriptContent, namedArgs) {
  return new Promise((resolve, reject) => {
    const command = buildPowerShellInvocation(scriptContent, namedArgs);
    const child = spawn(
      "powershell.exe",
      [
        "-NoProfile",
        "-NonInteractive",
        "-Sta",
        "-ExecutionPolicy",
        "Bypass",
        "-EncodedCommand",
        encodePowerShellCommand(command)
      ],
      {
        stdio: ["ignore", "pipe", "pipe"]
      }
    );

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(new Error(stderr.trim() || stdout.trim() || `PowerShell exited with code ${code}`));
    });
  });
}

function escapeAppleScriptText(value) {
  return String(value)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\r/g, "\\r")
    .replace(/\n/g, "\\n");
}

function runMacTextInjection(text, mode, options = {}) {
  return new Promise((resolve, reject) => {
    const escapedText = escapeAppleScriptText(text);
    const shouldPressEnter = mode === "type_and_enter" || Boolean(options.forceEnter);
    const script = `
set clipText to "${escapedText}"
set shouldPaste to (length of clipText) > 0
set previousClipboard to missing value
if shouldPaste then
  set previousClipboard to the clipboard
end if
try
  if shouldPaste then
    set the clipboard to clipText
    delay 0.06
  end if
  tell application "System Events"
    if shouldPaste then
      keystroke "v" using command down
    end if
    if ${shouldPressEnter ? "true" : "false"} then
      if shouldPaste then
        delay 0.12
      end if
      key code 36
    end if
  end tell
  if shouldPaste then
    delay 0.18
    set the clipboard to previousClipboard
  end if
on error errMsg number errNum
  if shouldPaste then
    try
      set the clipboard to previousClipboard
    end try
  end if
  error errMsg number errNum
end try
`;

    const child = spawn("osascript", ["-e", script], {
      stdio: ["ignore", "pipe", "pipe"]
    });

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(new Error(stderr.trim() || stdout.trim() || `osascript exited with code ${code}`));
    });
  });
}

export async function injectText(text, mode, options = {}) {
  const trimmed = String(text || "").trim();
  const forceEnter = Boolean(options.forceEnter);
  if (!trimmed && !forceEnter) {
    return;
  }

  if (options.dryRun) {
    console.log("[inject] dry-run", { mode, text: trimmed, forceEnter });
    return;
  }

  if (process.platform === "win32") {
    const scriptPath = path.join(projectRoot, "scripts", "inject-text.ps1");
    const scriptContent = fs.readFileSync(scriptPath, "utf8");
    const textBase64 = Buffer.from(trimmed, "utf8").toString("base64");

    await runPowerShellScript(scriptContent, {
      TextBase64: textBase64,
      Mode: mode,
      ForceEnter: forceEnter ? "1" : "0"
    });
    return;
  }

  if (process.platform === "darwin") {
    await runMacTextInjection(trimmed, mode, { forceEnter });
    return;
  }

  throw new Error(`text injection is only implemented for Windows/macOS in this MVP, got ${process.platform}`);
}
