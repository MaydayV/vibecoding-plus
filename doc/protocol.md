# LAN WebSocket Protocol v1

> `protocolVersion: 1` — carried in `hello_ack` and `server_ready`.  
> Firmware constant: `kProtocolVersion` in `lan_mic_app.cc`.

## Transport

- WebSocket (RFC 6455), server → client path: macOS `NativeServer` on `LAN_VOICE_PORT` (default **8765**).
- Text frames: JSON objects with required `type` string field.
- Binary frames: PCM16 mono 16 kHz audio during PTT (device → server only).

## Authentication

When `LAN_SHARED_SECRET` is set:

1. Server → device: `auth_challenge { serverNonce }`
2. Device → server: `hello` with `sig = HMAC(secret, "hello|deviceId|boardType|serverNonce|deviceNonce")`

Without secret, `hello` may omit `sig` / `deviceNonce`.

## Device → Server

| type | Fields | Semantics |
|---|---|---|
| `hello` | `deviceId`, `boardType`, `deviceNonce?`, `sig?` | Handshake after WS connect |
| `ptt_start` | `ts?`, `source?` | Begin audio capture |
| `ptt_stop` | `ts?` | End capture; server transcribes |
| `action_send` | — | Confirm pending transcript (confirm mode) |
| `action_undo` | — | Undo pending segment or last injection |
| `action_enter` | — | Send Enter to focused app |
| `action_clear_input` | — | Clear focused input |
| `set_mode` | `mode`: `normal` \| `todo` | Switch voice routing mode |
| `todo_command` | `action`, `index?`, `id?`, `completed?`, `text?` | Todo CRUD |
| `plan_select` | `direction`: `-1` \| `1` | Move plan option cursor (legacy) |
| `plan_apply` | — | Apply selected plan (legacy; not product direction) |
| `ping` | — | Keepalive |

## Server → Device

| type | Fields | Semantics |
|---|---|---|
| `auth_challenge` | `serverNonce` | Challenge for HMAC hello |
| `hello_ack` | `deviceId`, `protocolVersion` | Handshake accepted |
| `server_ready` | `protocolVersion`, `sendTarget`, `textInjectionMode`, `transcriptDeliveryMode`, `authRequired`, `displayTodoRefreshMs`, `displayCodingRefreshMs`, `displayStyle` | Runtime config snapshot |
| `display_config` | layout fields | E-paper layout tuning |
| `transcript_final` | `text` | STT result |
| `transcript_cleared` | — | Pending transcript emptied |
| `status` | `status`, `text?`, `message?` | `typed`, `awaiting_action`, `undo_ok`, `input_error`, `no_pending`, … |
| `mode_state` | `mode` | Server-side mode echo |
| `todo_state` | `items[]`, `selectedIndex`, `lastActionText?` | Todo list mirror |
| `todo_result` | `ok`, `action`, `message` | Todo command result |
| `cli_session_state` | `phase`, `statusLine`, `threadId`, `repoName`, `cwd`, `quota5hRemainingPct?`, `quotaWeekRemainingPct?` | CLI phase mirror |
| `cli_summary` | `latestUserText`, `latestAssistantText`, `statusLine`, `threadId`, `repoName` | Latest prompt/response |
| `cli_log_tail` | `lines[]` | Rolling log for e-paper |
| `plan_options` | `options[]`, `selectedIndex` | Legacy plan UI |
| `force_refresh` | — | Redraw display |
| `device_event` | `event`, `deviceId`, `boardType` | Multi-client admin |
| `firmware_*` | (reserved) | OTA — not implemented |

## sendTarget values

| Value | Behavior |
|---|---|
| `text_injector` | Inject transcript into focused app |
| `codex_exec` | Run `codex exec --json` per voice prompt |
| `claude_code` | Run `claude -p --output-format stream-json` per voice prompt |

External terminal sessions are mirrored read-only via rollout/transcript file watchers (§8.5 D1/D2); no protocol change.

## Versioning policy

- Unknown `type`: log `unknown_message_type`, ignore.
- `protocolVersion` mismatch: log warning, best-effort continue.
- Breaking changes require incrementing `protocolVersion` and updating both firmware and macOS client.
