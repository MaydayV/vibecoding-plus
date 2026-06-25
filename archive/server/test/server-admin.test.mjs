import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { spawn } from "node:child_process";

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function getFreePort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(address.port);
      });
    });
  });
}

async function waitForReady(port, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/healthz`);
      if (response.ok) {
        return;
      }
    } catch (error) {
      lastError = error;
    }
    await sleep(100);
  }
  throw lastError || new Error("server_not_ready");
}

async function stopServer(child) {
  if (!child || child.exitCode !== null) {
    return;
  }

  await new Promise((resolve) => {
    child.once("exit", resolve);
    child.kill();
    setTimeout(resolve, 3000).unref?.();
  });
}

test("admin page and APIs support todo/env editing", async (t) => {
  const port = await getFreePort();
  const appDataRoot = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-admin-api-"));
  const cwdRoot = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-admin-cwd-"));

  const server = spawn(process.execPath, ["client/server/src/server.mjs"], {
    cwd: path.resolve("."),
    env: {
      ...process.env,
      APPDATA: appDataRoot,
      VIBE_INVOKE_CWD: cwdRoot,
      LAN_DISCOVERY_ENABLED: "0",
      LAN_VOICE_BIND: "127.0.0.1",
      LAN_VOICE_PORT: String(port),
      MOCK_TRANSCRIPT: "admin test",
      SEND_TARGET: "text_injector",
      DRY_RUN_TEXT_INJECTION: "1",
      TODO_INTENT_PROVIDER: "rules",
      TRANSCRIPT_DELIVERY_MODE: "immediate",
      LAN_TRUST_LOCALHOST: "1"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  const output = [];
  server.stdout.on("data", (chunk) => output.push(String(chunk)));
  server.stderr.on("data", (chunk) => output.push(String(chunk)));

  t.after(async () => {
    await stopServer(server);
    fs.rmSync(appDataRoot, { recursive: true, force: true });
    fs.rmSync(cwdRoot, { recursive: true, force: true });
  });

  await waitForReady(port);

  const todosRes = await fetch(`http://127.0.0.1:${port}/api/admin/todos`);
  assert.equal(todosRes.status, 200);
  const todosPayload = await todosRes.json();
  assert.equal(todosPayload.ok, true);
  const baselineCount = todosPayload.snapshot.items.length;

  const createTodoRes = await fetch(`http://127.0.0.1:${port}/api/admin/todos`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      title: "管理页新增待办",
      dueAt: "2026-05-01T00:00:00.000Z"
    })
  });
  assert.equal(createTodoRes.status, 200);
  const createTodoPayload = await createTodoRes.json();
  assert.equal(createTodoPayload.ok, true);
  assert.equal(createTodoPayload.snapshot.items.length, baselineCount + 1);
  const created = createTodoPayload.snapshot.items.find((item) => item.title === "管理页新增待办");
  assert.ok(created);
  assert.equal(created.dueAt, "2026-05-01T00:00:00.000Z");

  const updateTodoRes = await fetch(`http://127.0.0.1:${port}/api/admin/todos`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      id: created.id,
      title: "管理页编辑后待办",
      dueAt: "2026-05-03T00:00:00.000Z",
      completed: true
    })
  });
  assert.equal(updateTodoRes.status, 200);
  const updateTodoPayload = await updateTodoRes.json();
  const updated = updateTodoPayload.snapshot.archiveItems.find((item) => item.id === created.id);
  assert.equal(updateTodoPayload.snapshot.items.some((item) => item.id === created.id), false);
  assert.equal(updated.title, "管理页编辑后待办");
  assert.equal(updated.dueAt, "2026-05-03T00:00:00.000Z");
  assert.equal(updated.completed, true);

  const deleteTodoRes = await fetch(`http://127.0.0.1:${port}/api/admin/todos`, {
    method: "DELETE",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ id: created.id })
  });
  assert.equal(deleteTodoRes.status, 200);
  const deleteTodoPayload = await deleteTodoRes.json();
  assert.equal(
    deleteTodoPayload.snapshot.items.some((item) => item.id === created.id),
    false
  );

  const syncGetRes = await fetch(`http://127.0.0.1:${port}/api/admin/todo-sync`);
  assert.equal(syncGetRes.status, 200);
  const syncGetPayload = await syncGetRes.json();
  assert.equal(syncGetPayload.ok, true);
  assert.equal(typeof syncGetPayload.values.enabled, "boolean");

  const syncPostRes = await fetch(`http://127.0.0.1:${port}/api/admin/todo-sync`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      enabled: true,
      remindctlPath: "remindctl",
      list: "",
      pollSec: 20
    })
  });
  assert.equal(syncPostRes.status, 200);
  const syncPostPayload = await syncPostRes.json();
  assert.equal(syncPostPayload.ok, true);
  assert.equal(syncPostPayload.applied, true);
  assert.equal(syncPostPayload.restartRequired, false);
  assert.equal(syncPostPayload.values.REMINDERS_SYNC_ENABLED, "1");
  assert.equal(syncPostPayload.values.REMINDERS_LIST, "");

  const syncGetAfterRes = await fetch(`http://127.0.0.1:${port}/api/admin/todo-sync`);
  assert.equal(syncGetAfterRes.status, 200);
  const syncGetAfterPayload = await syncGetAfterRes.json();
  assert.equal(syncGetAfterPayload.ok, true);
  assert.equal(syncGetAfterPayload.values.list, "");

  const syncRunRes = await fetch(`http://127.0.0.1:${port}/api/admin/todo-sync/run`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ reason: "test_manual" })
  });
  assert.equal(syncRunRes.status, 200);
  const syncRunPayload = await syncRunRes.json();
  assert.equal(typeof syncRunPayload.ok, "boolean");
  assert.equal(typeof syncRunPayload.reason, "string");

  const envText = "TEST_ADMIN_ENV=1\nADMIN_KEY=abc\n";
  const envPostRes = await fetch(`http://127.0.0.1:${port}/api/admin/env`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ content: envText })
  });
  assert.equal(envPostRes.status, 200);
  const envPostPayload = await envPostRes.json();
  assert.equal(envPostPayload.content, envText);

  const envPath = String(envPostPayload.path || envGetPayload.path || "");
  assert.ok(envPath);
  assert.equal(fs.existsSync(envPath), true);
  assert.equal(envPath, path.join(cwdRoot, ".env"));
  assert.equal(fs.readFileSync(envPath, "utf8"), envText);

  const healthRes = await fetch(`http://127.0.0.1:${port}/healthz`);
  assert.equal(healthRes.status, 200);
  assert.equal(await healthRes.text(), "ok\n");
});
