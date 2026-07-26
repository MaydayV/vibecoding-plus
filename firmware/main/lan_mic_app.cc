#include "lan_mic_app.h"
#include "lan_mic_app_internal.h"

#include <cJSON.h>
#include <driver/gpio.h>
#include <esp_log.h>
#include <esp_random.h>
#include <esp_system.h>
#include <esp_timer.h>
#include <lwip/inet.h>
#include <lwip/sockets.h>
#include <mbedtls/md.h>

#include <algorithm>
#include <cmath>
#include <cerrno>
#include <fcntl.h>
#include <cstring>
#include <cstdio>
#include <ctime>
#include <cctype>
#include <string>
#include <vector>

#include <esp_sleep.h>
#include <esp_wifi.h>
#include <esp_netif.h>

#include "board.h"
#include "boards/zectrix-s3-epaper-4.2/config.h"
#include "boards/zectrix-s3-epaper-4.2/rtc_pcf8563.h"

#include "boards/zectrix/zectrix_nfc.h"
extern "C" void ZectrixSetFactoryLedOverride(bool enabled, bool blink);
extern "C" ZectrixNfc* __attribute__((weak)) ZectrixGetNfc();
extern "C" RtcPcf8563* __attribute__((weak)) ZectrixGetRtc();
#include "display.h"
#include "network_interface.h"
#include "settings.h"
#include "ssid_manager.h"
#include "wifi_manager.h"
#include "web_socket.h"

#ifndef CONFIG_LAN_MIC_SERVER_URI
#define CONFIG_LAN_MIC_SERVER_URI ""
#endif
#ifndef CONFIG_LAN_DISCOVERY_ENABLED
#define CONFIG_LAN_DISCOVERY_ENABLED 1
#endif
#ifndef CONFIG_LAN_DISCOVERY_PORT
#define CONFIG_LAN_DISCOVERY_PORT 8766
#endif
#ifndef CONFIG_LAN_DISCOVERY_HOST_ID
#define CONFIG_LAN_DISCOVERY_HOST_ID ""
#endif
#ifndef CONFIG_LAN_SHARED_SECRET
#define CONFIG_LAN_SHARED_SECRET ""
#endif

LanMicApp::LanMicApp()
    : board_(Board::GetInstance()),
      up_nav_driver_(TODO_UP_BUTTON_GPIO,
                     kNavLongPressMs,
                     kNavShortPressMinMs,
                     kNavShortPressMaxMs),
      down_nav_driver_(TODO_DOWN_BUTTON_GPIO,
                       kNavLongPressMs,
                       kNavShortPressMinMs,
                       kNavShortPressMaxMs),
      todo_boot_tap_(kTodoBootDoubleClickWindowMs),
      injector_boot_tap_(kInjectorBootDoubleClickWindowMs) {
    wifi_event_group_ = xEventGroupCreate();
    server_msg_queue_ = xQueueCreate(16, sizeof(PendingServerMessage));
    net_event_queue_ = xQueueCreate(16, sizeof(PendingNetMessage));
    last_user_input_ms_ = esp_timer_get_time() / 1000;
}

LanMicApp::~LanMicApp() {
    DisconnectWebSocket();
    if (server_msg_queue_ != nullptr) {
        PendingServerMessage item;
        while (xQueueReceive(server_msg_queue_, &item, 0) == pdPASS) {
            free(item.data);
        }
        vQueueDelete(server_msg_queue_);
        server_msg_queue_ = nullptr;
    }
    if (net_event_queue_ != nullptr) {
        vQueueDelete(net_event_queue_);
        net_event_queue_ = nullptr;
    }
    if (wifi_event_group_ != nullptr) {
        vEventGroupDelete(wifi_event_group_);
    }
}

