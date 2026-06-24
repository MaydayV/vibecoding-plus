# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Host bridge for LAN voice coding with an ESP32 device and Codex CLI. Captures push-to-talk audio via WebSocket, transcribes it using STT providers (OpenAI Whisper or Volcengine), and either injects text into Windows input fields or sends it to a managed Codex CLI session.

## Workflow Preferences (Current Project)

- For firmware changes under `firmware/**`, automatically run build first (`idf.py build`).
- After successful firmware build, automatically flash to connected board (`idf.py -p /dev/cu.usbmodem* flash`) when device is present.
- After firmware flash, automatically run host-side regression tests (`npm test` or targeted `node --test ...`).
- If tests fail, automatically attempt focused fixes and rerun relevant tests until passing or a hard blocker appears.
- If flashing fails due to missing device/port, immediately report blocker and continue with build + tests.


ES module Node.js application (requires Node >= 20). Single dependency: `ws` for WebSocket.

### Module Graph

```
client/server/src/server.mjs (entry point — HTTP + WebSocket server)
├── config.mjs           — loads .env, resolves paths, auto-detects CLI shims on Windows
├── discovery-server.mjs — UDP broadcast listener for device discovery
│   └── lan-auth.mjs     — HMAC-SHA256 signing for discovery replies
├── lan-auth.mjs         — validates hello messages (nonce + timestamp freshness)
├── codex-session.mjs    — spawns/manages persistent Codex CLI subprocess
├── claude-session.mjs   — spawns/manages Claude Code CLI (claude -p --output-format stream-json)
├── doctor.mjs           — --doctor diagnostics (STT keys, CLI availability, ports)
├── cli-projector.mjs    — formats CLI state for device e-paper display
├── codex-rate-limits.mjs— reads quota from ~/.codex/sessions .jsonl files
├── stt.mjs              — speech-to-text (OpenAI Whisper / Volcengine ASR)
│   ├── wav.mjs          — PCM16 → WAV header conversion
│   └── paths.mjs        — resolves project root from import.meta.url
└── text-injector.mjs    — text injection via clipboard + hotkey (macOS / Windows)
```

### Protocol Flow

1. **Discovery**: Device sends UDP `discover_host` → server replies with WS URL (optionally HMAC-signed)
2. **Handshake**: Device connects WS → sends `hello` (with HMAC signature if auth enabled) → server sends `hello_ack`, `server_ready`, initial CLI state
3. **PTT cycle**: `ptt_start` → binary PCM16 audio chunks → `ptt_stop` → server transcribes → `transcript_final`
4. **Transcript delivery**: Either immediate dispatch or confirm-on-device (`action_send`/`action_undo`)
5. **Codex mode**: Transcript sent to Codex CLI, JSON event stream parsed, state broadcast to all clients

### Key Design Details

- **Audio format**: 16kHz mono PCM16 (signed 16-bit LE)
- **Authentication**: HMAC-SHA256 with message format `type|field1|field2|...`, nonce replay protection, configurable timestamp window (default 300s)
- **Text injection**: Uses clipboard + Cmd+V + restores previous clipboard (macOS AppleScript); falls back to PowerShell on Windows
- **Codex session**: Spawns via PowerShell wrapper, tracks thread ID for `codex exec resume` continuity
- **CLI projector**: Maintains rolling 8-line log buffer, truncates for e-paper constraints

## Configuration (.env)

**Required** (one STT provider):
- `OPENAI_API_KEY` — for Whisper
- `VOLCENGINE_APP_KEY` + `VOLCENGINE_ACCESS_KEY` — for Volcengine ASR
- `WHISPER_CPP_MODEL_PATH` — for local whisper.cpp ASR

**Key settings**:
- `SEND_TARGET`: `text_injector` (default), `codex_exec`, or `claude_code`
- `TRANSCRIPT_DELIVERY_MODE`: `immediate` (default) or `confirm_on_device`
- `LAN_SHARED_SECRET`: enables HMAC authentication
- `LAN_VOICE_PORT` / `LAN_DISCOVERY_PORT`: network ports (default 8765/8766)

**Claude Code CLI** (when `SEND_TARGET=claude_code`):
- `CLAUDE_COMMAND`: path to `claude` binary (auto-detects `claude.ps1` shim on Windows)
- `CLAUDE_CWD`: working directory (defaults to project root)
- `CLAUDE_ALLOWED_TOOLS`: comma-separated tools to pre-approve (default: `Read,Edit,Write,Bash,Glob,Grep`)
- `CLAUDE_MAX_TURNS`: max agentic turns per prompt (default: 10)
- `CLI_TIMEOUT_SEC`: kill CLI subprocess after N seconds (default: 300, applies to both Codex and Claude)

**Debug/test flags**:
- `MOCK_TRANSCRIPT`: bypass STT with fixed text
- `DRY_RUN_TEXT_INJECTION`: log without typing
- `SAVE_DEBUG_WAV`: save audio to tmp/
