#ifndef LAN_MIC_APP_H
#define LAN_MIC_APP_H

#include <atomic>
#include <deque>
#include <memory>
#include <string>
#include <vector>

#include <driver/gpio.h>
#include <freertos/FreeRTOS.h>
#include <freertos/event_groups.h>
#include <freertos/queue.h>

#include "audio_codec.h"
#include "input/deferred_tap_tracker.h"
#include "input/gpio_input_driver.h"

struct cJSON;

class Board;
class Display;
class WebSocket;

class LanMicApp {
public:
    LanMicApp();
    ~LanMicApp();

    void Run();

private:
    Board& board_;
    AudioCodec* codec_ = nullptr;
    Display* display_ = nullptr;
    std::unique_ptr<WebSocket> ws_;
    EventGroupHandle_t wifi_event_group_ = nullptr;
    GpioInputDriver up_nav_driver_;
    GpioInputDriver down_nav_driver_;
    DeferredTapTracker todo_boot_tap_;
    DeferredTapTracker injector_boot_tap_;
    bool hello_sent_ = false;
    std::atomic<bool> ws_disconnected_pending_{false};
    std::atomic<bool> ws_connected_pending_{false};
    std::atomic<bool> ws_error_pending_{false};
    std::atomic<int> ws_error_code_{0};
    std::string pending_connect_uri_;
    std::atomic<bool> connect_attempt_running_{false};
    std::atomic<bool> connect_attempt_completed_{false};
    std::atomic<bool> connect_cancel_requested_{false};
    std::atomic<bool> manual_reconnect_requested_{false};
    std::atomic<int64_t> connect_attempt_started_ms_{0};
    std::atomic<bool> wifi_reconfigure_restart_pending_{false};
    int reconnect_failure_count_ = 0;
    int64_t last_wifi_recovery_ms_ = 0;
    std::atomic<TaskHandle_t> connect_task_handle_{nullptr};
    int64_t last_user_input_ms_ = 0;
    std::string auth_server_nonce_;
    bool auth_challenge_received_ = false;
    struct PendingServerMessage {
        char* data = nullptr;
        size_t len = 0;
    };
    QueueHandle_t server_msg_queue_ = nullptr;
    enum class PendingNetEvent : uint8_t {
        WifiConnecting,
        WifiConnected,
        WifiDisconnected,
        WifiConfigEnter,
        WifiConfigExit,
        WsConnected,
        WsError,
    };
    struct PendingNetMessage {
        PendingNetEvent event;
        char data[192];
        int code = 0;
    };
    QueueHandle_t net_event_queue_ = nullptr;
    bool has_pending_transcript_ = false;
    std::string send_target_;         // received from server_ready: "claude_code" | "codex_exec" | "text_injector"
    int display_todo_refresh_ms_ = 800;
    int display_coding_refresh_ms_ = 800;
    bool display_dark_style_ = false;
    std::vector<int16_t> audio_frame_buffer_; // reused across StreamAudioFrame() calls
    std::deque<std::vector<int16_t>> preroll_frames_;
    enum class Phase {
        Idle,
        Recording,
        Transcribing,
        AwaitingAction,
        Running,
        Upgrading,
        Error
    };
    enum class Page {
        Summary,
        Todo,
        Log,
        Settings
    };
    enum class VoiceMode {
        Normal,
        Todo
    };
    enum class TodoMenuKind {
        Todo,
        TodoAction,
        Live,
        ReconnectStuck
    };
    struct TodoItem {
        std::string id;
        std::string title;
        bool completed = false;
        std::string due_at;
    };
    enum class PendingTodoOpType {
        Toggle,
        Delete
    };
    struct PendingTodoOp {
        PendingTodoOpType type = PendingTodoOpType::Toggle;
        std::string id;
        bool completed = false;
    };

