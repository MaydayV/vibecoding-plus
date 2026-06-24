import test from "node:test";
import assert from "node:assert/strict";

import { buildToolPath, getEnvironmentChecks } from "../src/environment-checks.mjs";

test("buildToolPath includes common macOS GUI app tool directories", () => {
  const value = buildToolPath("/custom/bin");
  assert.match(value, /\/opt\/homebrew\/bin/);
  assert.match(value, /\/usr\/local\/bin/);
  assert.match(value, /\/\.local\/bin/);
  assert.match(value, /\/custom\/bin/);
});

test("getEnvironmentChecks marks mode-specific tools as required", async () => {
  const report = await getEnvironmentChecks({
    sendTarget: "codex_exec",
    sttProvider: "whisper_cpp",
    whisperCppCommand: "definitely-missing-whisper-cli",
    whisperCppModelPath: "/tmp/model.bin",
    codexCommand: "definitely-missing-codex",
    remindersSyncEnabled: true,
    remindersRemindctlPath: "definitely-missing-remindctl",
    userConfigPath: "/tmp/.env"
  }, { configIssues: [] });

  const byId = Object.fromEntries(report.checks.map((item) => [item.id, item]));
  assert.equal(byId.codex.required, true);
  assert.equal(byId.codex.status, "missing");
  assert.equal(byId.whisper_cpp.required, true);
  assert.equal(byId.whisper_cpp.status, "missing");
  assert.equal(byId.remindctl.required, true);
  assert.equal(byId.remindctl.status, "missing");
  assert.equal(byId.stt_config.status, "ok");
});
