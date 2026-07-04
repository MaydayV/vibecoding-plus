import Foundation

/// Generated from doc/protocol.yaml — do not edit by hand.
enum LANProtocol {
    static let version = 1
}

enum LANDeviceMessage {
    static let hello = "hello"
    static let ptt_start = "ptt_start"
    static let ptt_stop = "ptt_stop"
    static let action_send = "action_send"
    static let action_undo = "action_undo"
    static let action_enter = "action_enter"
    static let action_clear_input = "action_clear_input"
    static let set_mode = "set_mode"
    static let set_target = "set_target"
    static let set_cli_cwd = "set_cli_cwd"
    static let todo_command = "todo_command"
    static let plan_select = "plan_select"
    static let plan_apply = "plan_apply"
    static let ping = "ping"
    static let prompt = "prompt"
    static let firmware_progress = "firmware_progress"
    static let firmware_result = "firmware_result"
    static let firmware_check_result = "firmware_check_result"
    static let discover_host = "discover_host"
}

enum LANServerMessage {
    static let auth_challenge = "auth_challenge"
    static let hello_ack = "hello_ack"
    static let server_ready = "server_ready"
    static let display_config = "display_config"
    static let transcript_final = "transcript_final"
    static let transcript_partial = "transcript_partial"
    static let transcript_cleared = "transcript_cleared"
    static let status = "status"
    static let mode_state = "mode_state"
    static let todo_state = "todo_state"
    static let todo_result = "todo_result"
    static let cli_session_state = "cli_session_state"
    static let cli_summary = "cli_summary"
    static let cli_log_tail = "cli_log_tail"
    static let cli_cwd_updated = "cli_cwd_updated"
    static let plan_options = "plan_options"
    static let force_refresh = "force_refresh"
    static let device_event = "device_event"
    static let pong = "pong"
    static let warning = "warning"
    static let error = "error"
    static let firmware_check = "firmware_check"
    static let firmware_offer = "firmware_offer"
    static let provision_secret = "provision_secret"
    static let discover_reply = "discover_reply"
}

enum LANSendTarget {
    static let text_injector = "text_injector"
    static let codex_exec = "codex_exec"
    static let claude_code = "claude_code"
}

enum LANVoiceMode {
    static let normal = "normal"
    static let todo = "todo"
}