    // Settings page state
    static constexpr int kSettingsItemCount = 4;
    static constexpr int kSettingsItemVolume   = 0;
    static constexpr int kSettingsItemWifi     = 1;
    static constexpr int kSettingsItemRestart  = 2;
    static constexpr int kSettingsItemPowerOff = 3;
    int settings_selected_item_ = 0;
    bool settings_editing_volume_ = false;
    int volume_ = 70;
    enum class NetworkState {
        Offline,
        Wifi,
        Server,
        Config
    };

    Phase phase_ = Phase::Idle;
    Page active_page_ = Page::Todo;
    VoiceMode voice_mode_ = VoiceMode::Todo;
    NetworkState network_state_ = NetworkState::Offline;
    std::string status_text_;
    std::string transcript_text_;
    std::string cli_status_text_;
    std::string cli_phase_text_;
    std::string latest_assistant_text_;
    std::string repo_name_;
    std::string server_uri_;
    std::vector<std::string> cli_log_lines_;
    std::vector<TodoItem> todo_items_;
    std::vector<PendingTodoOp> pending_todo_ops_;
    std::vector<std::string> plan_options_;
    int plan_selected_index_ = -1;
    int todo_selected_index_ = -1;
    std::string todo_last_action_text_;
    bool todo_menu_open_ = false;
    TodoMenuKind todo_menu_kind_ = TodoMenuKind::Todo;
    int todo_menu_selected_item_ = 0;
    bool offline_todo_mode_ = false;
    bool reconnect_stuck_prompt_ = false;
    bool pending_normal_after_reconnect_ = false;
    std::string hint_text_;
    int quota_5h_remaining_pct_ = -1;
    int quota_week_remaining_pct_ = -1;
    int battery_level_ = 0;
    bool battery_known_ = false;
    bool battery_charging_ = false;
    bool battery_discharging_ = false;
    int summary_scroll_offset_ = 0;
    int log_scroll_offset_ = 0;
    std::string cached_server_uri_;
    std::string paired_host_id_;
    std::string paired_host_name_;
    std::string nfc_last_uri_;
    bool todo_nvs_dirty_ = false;
    int64_t todo_nvs_dirty_since_ms_ = 0;
    std::string todo_nvs_pending_snapshot_;
    std::string todo_nvs_last_written_snapshot_;