bool LanMicApp::Initialize() {
    codec_ = board_.GetAudioCodec();
    display_ = board_.GetDisplay();
    if (codec_ == nullptr) {
        ESP_LOGE(kLanMicTag, "Audio codec is null");
        return false;
    }

    ConfigureButtons();
    // The e-paper status bar already shows device state; keep the board LED
    // off so power/app LED blinking does not look like an error or recording.
    ZectrixSetFactoryLedOverride(true, false);

    LoadPersistedNetworkState();
    codec_->Start();
    codec_->EnableOutput(false);
    codec_->SetOutputVolume(volume_);

    status_text_ = "启动 Wi‑Fi";
    cli_status_text_ = "CLI 空闲";
    cli_phase_text_ = "空闲";
    transcript_text_.clear();
    latest_assistant_text_.clear();
    repo_name_ = "AI";
    send_target_.clear();
    server_uri_.clear();
#if !CONFIG_LAN_DISCOVERY_ENABLED
    if (!cached_server_uri_.empty()) {
        server_uri_ = cached_server_uri_;
    } else if (std::strlen(CONFIG_LAN_MIC_SERVER_URI) > 0) {
        server_uri_ = CONFIG_LAN_MIC_SERVER_URI;
    }
#endif
    audio_frame_buffer_.resize(kFrameSamples);
    cli_log_lines_.clear();
    active_page_ = Page::Summary;
    voice_mode_ = VoiceMode::Normal;
    display_todo_refresh_ms_ = 2000;
    display_coding_refresh_ms_ = 2000;
    display_dark_style_ = false;
    hint_text_ = "长按UP打开菜单\n长按BOOT开始语音";
    phase_ = Phase::Idle;
    network_state_ = NetworkState::Offline;
    RefreshBatteryStatus(/*suppress_display=*/true);
    UpdateDisplay();
    // Force a full e-paper refresh on startup to clear any residual image
    // from a previous firmware (e.g. factory test page)
    if (display_ != nullptr) {
        display_->RequestUrgentFullRefresh();
    }

    board_.SetNetworkEventCallback([this](NetworkEvent event, const std::string& data) {
        switch (event) {
            case NetworkEvent::Connecting:
                EnqueueNetEvent(PendingNetEvent::WifiConnecting, data);
                break;
            case NetworkEvent::Connected:
                EnqueueNetEvent(PendingNetEvent::WifiConnected, data);
                break;
            case NetworkEvent::Disconnected:
                EnqueueNetEvent(PendingNetEvent::WifiDisconnected);
                break;
            case NetworkEvent::WifiConfigModeEnter:
                EnqueueNetEvent(PendingNetEvent::WifiConfigEnter, data);
                break;
            case NetworkEvent::WifiConfigModeExit:
                EnqueueNetEvent(PendingNetEvent::WifiConfigExit);
                break;
            default:
                break;
        }
    });

    board_.StartNetwork();
    return true;
}

LanMicApp::VoiceMode LanMicApp::DesiredVoiceModeForPage(Page page) const {
    return page == Page::Todo ? VoiceMode::Todo : VoiceMode::Normal;
}

bool LanMicApp::SyncVoiceModeToPage(Page page) {
    const VoiceMode desired = DesiredVoiceModeForPage(page);
    if (!IsServerConnected()) {
        voice_mode_ = desired;
        return false;
    }
    if (voice_mode_ == desired) {
        return true;
    }
    if (!SendSetMode(desired == VoiceMode::Todo ? "todo" : "normal")) {
        return false;
    }
    voice_mode_ = desired;
    return true;
}

bool LanMicApp::SyncVoiceModeToActivePage() {
    return SyncVoiceModeToPage(active_page_);
}

LanMicApp::Page LanMicApp::PageForCurrentVoiceMode() const {
    return voice_mode_ == VoiceMode::Todo ? Page::Todo : Page::Summary;
}

bool LanMicApp::StreamAudioFrame() {
    // Hold a strong reference for the whole call: the "lan_reconnect" /
    // "lan_fw_ota" tasks may swap or drop ws_ at any moment.
    const std::shared_ptr<WebSocket> ws = GetWebSocket();
    if (ws == nullptr || !ws->IsConnected()) {
        return false;
    }

    if (!codec_->InputData(audio_frame_buffer_)) {
        return false;
    }

    if (!ws->Send(audio_frame_buffer_.data(), audio_frame_buffer_.size() * sizeof(int16_t), true)) {
        ESP_LOGW(kLanMicTag, "Failed to send audio frame");
        DisconnectWebSocket();
        return false;
    }

    return true;
}

