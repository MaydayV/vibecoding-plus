#!/usr/bin/env node
// Protocol smoke test against NativeServer (run app with MOCK_TRANSCRIPT=smoke-ok first).
import { WebSocket } from "ws";

const url = process.env.MOCK_SERVER_URL || "ws://127.0.0.1:8765";
const secret = process.env.LAN_SHARED_SECRET || "";
const timeoutMs = Number(process.env.MOCK_TIMEOUT_MS || 8000);

const seen = new Set();
let failed = false;

function fail(message) {
  failed = true;
  console.error(`FAIL: ${message}`);
  ws.close();
}

const ws = new WebSocket(url);
const timer = setTimeout(() => fail(`timeout after ${timeoutMs}ms`), timeoutMs);

ws.on("open", () => {
  console.log("connected");
  if (!secret) {
    ws.send(JSON.stringify({ type: "hello", deviceId: "mock-client", boardType: "mock" }));
  }
});

ws.on("message", (msg) => {
  let data;
  try {
    data = JSON.parse(msg.toString());
  } catch {
    console.log("binary", msg.length);
    return;
  }
  console.log("←", data.type, JSON.stringify(data).slice(0, 120));
  seen.add(data.type);

  if (data.type === "auth_challenge") {
    if (!secret) {
      ws.send(JSON.stringify({ type: "hello", deviceId: "mock-client", boardType: "mock" }));
      return;
    }
    fail("auth_challenge received but LAN_SHARED_SECRET not set for mock signing");
    return;
  }

  if (data.type === "server_ready") {
    if (data.protocolVersion !== 1) {
      fail(`unexpected protocolVersion: ${data.protocolVersion}`);
      return;
    }
    ws.send(JSON.stringify({ type: "set_mode", mode: "todo" }));
    ws.send(JSON.stringify({ type: "ptt_start", ts: Date.now() }));
    ws.send(Buffer.alloc(640, 1));
    setTimeout(() => ws.send(JSON.stringify({ type: "ptt_stop", ts: Date.now() })), 50);
    return;
  }

  if (data.type === "transcript_final") {
    if (!String(data.text || "").length) {
      fail("empty transcript_final");
      return;
    }
    ws.send(JSON.stringify({ type: "action_undo" }));
    return;
  }

  if (data.type === "status" && (data.status === "undo_ok" || data.status === "no_pending")) {
    clearTimeout(timer);
    const required = ["hello_ack", "server_ready"];
    for (const type of required) {
      if (!seen.has(type)) fail(`missing ${type}`);
    }
    if (!failed) {
      console.log("PASS: hello → server_ready → ptt → transcript → undo");
      process.exitCode = 0;
    }
    ws.close();
  }
});

ws.on("close", () => {
  clearTimeout(timer);
  if (!failed && process.exitCode !== 0) {
    fail("closed before completing flow");
  }
  process.exit(failed ? 1 : 0);
});

ws.on("error", (error) => {
  clearTimeout(timer);
  console.error(error);
  process.exit(1);
});