    bool Initialize();
    void LoadPersistedNetworkState();
    void SaveCachedServerUri(const std::string& server_uri);
    void SavePairedHost(const std::string& host_id, const std::string& host_name);
    void ClearPersistedHost();
    void ClearCachedServerUri();
    void UpdateNfcProvisionUri(const std::string& event_hint);
    void RefreshNfcForOfflineSetup(const std::string& ws_uri, const std::string& pair_url = "");
    void WriteNfcUriIfNeeded(const std::string& uri, const char* reason);
    std::string BuildSetupUrlFromWsUri(const std::string& ws_uri) const;
    void RequestWifiReconfigureByReboot(const char* status_text, const char* hint_text);
    void ConfigureButtons();
    bool IsWifiConnected() const;
    bool IsServerConnected() const;
    bool EnsureWebSocketConnected();
    void StartConnectAttemptAsync();
    void RunConnectAttemptTask();
    bool DiscoverServerUri();
    std::string GetExpectedDiscoveryHostId() const;
    std::string GetFallbackServerUri() const;
    std::string GetDiscoveryHintText() const;
    std::string MakeAuthNonce() const;
    std::string HmacSha256Hex(const std::vector<std::string>& parts) const;
    void EnterWifiSetupMode();
    void DisconnectWebSocket();
    void RecoverWifiForReconnect(const char* reason = "");
    void EnterOfflineDeepSleep();
    bool IsPttPressed() const;
    bool IsNavButtonPressed(gpio_num_t gpio_num) const;
    bool SendJson(const char* json);
    bool SendJsonObject(cJSON* root);
    bool SendFirmwareProgress(const char* phase, int pct, const char* error);
    bool SendFirmwareResult(bool ok, const char* version, const char* message);
    bool SendFirmwareCheckResult(bool need_upgrade, const char* current_version);
    void HandleFirmwareCheck(cJSON* root);
    std::string GetSharedSecret() const;
    void SaveSharedSecret(const std::string& secret);
    void HandleFirmwareOffer(cJSON* root);
    bool SendHello();
    bool SendPttStart();
    bool SendPttStop();
    bool SendEnter();
    bool SendClearInput();
    bool SendAction(const char* action_type);
    bool SendSetMode(const char* mode);
    bool SendTodoCommand(const char* action, int index = 0, int completed = -1, const char* id = nullptr);
    bool SendPlanSelect(int direction);
    bool SendPlanApply();
    VoiceMode DesiredVoiceModeForPage(Page page) const;
    bool SyncVoiceModeToPage(Page page);
    bool SyncVoiceModeToActivePage();
    Page PageForCurrentVoiceMode() const;
    bool StreamAudioFrame();
    void CapturePrerollFrame();
    bool FlushPrerollFrames();
    void EnqueueServerMessage(const char* data, size_t len);
    void EnqueueNetEvent(PendingNetEvent event, const std::string& data = "");
    void DrainPendingEvents(int64_t now_ms);
    void HandleWsConnected(const std::string& target_uri);
    void HandleNetEvent(const PendingNetMessage& message);
    void TouchUserInput(int64_t now_ms);
    void HandleServerMessage(const char* data, size_t len);
    void RefreshBatteryStatus(bool force_update = false);
    void HandleScroll(int direction);
    void MoveTodoSelection(int direction);
    void ToggleSelectedTodo();
    void DeleteSelectedTodo();
    void OpenTodoMenu(TodoMenuKind kind = TodoMenuKind::Todo);
    void CloseTodoMenu();
    int GetTodoMenuItemCount() const;
    std::string GetTodoMenuItemLabel(int item) const;
    void HandleTodoMenuInput(bool up_click, bool down_click, bool boot_press);
    void ExecuteTodoMenuItem(int item);
    void EnterOfflineTodoMode(const std::string& message);
    void RequestReconnect(const std::string& message);
    void QueueOfflineTodoToggle(const TodoItem& item, bool completed);
    void QueueOfflineTodoDelete(const TodoItem& item);
    void FlushPendingTodoOps();
    void LoadCachedTodoState();
    void SaveCachedTodoState();
    void FlushCachedTodoStateIfNeeded(int64_t now_ms, bool force = false);
    std::string BuildCachedTodoStateJson() const;
    void LoadPendingTodoOps();
    void SavePendingTodoOps();
    void SwitchPage(Page page);
    void EnterSettings();
    void HandleSettingsInput(bool up_click, bool down_click, bool boot_press);
    void ExecuteSettingsItem(int item);
    void Shutdown();
    void SaveVolume();
    const char* GetNetworkLabel() const;
    std::string GetPhaseLabel() const;
    const char* GetModeLabel() const;
    const char* GetToolLabel() const;  // "Claude" | "Codex" | "Inject"
    std::string GetFooterText() const;
    std::string BuildPromptBody() const;
    std::string BuildReplyBody() const;
    bool ShouldShowIdleTodoPage() const;
    void ShowIdleTodoPage();
    std::vector<std::string> WrapText(const std::string& text, size_t max_chars) const;
    std::vector<std::string> SliceLines(const std::vector<std::string>& lines, int offset, size_t max_lines) const;
    void UpdateLed();
    void PlayBeep(int freq_hz, int duration_ms);
    void DrawHorizontalLine(int y, int thickness = 1);
    void DrawTodoDashLine(int y, int x_start, int x_end);
    void DrawTodoHeaderIcon(int x, int y);
    void DrawWifiIcon(int x, int y);
    void DrawBatteryIcon(int x, int y, int level, bool charging);
    void UpdateDisplay();
};

#endif // LAN_MIC_APP_H