void LanMicApp::CapturePrerollFrame() {
    if (codec_ == nullptr) {
        return;
    }

    std::vector<int16_t> frame(kFrameSamples);
    if (!codec_->InputData(frame)) {
        return;
    }

    if (preroll_frames_.size() >= kPrerollFrameCount) {
        preroll_frames_.pop_front();
    }
    preroll_frames_.push_back(std::move(frame));
}

bool LanMicApp::FlushPrerollFrames() {
    const std::shared_ptr<WebSocket> ws = GetWebSocket();
    if (ws == nullptr || !ws->IsConnected()) {
        preroll_frames_.clear();
        return false;
    }

    while (!preroll_frames_.empty()) {
        auto& frame = preroll_frames_.front();
        if (!ws->Send(frame.data(), frame.size() * sizeof(int16_t), true)) {
            ESP_LOGW(kLanMicTag, "Failed to send preroll frame");
            preroll_frames_.clear();
            DisconnectWebSocket();
            return false;
        }
        preroll_frames_.pop_front();
    }

    return true;
}

void LanMicApp::EnqueueServerMessage(const char* data, size_t len) {
    if (server_msg_queue_ == nullptr || data == nullptr || len == 0) {
        return;
    }
    auto* copy = static_cast<char*>(malloc(len));
    if (copy == nullptr) {
        return;
    }
    memcpy(copy, data, len);
    PendingServerMessage item{copy, len};
    if (xQueueSend(server_msg_queue_, &item, 0) != pdPASS) {
        free(copy);
        ESP_LOGW(kLanMicTag, "server msg queue full, dropped");
    }
}

void LanMicApp::EnqueueNetEvent(PendingNetEvent event, const std::string& data, int code) {
    if (net_event_queue_ == nullptr) {
        return;
    }
    PendingNetMessage item{};
    item.event = event;
    item.code = code;
    if (!data.empty()) {
        snprintf(item.data, sizeof(item.data), "%s", data.c_str());
    }
    if (xQueueSend(net_event_queue_, &item, 0) != pdPASS) {
        ESP_LOGW(kLanMicTag, "net event queue full, dropped event=%u", static_cast<unsigned>(event));
    }
}

void LanMicApp::TouchUserInput(int64_t now_ms) {
    last_user_input_ms_ = now_ms;
}

void LanMicApp::HandleWsConnected(const std::string& target_uri_text) {
    board_.SetPowerSaveLevel(PowerSaveLevel::BALANCED);
    SaveCachedServerUri(target_uri_text);
    network_state_ = NetworkState::Server;
    status_text_ = "已连接";
    hint_text_ = "";
    phase_ = Phase::Idle;
    ShowIdleTodoPage();
    UpdateDisplay();
    if (display_ != nullptr) {
        display_->RequestUrgentFullRefresh();
    }
    if (GetSharedSecret().empty()) {
        SendHello();
    }
}

