import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import net from "node:net";

import WebSocket from "ws";

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

async function connectWebSocket(url, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;

  while (Date.now() < deadline) {
    try {
      return await new Promise((resolve, reject) => {
        const ws = new WebSocket(url);
        const cleanup = () => {
          ws.removeListener("open", onOpen);
          ws.removeListener("error", onError);
        };
        const onOpen = () => {
          cleanup();
          resolve(ws);
        };
        const onError = (error) => {
          cleanup();
          ws.terminate();
          reject(error);
        };
        ws.once("open", onOpen);
        ws.once("error", onError);
      });
    } catch (error) {
      lastError = error;
      await sleep(100);
    }
  }

  throw lastError || new Error(`failed to connect to ${url}`);
}

function createMessageCollector(ws) {
  const queue = [];
  const waiters = [];

  const flush = (message) => {
    const index = waiters.findIndex((waiter) => waiter.predicate(message));
    if (index >= 0) {
      const [waiter] = waiters.splice(index, 1);
      clearTimeout(waiter.timer);
      waiter.resolve(message);
      return true;
    }
    return false;
  };

  const onMessage = (data, isBinary) => {
    if (isBinary) {
      return;
    }
    const message = JSON.parse(Buffer.from(data).toString("utf8"));
    if (!flush(message)) {
      queue.push(message);
    }
  };

  const onClose = () => {
    while (waiters.length > 0) {
      const waiter = waiters.shift();
      clearTimeout(waiter.timer);
      waiter.reject(new Error("websocket_closed"));
    }
  };

  ws.on("message", onMessage);
  ws.once("close", onClose);

  return {
    take(predicate) {
      const index = queue.findIndex(predicate);
      if (index < 0) {
        return null;
      }
      return queue.splice(index, 1)[0];
    },
    waitFor(predicate, timeoutMs = 5000) {
      const existing = this.take(predicate);
      if (existing) {
        return Promise.resolve(existing);
      }

      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          const waiterIndex = waiters.findIndex((waiter) => waiter.resolve === resolve);
          if (waiterIndex >= 0) {
            waiters.splice(waiterIndex, 1);
          }
          reject(new Error("message_timeout"));
        }, timeoutMs);

        waiters.push({ predicate, resolve, reject, timer });
      });
    }
  };
}

async function closeWebSocket(ws) {
  if (!ws || ws.readyState === WebSocket.CLOSED) {
    return;
  }

  await new Promise((resolve) => {
    ws.once("close", resolve);
    ws.close();
  });
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

test("server injects text on macOS when send target is text_injector", async (t) => {
  const port = await getFreePort();
  const appDataRoot = fs.mkdtempSync(path.join(os.tmpdir(), "vibe-server-macos-inject-"));
  const server = spawn(process.execPath, ["src/server.mjs"], {
    cwd: path.resolve("."),
    env: {
      ...process.env,
      APPDATA: appDataRoot,
      LAN_DISCOVERY_ENABLED: "0",
      LAN_VOICE_BIND: "127.0.0.1",
      LAN_VOICE_PORT: String(port),
      MOCK_TRANSCRIPT: "hello mac",
      SEND_TARGET: "text_injector",
      DRY_RUN_TEXT_INJECTION: "1",
      TODO_INTENT_PROVIDER: "rules",
      TRANSCRIPT_DELIVERY_MODE: "immediate",
      LAN_TRUST_LOCALHOST: "1"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  const serverOutput = [];
  server.stdout.on("data", (chunk) => serverOutput.push(String(chunk)));
  server.stderr.on("data", (chunk) => serverOutput.push(String(chunk)));

  t.after(async () => {
    await stopServer(server);
    fs.rmSync(appDataRoot, { recursive: true, force: true });
  });

  const ws = await connectWebSocket(`ws://127.0.0.1:${port}`);
  const messages = createMessageCollector(ws);
  t.after(() => closeWebSocket(ws));

  ws.send(JSON.stringify({ type: "hello", deviceId: "mac-client" }));
  await messages.waitFor((message) => message.type === "hello_ack");
  await messages.waitFor((message) => message.type === "server_ready");

  ws.send(JSON.stringify({ type: "ptt_start", ts: Date.now() }));
  ws.send(Buffer.from([0x00, 0x00]), { binary: true });
  ws.send(JSON.stringify({ type: "ptt_stop", ts: Date.now() }));

  const typedStatus = await messages.waitFor(
    (message) => message.type === "status" && message.status === "typed" && message.text === "hello mac",
    6000
  );
  assert.equal(typedStatus.text, "hello mac");

  ws.send(JSON.stringify({ type: "action_enter", ts: Date.now() }));
  const enterStatus = await messages.waitFor(
    (message) => message.type === "status" && message.status === "typed" && message.text === "",
    6000
  );
  assert.equal(enterStatus.text, "");

  await sleep(200);
  const output = serverOutput.join("");
  assert.match(output, /\[inject\] dry-run/);
  assert.match(output, /forceEnter:\s*true/);
});