void LanMicApp::HandleNetEvent(const PendingNetMessage& message) {
    switch (message.event) {
        case PendingNetEvent::WifiConnecting:
            ESP_LOGI(kLanMicTag, "WiFi connecting: %s", message.data);
            network_state_ = NetworkState::Offline;
            status_text_ = "Wi‑Fi 连接中";
            hint_text_ = message.data[0] != '\0' ? message.data : "";
            UpdateDisplay();
            break;
        case PendingNetEvent::WifiConnected:
            ESP_LOGI(kLanMicTag, "WiFi connected: %s", message.data);
            xEventGroupSetBits(wifi_event_group_, kWifiConnectedBit);
            network_state_ = NetworkState::Wifi;
            status_text_ = "Wi‑Fi 已连接";
            server_uri_.clear();
            hint_text_ = CONFIG_LAN_DISCOVERY_ENABLED ? GetDiscoveryHintText() : "连接服务器中...";
            UpdateDisplay();
            if (!cached_server_uri_.empty()) {
                RefreshNfcForOfflineSetup(cached_server_uri_);
            }
            break;
        case PendingNetEvent::WifiDisconnected:
            ESP_LOGW(kLanMicTag, "WiFi disconnected");
            xEventGroupClearBits(wifi_event_group_, kWifiConnectedBit);
            network_state_ = NetworkState::Offline;
            status_text_ = "Wi‑Fi 已断开";
            hint_text_ = "检查 Wi‑Fi\n长按上下键进入配网";
            server_uri_.clear();
            DisconnectWebSocket();
            if (active_page_ == Page::Todo) {
                offline_todo_mode_ = true;
                todo_last_action_text_ = "离线待办";
            } else {
                active_page_ = Page::Summary;
            }
            UpdateDisplay();
            break;
        case PendingNetEvent::WifiConfigEnter:
            ESP_LOGW(kLanMicTag, "WiFi config mode: %s", message.data);
            network_state_ = NetworkState::Config;
            status_text_ = "Wi‑Fi 配网模式";
            hint_text_ = message.data;
            active_page_ = Page::Summary;
            summary_scroll_offset_ = 0;
            UpdateDisplay();
            UpdateNfcProvisionUri(message.data);
            break;
        case PendingNetEvent::WifiConfigExit:
            ESP_LOGI(kLanMicTag, "WiFi config mode exited");
            network_state_ = NetworkState::Offline;
            if (SsidManager::GetInstance().GetSsidList().empty()) {
                ESP_LOGW(kLanMicTag, "WiFi config mode exited without saved credentials; skip reboot");
                status_text_ = "Wi‑Fi 配网模式";
                hint_text_ = "未检测到已保存网络";
                active_page_ = Page::Summary;
                summary_scroll_offset_ = 0;
                UpdateDisplay();
                break;
            }
            RequestWifiReconfigureByReboot("重启中...", "正在应用 Wi‑Fi 配置");
            break;
        case PendingNetEvent::WsConnected:
            HandleWsConnected(message.data[0] != '\0' ? std::string(message.data) : pending_connect_uri_);
            break;
        case PendingNetEvent::WsError:
            network_state_ = IsWifiConnected() ? NetworkState::Wifi : NetworkState::Offline;
            status_text_ = "服务器错误";
            hint_text_ = "将自动重试";
            phase_ = Phase::Error;
            active_page_ = Page::Summary;
            UpdateDisplay();
            break;
        case PendingNetEvent::ConnectSearching:
            status_text_ = "正在查找主机";
            hint_text_ = GetDiscoveryHintText();
            UpdateDisplay();
            break;
        case PendingNetEvent::ConnectFailed:
            status_text_ = "连接失败";
            hint_text_ = message.data;
            UpdateDisplay();
            break;
        case PendingNetEvent::DiscoveryFound:
            status_text_ = "发现主机";
            hint_text_ = message.data;
            UpdateDisplay();
            break;
        case PendingNetEvent::OtaProgress: {
            char progress_text[sizeof(message.data) + 16];
            snprintf(progress_text, sizeof(progress_text), "%s %d%%", message.data, message.code);
            hint_text_ = progress_text;
            UpdateDisplay();
            break;
        }
        case PendingNetEvent::OtaFailed:
            phase_ = Phase::Error;
            status_text_ = "升级失败";
            hint_text_ = message.data;
            UpdateDisplay();
            break;
    }
}

void LanMicApp::DrainPendingEvents(int64_t now_ms) {
    PendingServerMessage item;
    while (server_msg_queue_ != nullptr &&
           xQueueReceive(server_msg_queue_, &item, 0) == pdPASS) {
        HandleServerMessage(item.data, item.len);
        free(item.data);
    }

    // Apply the connect task's discovery result before its net events, so a
    // DiscoveryFound hint renders against already-committed state. The fault
    // is applied after, so a URI that was discovered and then failed to
    // connect still gets invalidated.
    CommitDiscoveryOutcome();

    PendingNetMessage net_item;
    while (net_event_queue_ != nullptr &&
           xQueueReceive(net_event_queue_, &net_item, 0) == pdPASS) {
        HandleNetEvent(net_item);
    }

    ApplyConnectTargetFault();

    if (ws_connected_pending_.exchange(false, std::memory_order_acq_rel)) {
        PendingNetMessage connected{};
        connected.event = PendingNetEvent::WsConnected;
        snprintf(connected.data, sizeof(connected.data), "%s", pending_connect_uri_.c_str());
        HandleNetEvent(connected);
    }

    if (ws_error_pending_.exchange(false, std::memory_order_acq_rel)) {
        PendingNetMessage error{};
        error.event = PendingNetEvent::WsError;
        error.code = ws_error_code_.load(std::memory_order_acquire);
        HandleNetEvent(error);
    }
}

