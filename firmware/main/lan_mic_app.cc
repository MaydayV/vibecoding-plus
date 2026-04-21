#include "lan_mic_app.h"

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
#include <cstring>
#include <cstdio>
#include <ctime>
#include <cctype>
#include <string>
#include <vector>

#include <esp_sleep.h>

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

namespace {

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

constexpr char kTag[] = "LanMicApp";
constexpr char kDiscoveryService[] = "vibecoding-plus";
constexpr char kLanMicNamespace[] = "lan_mic";
constexpr char kVolumeKey[] = "volume";
constexpr char kLastServerUriKey[] = "last_srv_uri";
constexpr char kPairedHostIdKey[] = "pair_host_id";
constexpr char kPairedHostNameKey[] = "pair_host_nm";
constexpr char kPendingTodoOpsKey[] = "todo_ops";
constexpr char kCachedTodoStateKey[] = "todo_cache";
constexpr EventBits_t kWifiConnectedBit = BIT0;
constexpr int kFrameDurationMs = 20;
constexpr int kSampleRate = 16000;
constexpr int kFrameSamples = kSampleRate * kFrameDurationMs / 1000;
constexpr size_t kPrerollFrameCount = 45;      // 900 ms @ 20 ms per frame
constexpr int kDiscoveryAttempts = 3;
constexpr int kDiscoveryTimeoutMs = 600;
constexpr int kDiscoveryRetryDelayMs = 150;
constexpr int64_t kReconnectIntervalMinMs = 2000;
constexpr int64_t kReconnectIntervalMaxMs = 60000;
constexpr int64_t kClientPingIntervalMs = 10000;
constexpr int64_t kPongTimeoutMs = 15000;
constexpr int64_t kServerSilenceTimeoutMs = 45000;
constexpr int64_t kConnectAttemptWatchdogMs = 20000;
constexpr int64_t kReconnectPromptTimeoutMs = 15000;
constexpr int64_t kTodoBootHoldMs = 600;
constexpr int64_t kTodoBootDoubleClickWindowMs = 350;
constexpr uint32_t kConnectTaskStackSize = 6 * 1024;
constexpr UBaseType_t kConnectTaskPriority = 2;
// If no server connection is established within this window, enter deep sleep
// to preserve battery.  BOOT button or a 5-minute timer wakes the board for
// another retry cycle.  Pressing BOOT while disconnected resets this window.
constexpr int64_t kNoConnectionSleepMs = 5LL * 60 * 1000;  // 5 minutes
constexpr size_t kBodyCharsPerLine = 22;
constexpr size_t kPromptVisibleLines = 3;
constexpr size_t kReplyVisibleLines = 4;
constexpr size_t kLogVisibleLines = 8;
constexpr int kStatusBarBottomY = 31;
constexpr int kHeaderLineY = 62;
constexpr int kPromptDividerY = 156;
constexpr int kFooterTopY = 264;
constexpr int kContentHeaderY = 44;
constexpr int kPromptTitleY = 74;
constexpr int kPromptBodyY = 96;
constexpr int kReplyTitleY = 168;
constexpr int kReplyBodyY = 190;
constexpr int kLogTitleY = 74;
constexpr int kLogBodyY = 96;
constexpr int kFooterTextY = 276;
constexpr int kLineHeight = 18;
constexpr int kBatteryPollIntervalMs = 15000;
constexpr size_t kCachedTodoStateMaxBytes = 3500;
constexpr uint8_t kWifiIcon12x12[] = {
    0x00, 0x00,
    0x03, 0xC0,
    0x0C, 0x30,
    0x10, 0x08,
    0x03, 0xC0,
    0x04, 0x20,
    0x08, 0x10,
    0x01, 0x80,
    0x02, 0x40,
    0x00, 0x00,
    0x00, 0x00,
    0x00, 0x00,
};

constexpr uint8_t kBatteryIcon14x8[] = {
    0xFF, 0xFC,
    0x80, 0x04,
    0x80, 0x04,
    0x80, 0x04,
    0x80, 0x04,
    0x80, 0x04,
    0x80, 0x04,
    0xFF, 0xFC,
};


std::string FormatTwoDigits(int value) {
    if (value < 0) {
        value = 0;
    }
    if (value > 99) {
        value = value % 100;
    }
    char buffer[4];
    snprintf(buffer, sizeof(buffer), "%02d", value);
    return std::string(buffer);
}

std::string FormatTodoClockText(const tm& local_tm) {
    return FormatTwoDigits(local_tm.tm_hour) + ":" + FormatTwoDigits(local_tm.tm_min);
}

std::string FormatTodoDateText(const tm& local_tm) {
    static const char* kWeekdaysCn[] = {"周日", "周一", "周二", "周三", "周四", "周五", "周六"};
    const int wday = (local_tm.tm_wday >= 0 && local_tm.tm_wday <= 6) ? local_tm.tm_wday : 0;
    return FormatTwoDigits(local_tm.tm_mon + 1) + "/" +
           FormatTwoDigits(local_tm.tm_mday) + " " +
           kWeekdaysCn[wday];
}

std::string FormatTodoRightTimeText(const std::string& due_at) {
    if (due_at.empty()) {
        return "--:--";
    }

    std::string text = due_at;
    const size_t t_pos = text.find('T');
    if (t_pos == std::string::npos || t_pos + 6 > text.size()) {
        return "--:--";
    }

    const std::string hh = text.substr(t_pos + 1, 2);
    const std::string mm = text.substr(t_pos + 4, 2);
    if (!std::isdigit(static_cast<unsigned char>(hh[0])) ||
        !std::isdigit(static_cast<unsigned char>(hh[1])) ||
        !std::isdigit(static_cast<unsigned char>(mm[0])) ||
        !std::isdigit(static_cast<unsigned char>(mm[1]))) {
        return "--:--";
    }

    return hh + ":" + mm;
}

std::vector<std::string> WrapUtf8Lines(const std::string& text, size_t max_chars, size_t max_lines = 0) {
    std::vector<std::string> lines;
    std::string current;
    size_t current_chars = 0;
    const bool unlimited = max_lines == 0;

    auto push_line = [&]() {
        lines.push_back(current);
        current.clear();
        current_chars = 0;
    };

    for (size_t i = 0; i < text.size();) {
        const unsigned char ch = static_cast<unsigned char>(text[i]);
        size_t char_len = 1;
        if ((ch & 0x80) == 0x00) {
            char_len = 1;
        } else if ((ch & 0xE0) == 0xC0) {
            char_len = 2;
        } else if ((ch & 0xF0) == 0xE0) {
            char_len = 3;
        } else if ((ch & 0xF8) == 0xF0) {
            char_len = 4;
        }

        if (i + char_len > text.size()) {
            char_len = 1;
        }

        // Newline: flush current line without a string copy per codepoint
        if (char_len == 1 && text[i] == '\n') {
            push_line();
            i += 1;
            if (!unlimited && lines.size() >= max_lines) {
                return lines;
            }
            continue;
        }

        // Append codepoint bytes directly — avoids substr() allocation per character
        current.append(text, i, char_len);
        i += char_len;
        current_chars++;
        if (current_chars >= max_chars) {
            push_line();
            if (!unlimited && lines.size() >= max_lines) {
                return lines;
            }
        }
    }

    if (!current.empty() && (unlimited || lines.size() < max_lines)) {
        lines.push_back(current);
    }
    return lines;
}

const char* GetJsonString(cJSON* root, const char* key) {
    cJSON* item = cJSON_GetObjectItemCaseSensitive(root, key);
    if (!cJSON_IsString(item) || item->valuestring == nullptr) {
        return nullptr;
    }
    return item->valuestring;
}

bool GetJsonBool(cJSON* root, const char* key, bool fallback) {
    cJSON* item = cJSON_GetObjectItemCaseSensitive(root, key);
    if (cJSON_IsBool(item)) {
        return cJSON_IsTrue(item);
    }
    return fallback;
}

} // namespace

LanMicApp::LanMicApp()
    : board_(Board::GetInstance()),
      up_button_(TODO_UP_BUTTON_GPIO, false, 800),
      down_button_(TODO_DOWN_BUTTON_GPIO, false, 800) {
    wifi_event_group_ = xEventGroupCreate();
}

LanMicApp::~LanMicApp() {
    DisconnectWebSocket();
    if (wifi_event_group_ != nullptr) {
        vEventGroupDelete(wifi_event_group_);
    }
}

bool LanMicApp::Initialize() {
    codec_ = board_.GetAudioCodec();
    display_ = board_.GetDisplay();
    if (codec_ == nullptr) {
        ESP_LOGE(kTag, "Audio codec is null");
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
    display_todo_refresh_ms_ = 800;
    display_coding_refresh_ms_ = 800;
    display_dark_style_ = false;
    hint_text_ = "长按UP打开菜单\n长按BOOT开始语音";
    phase_ = Phase::Idle;
    network_state_ = NetworkState::Offline;
    RefreshBatteryStatus(true);
    UpdateDisplay();
    // Force a full e-paper refresh on startup to clear any residual image
    // from a previous firmware (e.g. factory test page)
    if (display_ != nullptr) {
        display_->RequestUrgentFullRefresh();
    }

    board_.SetNetworkEventCallback([this](NetworkEvent event, const std::string& data) {
        switch (event) {
            case NetworkEvent::Connecting:
                ESP_LOGI(kTag, "WiFi connecting: %s", data.c_str());
                network_state_ = NetworkState::Offline;
                status_text_ = "Wi‑Fi 连接中";
                hint_text_ = data.empty() ? "" : data;
                UpdateDisplay();
                break;
            case NetworkEvent::Connected:
                ESP_LOGI(kTag, "WiFi connected: %s", data.c_str());
                xEventGroupSetBits(wifi_event_group_, kWifiConnectedBit);
                network_state_ = NetworkState::Wifi;
                status_text_ = "Wi‑Fi 已连接";
                server_uri_.clear();
                hint_text_ = CONFIG_LAN_DISCOVERY_ENABLED ? GetDiscoveryHintText() : "连接服务器中...";
                UpdateDisplay();
                if (!cached_server_uri_.empty()) {
                    UpdateNfcAdminUri(cached_server_uri_);
                }
                break;
            case NetworkEvent::Disconnected:
                ESP_LOGW(kTag, "WiFi disconnected");
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
            case NetworkEvent::WifiConfigModeEnter:
                ESP_LOGW(kTag, "WiFi config mode: %s", data.c_str());
                network_state_ = NetworkState::Config;
                status_text_ = "Wi‑Fi 配网模式";
                hint_text_ = data;
                active_page_ = Page::Summary;
                summary_scroll_offset_ = 0;
                UpdateDisplay();
                UpdateNfcProvisionUri(data);
                break;
            case NetworkEvent::WifiConfigModeExit:
                ESP_LOGI(kTag, "WiFi config mode exited");
                network_state_ = NetworkState::Offline;
                if (SsidManager::GetInstance().GetSsidList().empty()) {
                    ESP_LOGW(kTag, "WiFi config mode exited without saved credentials; skip reboot");
                    status_text_ = "Wi‑Fi 配网模式";
                    hint_text_ = "未检测到已保存网络";
                    active_page_ = Page::Summary;
                    summary_scroll_offset_ = 0;
                    UpdateDisplay();
                    break;
                }
                RequestWifiReconfigureByReboot("重启中...", "正在应用 Wi‑Fi 配置");
                break;
            default:
                break;
        }
    });

    board_.StartNetwork();
    return true;
}

void LanMicApp::LoadPersistedNetworkState() {
    Settings nvs(kLanMicNamespace);
    volume_ = nvs.GetInt(kVolumeKey, 70);
    cached_server_uri_ = nvs.GetString(kLastServerUriKey, "");
    paired_host_id_ = nvs.GetString(kPairedHostIdKey, "");
    paired_host_name_ = nvs.GetString(kPairedHostNameKey, "");

    if (!paired_host_id_.empty()) {
        ESP_LOGI(kTag, "Loaded paired host: id=%s name=%s",
                 paired_host_id_.c_str(),
                 paired_host_name_.empty() ? "(unknown)" : paired_host_name_.c_str());
    }
    if (!cached_server_uri_.empty()) {
        ESP_LOGI(kTag, "Loaded cached server URI: %s", cached_server_uri_.c_str());
    }
    LoadCachedTodoState();
    LoadPendingTodoOps();
}

void LanMicApp::SaveCachedServerUri(const std::string& server_uri) {
    if (server_uri.empty() || server_uri == cached_server_uri_) {
        return;
    }

    Settings nvs(kLanMicNamespace, true);
    nvs.SetString(kLastServerUriKey, server_uri);
    cached_server_uri_ = server_uri;
    ESP_LOGI(kTag, "Cached server URI: %s", cached_server_uri_.c_str());
}

void LanMicApp::SavePairedHost(const std::string& host_id, const std::string& host_name) {
    if (host_id.empty()) {
        return;
    }

    const std::string next_host_name = host_name.empty() ? paired_host_name_ : host_name;
    if (host_id == paired_host_id_ && next_host_name == paired_host_name_) {
        return;
    }

    Settings nvs(kLanMicNamespace, true);
    nvs.SetString(kPairedHostIdKey, host_id);
    if (!next_host_name.empty()) {
        nvs.SetString(kPairedHostNameKey, next_host_name);
    }

    paired_host_id_ = host_id;
    paired_host_name_ = next_host_name;
    ESP_LOGI(kTag, "Paired host saved: id=%s name=%s",
             paired_host_id_.c_str(),
             paired_host_name_.empty() ? "(unknown)" : paired_host_name_.c_str());
}

void LanMicApp::ClearPersistedHost() {
    Settings nvs(kLanMicNamespace, true);
    nvs.EraseKey(kLastServerUriKey);
    nvs.EraseKey(kPairedHostIdKey);
    nvs.EraseKey(kPairedHostNameKey);

    cached_server_uri_.clear();
    paired_host_id_.clear();
    paired_host_name_.clear();
    server_uri_.clear();

    ESP_LOGI(kTag, "Cleared cached host pairing and server URI");
}

void LanMicApp::ClearCachedServerUri() {
    if (cached_server_uri_.empty()) {
        return;
    }

    Settings nvs(kLanMicNamespace, true);
    nvs.EraseKey(kLastServerUriKey);
    ESP_LOGW(kTag, "Cleared stale cached server URI: %s", cached_server_uri_.c_str());
    cached_server_uri_.clear();
}


void LanMicApp::UpdateNfcProvisionUri(const std::string& event_hint) {
    const std::string ap_url = WifiManager::GetInstance().GetApWebUrl();
    if (!ap_url.empty()) {
        WriteNfcUriIfNeeded(ap_url, "wifi_config_mode");
        return;
    }

    std::string fallback = event_hint;
    const size_t last_space = fallback.find_last_of(' ');
    if (last_space != std::string::npos && (last_space + 1) < fallback.size()) {
        const std::string maybe_url = fallback.substr(last_space + 1);
        if (maybe_url.rfind("http://", 0) == 0 || maybe_url.rfind("https://", 0) == 0) {
            fallback = maybe_url;
        }
    }

    if (fallback.rfind("http://", 0) == 0 || fallback.rfind("https://", 0) == 0) {
        WriteNfcUriIfNeeded(fallback, "wifi_config_mode_hint");
    }
}

void LanMicApp::UpdateNfcAdminUri(const std::string& ws_uri) {
    const std::string admin_url = BuildAdminUrlFromWsUri(ws_uri);
    if (admin_url.empty()) {
        return;
    }
    WriteNfcUriIfNeeded(admin_url, "server_connected");
}

void LanMicApp::WriteNfcUriIfNeeded(const std::string& uri, const char* reason) {
    if (uri.empty() || uri == nfc_last_uri_) {
        return;
    }

    if (ZectrixGetNfc == nullptr) {
        return;
    }

    ZectrixNfc* nfc = ZectrixGetNfc();
    if (nfc == nullptr) {
        return;
    }
    if (!nfc->IsPowered() && !nfc->PowerOn()) {
        ESP_LOGW(kTag, "NFC power on failed before write: reason=%s", reason != nullptr ? reason : "unknown");
        return;
    }

    const esp_err_t ret = nfc->WriteUriNdef(uri);
    if (ret != ESP_OK) {
        ESP_LOGW(kTag,
                 "NFC write uri failed: reason=%s ret=%s uri=%s",
                 reason != nullptr ? reason : "unknown",
                 esp_err_to_name(ret),
                 uri.c_str());
        return;
    }

    nfc_last_uri_ = uri;
    ESP_LOGI(kTag,
             "NFC uri updated: reason=%s uri=%s",
             reason != nullptr ? reason : "unknown",
             nfc_last_uri_.c_str());
}


std::string LanMicApp::BuildAdminUrlFromWsUri(const std::string& ws_uri) const {
    if (ws_uri.empty()) {
        return "";
    }

    const std::string ws_prefix = "ws://";
    const std::string wss_prefix = "wss://";
    bool secure = false;
    size_t authority_start = 0;
    if (ws_uri.rfind(ws_prefix, 0) == 0) {
        secure = false;
        authority_start = ws_prefix.size();
    } else if (ws_uri.rfind(wss_prefix, 0) == 0) {
        secure = true;
        authority_start = wss_prefix.size();
    } else {
        return "";
    }

    size_t authority_end = ws_uri.find('/', authority_start);
    if (authority_end == std::string::npos) {
        authority_end = ws_uri.size();
    }
    if (authority_end <= authority_start) {
        return "";
    }

    const std::string authority = ws_uri.substr(authority_start, authority_end - authority_start);
    return std::string(secure ? "https://" : "http://") + authority + "/admin";
}


void LanMicApp::RequestWifiReconfigureByReboot(const char* status_text, const char* hint_text) {
    bool expected = false;
    if (!wifi_reconfigure_restart_pending_.compare_exchange_strong(expected,
                                                                   true,
                                                                   std::memory_order_acq_rel,
                                                                   std::memory_order_acquire)) {
        return;
    }

    ESP_LOGI(kTag, "Request reconfigure WiFi by reboot");
    connect_cancel_requested_.store(true, std::memory_order_release);
    ws_disconnected_pending_.store(false, std::memory_order_release);
    hello_sent_ = false;

    status_text_ = status_text != nullptr ? status_text : "重启中...";
    hint_text_ = hint_text != nullptr ? hint_text : "正在重新配置 Wi‑Fi";
    active_page_ = Page::Summary;
    summary_scroll_offset_ = 0;
    UpdateDisplay();

    if (xTaskCreate([](void* arg) {
            auto* self = static_cast<LanMicApp*>(arg);
            vTaskDelay(pdMS_TO_TICKS(600));
            esp_restart();
            self->wifi_reconfigure_restart_pending_.store(false, std::memory_order_release);
            vTaskDelete(nullptr);
        },
        "wifi_reboot",
        3072,
        this,
        5,
        nullptr) != pdPASS) {
        wifi_reconfigure_restart_pending_.store(false, std::memory_order_release);
        vTaskDelay(pdMS_TO_TICKS(200));
        esp_restart();
    }
}

void LanMicApp::ConfigureButtons() {
    gpio_config_t cfg = {};
    cfg.pin_bit_mask = 1ULL << BOOT_BUTTON_GPIO;
    cfg.mode = GPIO_MODE_INPUT;
    cfg.pull_up_en = GPIO_PULLUP_ENABLE;
    cfg.pull_down_en = GPIO_PULLDOWN_DISABLE;
    cfg.intr_type = GPIO_INTR_DISABLE;
    ESP_ERROR_CHECK(gpio_config(&cfg));

    up_button_.OnClick([this]() {
        ESP_LOGI(kTag, "UP click");
        up_clicked_.store(true);
    });
    down_button_.OnClick([this]() {
        ESP_LOGI(kTag, "DOWN click");
        down_clicked_.store(true);
    });
    up_button_.OnLongPress([this]() {
        ESP_LOGI(kTag, "UP long press");
        up_long_pressed_.store(true);
    });
    down_button_.OnLongPress([this]() {
        ESP_LOGI(kTag, "DOWN long press");
        down_long_pressed_.store(true);
    });
    up_button_.OnDoubleClick([this]() {
        ESP_LOGI(kTag, "UP double click");
        up_double_clicked_.store(true);
    });
    down_button_.OnDoubleClick([this]() {
        ESP_LOGI(kTag, "DOWN double click");
        down_double_clicked_.store(true);
    });
}

bool LanMicApp::IsWifiConnected() const {
    return (xEventGroupGetBits(wifi_event_group_) & kWifiConnectedBit) != 0;
}

bool LanMicApp::IsServerConnected() const {
    return ws_ != nullptr && ws_->IsConnected();
}

void LanMicApp::StartConnectAttemptAsync() {
    if (IsServerConnected()) {
        return;
    }

    bool expected = false;
    if (!connect_attempt_running_.compare_exchange_strong(expected, true,
                                                          std::memory_order_acq_rel,
                                                          std::memory_order_acquire)) {
        return;
    }

    connect_attempt_completed_.store(false, std::memory_order_release);
    connect_cancel_requested_.store(false, std::memory_order_release);
    connect_attempt_started_ms_.store(esp_timer_get_time() / 1000, std::memory_order_release);
    reconnect_stuck_prompt_ = false;

    if (xTaskCreate([](void* arg) {
            auto* self = static_cast<LanMicApp*>(arg);
            self->RunConnectAttemptTask();
            self->connect_task_handle_ = nullptr;
            self->connect_attempt_started_ms_.store(0, std::memory_order_release);
            self->connect_attempt_running_.store(false, std::memory_order_release);
            self->connect_attempt_completed_.store(true, std::memory_order_release);
            vTaskDelete(nullptr);
        },
        "lan_reconnect",
        kConnectTaskStackSize,
        this,
        kConnectTaskPriority,
        &connect_task_handle_) != pdPASS) {
        connect_task_handle_ = nullptr;
        connect_attempt_started_ms_.store(0, std::memory_order_release);
        connect_attempt_running_.store(false, std::memory_order_release);
        connect_attempt_completed_.store(true, std::memory_order_release);
        status_text_ = "重连失败";
        hint_text_ = "创建任务失败";
        UpdateDisplay();
    }
}

void LanMicApp::RunConnectAttemptTask() {
    EnsureWebSocketConnected();
    if (connect_cancel_requested_.exchange(false, std::memory_order_acq_rel) && !IsServerConnected()) {
        ws_.reset();
        hello_sent_ = false;
    }
}

bool LanMicApp::EnsureWebSocketConnected() {
    if (IsServerConnected()) {
        return true;
    }

    const bool manual_reconnect = manual_reconnect_requested_.exchange(false, std::memory_order_acq_rel);
    if (manual_reconnect) {
        server_uri_.clear();
    }

    const char* target_uri = nullptr;
    const char* target_source = "none";
    std::string fallback_server_uri;
#if CONFIG_LAN_DISCOVERY_ENABLED
    if (!server_uri_.empty()) {
        target_uri = server_uri_.c_str();
        target_source = "discovery";
    } else {
        DiscoverServerUri();
        if (!server_uri_.empty()) {
            target_uri = server_uri_.c_str();
            target_source = "discovery";
        } else if (!cached_server_uri_.empty() && !manual_reconnect) {
            target_uri = cached_server_uri_.c_str();
            target_source = "cache";
        }
    }
#else
    if (!server_uri_.empty()) {
        target_uri = server_uri_.c_str();
        target_source = "configured";
    } else if (!cached_server_uri_.empty() && !manual_reconnect) {
        target_uri = cached_server_uri_.c_str();
        target_source = "cache";
    }
#endif

    if (target_uri == nullptr) {
        fallback_server_uri = GetFallbackServerUri();
        if (!fallback_server_uri.empty()) {
            target_uri = fallback_server_uri.c_str();
            target_source = "fallback";
        }
    }

    if (target_uri == nullptr) {
        status_text_ = "正在查找主机";
        hint_text_ = GetDiscoveryHintText();
        UpdateDisplay();
        return false;
    }

    NetworkInterface* network = board_.GetNetwork();
    if (network == nullptr) {
        ESP_LOGE(kTag, "Network interface is null");
        return false;
    }

    const std::string target_uri_text = target_uri;
    ESP_LOGI(kTag, "Connecting via %s: %s", target_source, target_uri_text.c_str());

    ws_ = network->CreateWebSocket(0);
    ws_->OnConnected([this, target_uri_text]() {
        ESP_LOGI(kTag, "WebSocket connected");
        board_.SetPowerSaveLevel(PowerSaveLevel::BALANCED);
        SaveCachedServerUri(target_uri_text);
        UpdateNfcAdminUri(target_uri_text);
        network_state_ = NetworkState::Server;
        status_text_ = "已连接";
        hint_text_ = "";  // BuildPromptBody() will show default hold-to-talk hint
        phase_ = Phase::Idle;
        ShowIdleTodoPage();
        UpdateDisplay();
        if (display_ != nullptr) {
            display_->RequestUrgentFullRefresh();
        }
    });
    ws_->OnDisconnected([this]() {
        ESP_LOGW(kTag, "WebSocket disconnected");
        ws_disconnected_pending_.store(true);
    });
    ws_->OnError([this](int error) {
        ESP_LOGW(kTag, "WebSocket error=%d", error);
        network_state_ = IsWifiConnected() ? NetworkState::Wifi : NetworkState::Offline;
        status_text_ = "服务器错误";
        hint_text_ = "将自动重试";
        phase_ = Phase::Error;
        active_page_ = Page::Summary;
        UpdateDisplay();
    });
    ws_->OnData([this](const char* data, size_t len, bool binary) {
        if (!binary && data != nullptr && len > 0) {
            HandleServerMessage(data, len);
        }
    });

    if (!ws_->Connect(target_uri)) {
        ESP_LOGW(kTag, "WebSocket connect failed: %s", target_uri);
        ws_.reset();
        hello_sent_ = false;
        if (std::strcmp(target_source, "discovery") == 0) {
            ESP_LOGW(kTag, "Discovered URI failed, forcing discovery next round");
            server_uri_.clear();
        } else if (std::strcmp(target_source, "cache") == 0) {
            ESP_LOGW(kTag, "Cache connect failed; clearing stale cache and forcing discovery");
            ClearCachedServerUri();
        }
        status_text_ = "连接失败";
        hint_text_ = target_uri;
        UpdateDisplay();
        return false;
    }

    hello_sent_ = false;
    return SendHello();
}

bool LanMicApp::DiscoverServerUri() {
#if !CONFIG_LAN_DISCOVERY_ENABLED
    return false;
#else
    if (!IsWifiConnected()) {
        return false;
    }

    if (!server_uri_.empty()) {
        return true;
    }

    auto discover_with_host_filter = [this](const std::string& requested_host_id) -> bool {
        cJSON* request = cJSON_CreateObject();
        const std::string nonce = MakeAuthNonce();
        cJSON_AddStringToObject(request, "type", "discover_host");
        cJSON_AddStringToObject(request, "service", kDiscoveryService);
        cJSON_AddStringToObject(request, "deviceId", board_.GetUuid().c_str());
        cJSON_AddStringToObject(request, "boardType", board_.GetBoardType().c_str());
        cJSON_AddStringToObject(request, "nonce", nonce.c_str());
        if (!requested_host_id.empty()) {
            cJSON_AddStringToObject(request, "expectedHostId", requested_host_id.c_str());
        }

        char* request_text = cJSON_PrintUnformatted(request);
        cJSON_Delete(request);
        if (request_text == nullptr) {
            return false;
        }

        for (int attempt = 0; attempt < kDiscoveryAttempts; ++attempt) {
            int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
            if (sock < 0) {
                ESP_LOGW(kTag, "Discovery socket create failed: errno=%d", errno);
                break;
            }

            int broadcast = 1;
            setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, sizeof(broadcast));
            struct sockaddr_in local_addr = {};
            local_addr.sin_family = AF_INET;
            local_addr.sin_port = htons(0);
            local_addr.sin_addr.s_addr = htonl(INADDR_ANY);
            if (bind(sock,
                     reinterpret_cast<struct sockaddr*>(&local_addr),
                     sizeof(local_addr)) < 0) {
                ESP_LOGW(kTag, "Discovery bind failed: errno=%d", errno);
                close(sock);
                continue;
            }

            struct sockaddr_in broadcast_addr = {};
            broadcast_addr.sin_family = AF_INET;
            broadcast_addr.sin_port = htons(CONFIG_LAN_DISCOVERY_PORT);
            broadcast_addr.sin_addr.s_addr = inet_addr("255.255.255.255");

            ESP_LOGI(kTag,
                     "Discovery attempt %d/%d%s",
                     attempt + 1,
                     kDiscoveryAttempts,
                     requested_host_id.empty() ? "" : " (paired host filter)");
            const int sent = sendto(sock,
                                    request_text,
                                    std::strlen(request_text),
                                    0,
                                    reinterpret_cast<struct sockaddr*>(&broadcast_addr),
                                    sizeof(broadcast_addr));
            if (sent < 0) {
                ESP_LOGW(kTag, "Discovery broadcast failed: errno=%d", errno);
                close(sock);
                continue;
            }

            const int64_t deadline_us = esp_timer_get_time() + (kDiscoveryTimeoutMs * 1000LL);
            while (esp_timer_get_time() < deadline_us) {
                const int64_t remaining_us = deadline_us - esp_timer_get_time();
                if (remaining_us <= 0) {
                    break;
                }

                struct timeval timeout = {};
                timeout.tv_sec = remaining_us / 1000000;
                timeout.tv_usec = remaining_us % 1000000;
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

                char response_buffer[512];
                struct sockaddr_in source_addr = {};
                socklen_t source_addr_len = sizeof(source_addr);
                const int received = recvfrom(sock,
                                              response_buffer,
                                              sizeof(response_buffer) - 1,
                                              0,
                                              reinterpret_cast<struct sockaddr*>(&source_addr),
                                              &source_addr_len);
                if (received <= 0) {
                    continue;
                }

                response_buffer[received] = '\0';
                cJSON* response = cJSON_Parse(response_buffer);
                if (response == nullptr) {
                    continue;
                }

                const char* type = GetJsonString(response, "type");
                const char* service = GetJsonString(response, "service");
                const char* ws_url = GetJsonString(response, "wsUrl");
                const char* host_id = GetJsonString(response, "hostId");
                const char* host_name = GetJsonString(response, "hostName");
                const char* reply_nonce = GetJsonString(response, "nonce");
                const char* auth_sig = GetJsonString(response, "authSig");

                const bool type_ok = type != nullptr && strcmp(type, "discover_reply") == 0;
                const bool service_ok = service == nullptr || strcmp(service, kDiscoveryService) == 0;
                const bool host_ok = requested_host_id.empty() ||
                                     (host_id != nullptr && requested_host_id == host_id);
                bool auth_ok = true;
                if (std::strlen(CONFIG_LAN_SHARED_SECRET) > 0) {
                    if (reply_nonce == nullptr || auth_sig == nullptr || nonce != reply_nonce) {
                        auth_ok = false;
                    } else {
                        const auto expected = HmacSha256Hex({
                            "discover_reply",
                            host_id != nullptr ? host_id : "",
                            host_name != nullptr ? host_name : "",
                            ws_url != nullptr ? ws_url : "",
                            reply_nonce
                        });
                        auth_ok = !expected.empty() && expected == std::string(auth_sig);
                    }
                }

                if (type_ok && service_ok && host_ok && auth_ok && ws_url != nullptr && ws_url[0] != '\0') {
                    server_uri_ = ws_url;
                    SaveCachedServerUri(server_uri_);
                    SavePairedHost(host_id != nullptr ? host_id : "",
                                   host_name != nullptr ? host_name : "");
                    status_text_ = "发现主机";
                    hint_text_ = (host_name != nullptr && host_name[0] != '\0') ? host_name : server_uri_;
                    ESP_LOGI(kTag, "Discovered host: %s (%s)", server_uri_.c_str(), hint_text_.c_str());
                    cJSON_Delete(response);
                    close(sock);
                    cJSON_free(request_text);
                    return true;
                }

                if (type_ok && service_ok && ws_url != nullptr && ws_url[0] != '\0' && !host_ok) {
                    ESP_LOGW(kTag,
                             "Discovery reply ignored by host filter: expected=%s got=%s",
                             requested_host_id.c_str(),
                             host_id != nullptr ? host_id : "(none)");
                } else if (type_ok && service_ok && host_ok && !auth_ok) {
                    ESP_LOGW(kTag, "Discovery reply auth failed for host=%s", host_id != nullptr ? host_id : "(none)");
                }

                cJSON_Delete(response);
            }

            close(sock);
            if (attempt + 1 < kDiscoveryAttempts) {
                vTaskDelay(pdMS_TO_TICKS(kDiscoveryRetryDelayMs));
            }
        }

        cJSON_free(request_text);
        return false;
    };

    const std::string expected_host_id = GetExpectedDiscoveryHostId();
    if (discover_with_host_filter(expected_host_id)) {
        return true;
    }

    if (!expected_host_id.empty()) {
        ESP_LOGW(kTag,
                 "Discovery with paired host id failed (%s), retrying without host filter",
                 expected_host_id.c_str());
        if (discover_with_host_filter("")) {
            return true;
        }
    }

    return false;
#endif
}

std::string LanMicApp::MakeAuthNonce() const {
    uint8_t bytes[8] = {0};
    esp_fill_random(bytes, sizeof(bytes));
    char buffer[sizeof(bytes) * 2 + 1];
    for (size_t index = 0; index < sizeof(bytes); ++index) {
        snprintf(buffer + (index * 2), sizeof(buffer) - (index * 2), "%02x", bytes[index]);
    }
    buffer[sizeof(buffer) - 1] = '\0';
    return std::string(buffer);
}

std::string LanMicApp::HmacSha256Hex(const std::vector<std::string>& parts) const {
    if (std::strlen(CONFIG_LAN_SHARED_SECRET) == 0) {
        return "";
    }

    std::string payload;
    for (size_t index = 0; index < parts.size(); ++index) {
        if (index > 0) {
            payload.push_back('|');
        }
        payload += parts[index];
    }

    const mbedtls_md_info_t* md_info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (md_info == nullptr) {
        return "";
    }

    unsigned char digest[32] = {0};
    const int ret = mbedtls_md_hmac(
        md_info,
        reinterpret_cast<const unsigned char*>(CONFIG_LAN_SHARED_SECRET),
        std::strlen(CONFIG_LAN_SHARED_SECRET),
        reinterpret_cast<const unsigned char*>(payload.data()),
        payload.size(),
        digest);
    if (ret != 0) {
        ESP_LOGW(kTag, "HMAC failed: %d", ret);
        return "";
    }

    char hex[65];
    for (size_t index = 0; index < sizeof(digest); ++index) {
        snprintf(hex + (index * 2), sizeof(hex) - (index * 2), "%02x", digest[index]);
    }
    hex[64] = '\0';
    return std::string(hex);
}

std::string LanMicApp::GetExpectedDiscoveryHostId() const {
    if (std::strlen(CONFIG_LAN_DISCOVERY_HOST_ID) > 0) {
        return CONFIG_LAN_DISCOVERY_HOST_ID;
    }
    return paired_host_id_;
}

std::string LanMicApp::GetFallbackServerUri() const {
    if (std::strlen(CONFIG_LAN_MIC_SERVER_URI) == 0) {
        return "";
    }
    return CONFIG_LAN_MIC_SERVER_URI;
}

std::string LanMicApp::GetDiscoveryHintText() const {
    if (!paired_host_name_.empty()) {
        return "正在查找 " + paired_host_name_ + "...";
    }
    if (!paired_host_id_.empty()) {
        return "正在查找已配对主机...";
    }
    return "正在发现主机...";
}

void LanMicApp::EnterWifiSetupMode() {
    ESP_LOGW(kTag, "Clearing saved Wi-Fi and scheduling reboot into config mode");
    ClearPersistedHost();
    DisconnectWebSocket();
    xEventGroupClearBits(wifi_event_group_, kWifiConnectedBit);
    up_long_pressed_.store(false);
    down_long_pressed_.store(false);
    has_pending_transcript_ = false;
    phase_ = Phase::Idle;
    network_state_ = NetworkState::Config;
    active_page_ = Page::Summary;
    summary_scroll_offset_ = 0;
    status_text_ = "Wi‑Fi 配网";
    hint_text_ = "正在启动配网热点...";
    UpdateDisplay();

    SsidManager::GetInstance().Clear();
    RequestWifiReconfigureByReboot("重启中...", "重启进入 Wi‑Fi 配网");
}

void LanMicApp::DisconnectWebSocket() {
    if (connect_attempt_running_.load(std::memory_order_acquire) && !IsServerConnected()) {
        connect_cancel_requested_.store(true, std::memory_order_release);
    } else if (ws_ != nullptr) {
        ws_.reset();
    }
    hello_sent_ = false;
    preroll_frames_.clear();
}

bool LanMicApp::IsPttPressed() const {
    return gpio_get_level(BOOT_BUTTON_GPIO) == 0;
}

bool LanMicApp::IsNavButtonPressed(gpio_num_t gpio_num) const {
    return gpio_get_level(gpio_num) == 0;
}

bool LanMicApp::SendJson(const char* json) {
    if (ws_ == nullptr || !ws_->IsConnected()) {
        return false;
    }
    if (!ws_->Send(json)) {
        ESP_LOGW(kTag, "Failed to send json: %s", json);
        DisconnectWebSocket();
        return false;
    }
    return true;
}

bool LanMicApp::SendHello() {
    if (hello_sent_) {
        return true;
    }

    const int64_t auth_ts = esp_timer_get_time() / 1000;
    const std::string auth_nonce = MakeAuthNonce();
    const std::string auth_sig = HmacSha256Hex({
        "hello",
        board_.GetUuid(),
        board_.GetBoardType(),
        std::to_string(auth_ts),
        auth_nonce
    });

    char message[512];
    if (!auth_sig.empty()) {
        snprintf(message,
                 sizeof(message),
                 "{\"type\":\"hello\",\"deviceId\":\"%s\",\"boardType\":\"%s\",\"authTs\":%lld,\"authNonce\":\"%s\",\"authSig\":\"%s\"}",
                 board_.GetUuid().c_str(),
                 board_.GetBoardType().c_str(),
                 static_cast<long long>(auth_ts),
                 auth_nonce.c_str(),
                 auth_sig.c_str());
    } else {
        snprintf(message,
                 sizeof(message),
                 "{\"type\":\"hello\",\"deviceId\":\"%s\",\"boardType\":\"%s\"}",
                 board_.GetUuid().c_str(),
                 board_.GetBoardType().c_str());
    }
    hello_sent_ = SendJson(message);
    return hello_sent_;
}

bool LanMicApp::SendPttStart() {
    char message[128];
    snprintf(message,
             sizeof(message),
             "{\"type\":\"ptt_start\",\"ts\":%lld}",
             static_cast<long long>(esp_timer_get_time() / 1000));
    return SendJson(message);
}

bool LanMicApp::SendPttStop() {
    char message[128];
    snprintf(message,
             sizeof(message),
             "{\"type\":\"ptt_stop\",\"ts\":%lld}",
             static_cast<long long>(esp_timer_get_time() / 1000));
    return SendJson(message);
}

bool LanMicApp::SendEnter() {
    char message[128];
    snprintf(message,
             sizeof(message),
             "{\"type\":\"action_enter\",\"ts\":%lld}",
             static_cast<long long>(esp_timer_get_time() / 1000));
    return SendJson(message);
}

bool LanMicApp::SendAction(const char* action_type) {
    char message[128];
    snprintf(message,
             sizeof(message),
             "{\"type\":\"%s\",\"ts\":%lld}",
             action_type,
             static_cast<long long>(esp_timer_get_time() / 1000));
    return SendJson(message);
}

bool LanMicApp::SendSetMode(const char* mode) {
    char message[128];
    snprintf(message,
             sizeof(message),
             "{\"type\":\"set_mode\",\"mode\":\"%s\"}",
             mode);
    return SendJson(message);
}

bool LanMicApp::SendTodoCommand(const char* action, int index, int completed, const char* id) {
    char message[384];
    char id_part[96] = "";
    if (id != nullptr && id[0] != '\0') {
        snprintf(id_part, sizeof(id_part), ",\"id\":\"%s\"", id);
    }
    if (index > 0 && completed >= 0) {
        snprintf(message,
                 sizeof(message),
                 "{\"type\":\"todo_command\",\"action\":\"%s\",\"index\":%d,\"completed\":%s%s}",
                 action,
                 index,
                 completed ? "true" : "false",
                 id_part);
    } else if (index > 0) {
        snprintf(message,
                 sizeof(message),
                 "{\"type\":\"todo_command\",\"action\":\"%s\",\"index\":%d%s}",
                 action,
                 index,
                 id_part);
    } else if (completed >= 0) {
        snprintf(message,
                 sizeof(message),
                 "{\"type\":\"todo_command\",\"action\":\"%s\",\"completed\":%s%s}",
                 action,
                 completed ? "true" : "false",
                 id_part);
    } else {
        snprintf(message,
                 sizeof(message),
                 "{\"type\":\"todo_command\",\"action\":\"%s\"%s}",
                 action,
                 id_part);
    }
    return SendJson(message);
}

bool LanMicApp::SendPlanSelect(int direction) {
    if (direction == 0) {
        return false;
    }
    const char* move = direction < 0 ? "prev" : "next";
    char message[128];
    snprintf(message,
             sizeof(message),
             "{\"type\":\"plan_select\",\"direction\":\"%s\"}",
             move);
    return SendJson(message);
}

bool LanMicApp::SendPlanApply() {
    return SendJson("{\"type\":\"plan_apply\"}");
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
    if (ws_ == nullptr || !ws_->IsConnected()) {
        return false;
    }

    if (!codec_->InputData(audio_frame_buffer_)) {
        return false;
    }

    if (!ws_->Send(audio_frame_buffer_.data(), audio_frame_buffer_.size() * sizeof(int16_t), true)) {
        ESP_LOGW(kTag, "Failed to send audio frame");
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
    if (ws_ == nullptr || !ws_->IsConnected()) {
        preroll_frames_.clear();
        return false;
    }

    while (!preroll_frames_.empty()) {
        auto& frame = preroll_frames_.front();
        if (!ws_->Send(frame.data(), frame.size() * sizeof(int16_t), true)) {
            ESP_LOGW(kTag, "Failed to send preroll frame");
            preroll_frames_.clear();
            DisconnectWebSocket();
            return false;
        }
        preroll_frames_.pop_front();
    }

    return true;
}

void LanMicApp::HandleServerMessage(const char* data, size_t len) {
    std::string text(data, len);
    ESP_LOGI(kTag, "Server: %s", text.c_str());

    cJSON* root = cJSON_ParseWithLength(data, len);
    if (root == nullptr) {
        ESP_LOGW(kTag, "Failed to parse server json");
        return;
    }

    const char* type = GetJsonString(root, "type");
    if (type == nullptr) {
        cJSON_Delete(root);
        return;
    }

    if (strcmp(type, "hello_ack") == 0) {
        status_text_ = "就绪";
        offline_todo_mode_ = false;
        reconnect_stuck_prompt_ = false;
        todo_menu_open_ = false;
        if (!has_pending_transcript_) {
            phase_ = Phase::Idle;
        }
        // 连上服务器：上升双音
        PlayBeep(600, 80);
        PlayBeep(900, 100);
    } else if (strcmp(type, "server_ready") == 0) {
        status_text_ = "就绪";
        offline_todo_mode_ = false;
        reconnect_stuck_prompt_ = false;
        todo_menu_open_ = false;
        if (!has_pending_transcript_) {
            phase_ = Phase::Idle;
        }
        const char* send_target = GetJsonString(root, "sendTarget");
        if (send_target != nullptr) {
            send_target_ = send_target;
            cli_status_text_ = std::string(GetToolLabel()) + " 空闲";
            if (repo_name_ == "AI") {
                repo_name_ = GetToolLabel();
            }
        }
        const char* mode = GetJsonString(root, "mode");
        if (mode != nullptr) {
            voice_mode_ = strcmp(mode, "todo") == 0 ? VoiceMode::Todo : VoiceMode::Normal;
        }
        if (pending_normal_after_reconnect_) {
            pending_normal_after_reconnect_ = false;
            active_page_ = Page::Summary;
        }
        SyncVoiceModeToActivePage();
    } else if (strcmp(type, "display_config") == 0) {
        cJSON* todo_refresh_ms = cJSON_GetObjectItemCaseSensitive(root, "todoRefreshMs");
        cJSON* coding_refresh_ms = cJSON_GetObjectItemCaseSensitive(root, "codingRefreshMs");
        const char* style = GetJsonString(root, "style");

        if (cJSON_IsNumber(todo_refresh_ms)) {
            display_todo_refresh_ms_ = std::clamp(todo_refresh_ms->valueint, 200, 10000);
        }
        if (cJSON_IsNumber(coding_refresh_ms)) {
            display_coding_refresh_ms_ = std::clamp(coding_refresh_ms->valueint, 200, 10000);
        }
        if (style != nullptr) {
            display_dark_style_ = std::strcmp(style, "dark") == 0;
        }

        if (display_ != nullptr) {
            const int interval = active_page_ == Page::Todo ? display_todo_refresh_ms_ : display_coding_refresh_ms_;
            display_->SetSampleIntervalMs(interval);
            display_->SetInverted(display_dark_style_);
        }
    } else if (strcmp(type, "mode_state") == 0) {

        cJSON* items = cJSON_GetObjectItemCaseSensitive(root, "items");
        cJSON* selected_index = cJSON_GetObjectItemCaseSensitive(root, "selectedIndex");
        const char* last_action = GetJsonString(root, "lastActionText");
        todo_items_.clear();
        if (cJSON_IsArray(items)) {
            cJSON* item = nullptr;
            cJSON_ArrayForEach(item, items) {
                const char* id = GetJsonString(item, "id");
                const char* title = GetJsonString(item, "title");
                if (title == nullptr) {
                    continue;
                }
                todo_items_.push_back({
                    id != nullptr ? id : "",
                    title,
                    GetJsonBool(item, "completed", false),
                    GetJsonString(item, "dueAt") != nullptr ? GetJsonString(item, "dueAt") : ""
                });
            }
        }
        if (cJSON_IsNumber(selected_index)) {
            todo_selected_index_ = selected_index->valueint;
        } else {
            todo_selected_index_ = todo_items_.empty() ? -1 : 0;
        }
        if (todo_items_.empty()) {
            todo_selected_index_ = -1;
        } else {
            todo_selected_index_ = std::clamp(
                todo_selected_index_,
                0,
                static_cast<int>(todo_items_.size()) - 1);
        }
        if (last_action != nullptr) {
            todo_last_action_text_ = last_action;
        }
        SaveCachedTodoState();
        offline_todo_mode_ = false;
        reconnect_stuck_prompt_ = false;
        FlushPendingTodoOps();
    } else if (strcmp(type, "todo_result") == 0) {
        const char* message = GetJsonString(root, "message");
        const bool ok = GetJsonBool(root, "ok", false);
        phase_ = Phase::Idle;
        status_text_ = ok ? "待办" : "待办错误";
        hint_text_ = message != nullptr ? message : "";
        if (message != nullptr) {
            todo_last_action_text_ = message;
        }
        active_page_ = Page::Todo;
    } else if (strcmp(type, "plan_options") == 0) {
        cJSON* options = cJSON_GetObjectItemCaseSensitive(root, "options");
        cJSON* selected_index = cJSON_GetObjectItemCaseSensitive(root, "selectedIndex");
        plan_options_.clear();
        if (cJSON_IsArray(options)) {
            cJSON* item = nullptr;
            cJSON_ArrayForEach(item, options) {
                if (cJSON_IsString(item) && item->valuestring != nullptr) {
                    plan_options_.push_back(item->valuestring);
                }
            }
        }

        if (plan_options_.empty()) {
            plan_selected_index_ = -1;
        } else if (cJSON_IsNumber(selected_index)) {
            plan_selected_index_ = std::clamp(selected_index->valueint, 0, static_cast<int>(plan_options_.size()) - 1);
        } else {
            plan_selected_index_ = std::clamp(plan_selected_index_, 0, static_cast<int>(plan_options_.size()) - 1);
        }

        if (!plan_options_.empty()) {
            active_page_ = Page::Summary;
            phase_ = Phase::Idle;
            status_text_ = "方案已就绪";
            hint_text_ = "上下键选择 BOOT 应用";
            summary_scroll_offset_ = std::max(0, plan_selected_index_ - 1);
        }
    } else if (strcmp(type, "status") == 0) {
        const char* status = GetJsonString(root, "status");
        const char* text_value = GetJsonString(root, "text");
        if (status != nullptr) {
            if (strcmp(status, "recording") == 0) {
                phase_ = Phase::Recording;
                status_text_ = "录音中";
                active_page_ = PageForCurrentVoiceMode();
            } else if (strcmp(status, "transcribing") == 0) {
                phase_ = Phase::Transcribing;
                status_text_ = "转写中";
                active_page_ = PageForCurrentVoiceMode();
                PlayBeep(660, 80);   // 停止录音/转录中：短低音
            } else if (strcmp(status, "awaiting_action") == 0) {
                phase_ = Phase::AwaitingAction;
                status_text_ = "待发送";
                has_pending_transcript_ = true;
                active_page_ = Page::Summary;
                summary_scroll_offset_ = 0;
            } else if (strcmp(status, "typed") == 0) {
                const bool text_injector = send_target_ == "text_injector";
                phase_ = text_injector ? Phase::Idle : Phase::Running;
                status_text_ = text_injector ? "已注入" : "已发送";
                has_pending_transcript_ = false;
                active_page_ = Page::Summary;
            } else if (strcmp(status, "undo_ok") == 0) {
                phase_ = Phase::Idle;
                status_text_ = "已取消";
                has_pending_transcript_ = false;
                ShowIdleTodoPage();
            } else if (strcmp(status, "transcript_empty") == 0 || strcmp(status, "empty_segment") == 0) {
                if (text_value != nullptr && text_value[0] != '\0') {
                    phase_ = Phase::AwaitingAction;
                    status_text_ = "未追加语音";
                    has_pending_transcript_ = true;
                    transcript_text_ = text_value;
                    active_page_ = Page::Summary;
                } else {
                    phase_ = Phase::Idle;
                    status_text_ = "未检测到语音";
                    hint_text_ = "请重试";
                    has_pending_transcript_ = false;
                    transcript_text_.clear();
                    ShowIdleTodoPage();
                }
            } else if (strcmp(status, "no_pending") == 0) {
                phase_ = Phase::Idle;
                status_text_ = "无待处理内容";
                ShowIdleTodoPage();
            } else if (strcmp(status, "cli_busy") == 0) {
                phase_ = Phase::Running;
                status_text_ = std::string(GetToolLabel()) + " 忙碌";
                active_page_ = Page::Summary;
            } else {
                status_text_ = status;
            }
        }
        if (text_value != nullptr) {
            transcript_text_ = text_value;
        }
    } else if (strcmp(type, "transcript_final") == 0) {
        const char* text_value = GetJsonString(root, "text");
        if (text_value != nullptr) {
            transcript_text_ = text_value;
        }
        has_pending_transcript_ = GetJsonBool(root, "requiresAction", false);
        phase_ = has_pending_transcript_ ? Phase::AwaitingAction : Phase::Idle;
        if (has_pending_transcript_) {
            status_text_ = "待发送";
        } else {
            status_text_ = voice_mode_ == VoiceMode::Todo ? "待办输入" : "转写已就绪";
        }
        active_page_ = PageForCurrentVoiceMode();
        summary_scroll_offset_ = 0;
    } else if (strcmp(type, "transcript_cleared") == 0) {
        transcript_text_.clear();
        has_pending_transcript_ = false;
        phase_ = Phase::Idle;
        status_text_ = "已清除";
        ShowIdleTodoPage();
    } else if (strcmp(type, "cli_session_state") == 0) {
        const char* phase = GetJsonString(root, "phase");
        const char* status_line = GetJsonString(root, "statusLine");
        const char* repo_name = GetJsonString(root, "repoName");
        cJSON* quota_5h = cJSON_GetObjectItemCaseSensitive(root, "quota5hRemainingPct");
        cJSON* quota_week = cJSON_GetObjectItemCaseSensitive(root, "quotaWeekRemainingPct");
        if (phase != nullptr) {
            const bool was_running = (phase_ == Phase::Running);
            const bool recording_or_transcribing =
                (phase_ == Phase::Recording) || (phase_ == Phase::Transcribing);
            cli_phase_text_ = phase;
            if (strcmp(phase, "running") == 0) {
                if (!recording_or_transcribing) {
                    phase_ = Phase::Running;
                    active_page_ = PageForCurrentVoiceMode();
                }
            } else if (strcmp(phase, "error") == 0) {
                if (!recording_or_transcribing) {
                    phase_ = Phase::Error;
                    active_page_ = PageForCurrentVoiceMode();
                    PlayBeep(300, 300);  // 出错：低沉长音
                }
            } else if (!has_pending_transcript_ && !recording_or_transcribing) {
                phase_ = Phase::Idle;
                ShowIdleTodoPage();
                if (was_running) {
                    // AI 回复完成：上升双音
                    PlayBeep(800, 80);
                    PlayBeep(1000, 100);
                }
            }
        }
        if (status_line != nullptr) {
            cli_status_text_ = status_line;
        } else if (phase != nullptr) {
            cli_status_text_ = phase;
        }
        if (repo_name != nullptr) {
            repo_name_ = repo_name;
        }
        if (cJSON_IsNumber(quota_5h)) {
            quota_5h_remaining_pct_ = quota_5h->valueint;
        }
        if (cJSON_IsNumber(quota_week)) {
            quota_week_remaining_pct_ = quota_week->valueint;
        }
    } else if (strcmp(type, "cli_summary") == 0) {
        const char* latest_assistant = GetJsonString(root, "latestAssistantText");
        const char* status_line = GetJsonString(root, "statusLine");
        const char* repo_name = GetJsonString(root, "repoName");
        if (latest_assistant != nullptr) {
            latest_assistant_text_ = latest_assistant;
            summary_scroll_offset_ = 0;
        }
        if (status_line != nullptr) {
            cli_status_text_ = status_line;
        }
        if (repo_name != nullptr) {
            repo_name_ = repo_name;
        }
        if (phase_ == Phase::Running) {
            active_page_ = PageForCurrentVoiceMode();
        }
    } else if (strcmp(type, "cli_log_tail") == 0) {
        cJSON* lines = cJSON_GetObjectItemCaseSensitive(root, "lines");
        if (cJSON_IsArray(lines)) {
            cli_log_lines_.clear();
            cJSON* line = nullptr;
            cJSON_ArrayForEach(line, lines) {
                if (cJSON_IsString(line) && line->valuestring != nullptr) {
                    cli_log_lines_.push_back(line->valuestring);
                }
            }
            std::vector<std::string> wrapped;
            for (const auto& item : cli_log_lines_) {
                const auto item_lines = WrapText(item, kBodyCharsPerLine);
                wrapped.insert(wrapped.end(), item_lines.begin(), item_lines.end());
            }
            log_scroll_offset_ = std::max(0, static_cast<int>(wrapped.size()) - static_cast<int>(kLogVisibleLines));
        }
    } else if (strcmp(type, "error") == 0) {
        const char* error = GetJsonString(root, "error");
        phase_ = Phase::Error;
        status_text_ = "错误";
        hint_text_ = (error != nullptr) ? error : "未知错误";
    } else if (strcmp(type, "warning") == 0) {
        const char* warning = GetJsonString(root, "warning");
        status_text_ = "警告";
        hint_text_ = (warning != nullptr) ? warning : "";
    }

    cJSON_Delete(root);
    UpdateDisplay();
}

void LanMicApp::RefreshBatteryStatus(bool force_update) {
    int level = 0;
    bool charging = false;
    bool discharging = false;
    const bool ok = board_.GetBatteryLevel(level, charging, discharging);
    const bool changed = (!battery_known_ && ok) ||
                         battery_level_ != level ||
                         battery_charging_ != charging ||
                         battery_discharging_ != discharging;

    battery_known_ = ok;
    battery_level_ = level;
    battery_charging_ = charging;
    battery_discharging_ = discharging;
    if (!force_update && changed) {
        UpdateDisplay();
    }
}

void LanMicApp::HandleScroll(int direction) {
    if (direction == 0) {
        return;
    }

    // Clamp and update offset, then let UpdateDisplay() do the single wrap computation.
    if (active_page_ == Page::Summary) {
        const int next_offset = summary_scroll_offset_ + direction;
        if (next_offset != summary_scroll_offset_ && next_offset >= 0) {
            summary_scroll_offset_ = next_offset;
            UpdateDisplay();
        }
        return;
    }

    const int next_offset = log_scroll_offset_ + direction;
    if (next_offset != log_scroll_offset_ && next_offset >= 0) {
        log_scroll_offset_ = next_offset;
        UpdateDisplay();
    }
}

void LanMicApp::MoveTodoSelection(int direction) {
    if (direction == 0 || todo_items_.empty()) {
        return;
    }

    const int count = static_cast<int>(todo_items_.size());
    const int current = todo_selected_index_ < 0 ? 0 : std::clamp(todo_selected_index_, 0, count - 1);
    const int next = todo_selected_index_ < 0
        ? 0
        : (current + direction + count) % count;
    if (next == todo_selected_index_) {
        return;
    }

    todo_selected_index_ = next;
    todo_last_action_text_ = "当前计划 " + std::to_string(todo_selected_index_ + 1);
    if (IsServerConnected()) {
        SendTodoCommand(direction < 0 ? "select_prev" : "select_next");
    }
    UpdateDisplay();
}

void LanMicApp::ToggleSelectedTodo() {
    if (todo_items_.empty() ||
        todo_selected_index_ < 0 ||
        todo_selected_index_ >= static_cast<int>(todo_items_.size())) {
        status_text_ = "无待办";
        hint_text_ = "请先添加计划";
        UpdateDisplay();
        return;
    }

    const int item_index = todo_selected_index_ + 1;
    const bool next_completed = !todo_items_[todo_selected_index_].completed;
    const TodoItem item = todo_items_[todo_selected_index_];
    todo_items_[todo_selected_index_].completed = next_completed;
    todo_last_action_text_ = next_completed
        ? "已完成计划 " + std::to_string(item_index)
        : "已恢复计划 " + std::to_string(item_index);

    if (IsServerConnected()) {
        SendTodoCommand("toggle", item_index, next_completed ? 1 : 0, item.id.c_str());
    } else {
        QueueOfflineTodoToggle(item, next_completed);
        todo_last_action_text_ += " (待同步)";
    }
    SaveCachedTodoState();
    UpdateDisplay();
}

void LanMicApp::DeleteSelectedTodo() {
    if (todo_items_.empty() ||
        todo_selected_index_ < 0 ||
        todo_selected_index_ >= static_cast<int>(todo_items_.size())) {
        status_text_ = "无待办";
        hint_text_ = "请先添加计划";
        UpdateDisplay();
        return;
    }

    const int item_index = todo_selected_index_ + 1;
    const TodoItem item = todo_items_[todo_selected_index_];
    todo_items_.erase(todo_items_.begin() + todo_selected_index_);
    if (todo_items_.empty()) {
        todo_selected_index_ = -1;
    } else {
        todo_selected_index_ = std::min(
            todo_selected_index_,
            static_cast<int>(todo_items_.size()) - 1);
    }

    todo_last_action_text_ = "已删除计划 " + std::to_string(item_index);
    if (IsServerConnected()) {
        SendTodoCommand("delete", item_index, -1, item.id.c_str());
    } else {
        QueueOfflineTodoDelete(item);
        todo_last_action_text_ += " (待同步)";
    }
    SaveCachedTodoState();
    UpdateDisplay();
}

void LanMicApp::QueueOfflineTodoToggle(const TodoItem& item, bool completed) {
    if (item.id.empty()) {
        return;
    }
    for (const auto& op : pending_todo_ops_) {
        if (op.id == item.id && op.type == PendingTodoOpType::Delete) {
            return;
        }
    }
    pending_todo_ops_.erase(
        std::remove_if(
            pending_todo_ops_.begin(),
            pending_todo_ops_.end(),
            [&item](const PendingTodoOp& op) {
                return op.id == item.id && op.type == PendingTodoOpType::Toggle;
            }),
        pending_todo_ops_.end());
    pending_todo_ops_.push_back({PendingTodoOpType::Toggle, item.id, completed});
    SavePendingTodoOps();
}

void LanMicApp::QueueOfflineTodoDelete(const TodoItem& item) {
    if (item.id.empty()) {
        return;
    }
    pending_todo_ops_.erase(
        std::remove_if(
            pending_todo_ops_.begin(),
            pending_todo_ops_.end(),
            [&item](const PendingTodoOp& op) {
                return op.id == item.id;
            }),
        pending_todo_ops_.end());
    pending_todo_ops_.push_back({PendingTodoOpType::Delete, item.id, false});
    SavePendingTodoOps();
}

void LanMicApp::FlushPendingTodoOps() {
    if (!IsServerConnected() || pending_todo_ops_.empty()) {
        return;
    }

    size_t sent = 0;
    for (const auto& op : pending_todo_ops_) {
        const bool ok = op.type == PendingTodoOpType::Toggle
            ? SendTodoCommand("toggle", 0, op.completed ? 1 : 0, op.id.c_str())
            : SendTodoCommand("delete", 0, -1, op.id.c_str());
        if (!ok) {
            break;
        }
        ++sent;
    }

    if (sent > 0) {
        pending_todo_ops_.erase(pending_todo_ops_.begin(), pending_todo_ops_.begin() + sent);
        SavePendingTodoOps();
        todo_last_action_text_ = pending_todo_ops_.empty()
            ? "离线待办"
            : "部分离线更改待同步";
    }
}

void LanMicApp::LoadCachedTodoState() {
    Settings nvs(kLanMicNamespace);
    const std::string serialized = nvs.GetString(kCachedTodoStateKey, "");
    if (serialized.empty()) {
        return;
    }

    cJSON* root = cJSON_Parse(serialized.c_str());
    if (!cJSON_IsObject(root)) {
        if (root != nullptr) {
            cJSON_Delete(root);
        }
        ESP_LOGW(kTag, "Ignoring corrupt cached todo state");
        Settings writable(kLanMicNamespace, true);
        writable.EraseKey(kCachedTodoStateKey);
        return;
    }

    cJSON* items = cJSON_GetObjectItemCaseSensitive(root, "items");
    cJSON* selected_index = cJSON_GetObjectItemCaseSensitive(root, "selectedIndex");
    const char* last_action = GetJsonString(root, "lastActionText");

    std::vector<TodoItem> cached_items;
    if (cJSON_IsArray(items)) {
        cJSON* item = nullptr;
        cJSON_ArrayForEach(item, items) {
            const char* id = GetJsonString(item, "id");
            const char* title = GetJsonString(item, "title");
            if (title == nullptr || title[0] == '\0') {
                continue;
            }
            cached_items.push_back({
                id != nullptr ? id : "",
                title,
                GetJsonBool(item, "completed", false),
                GetJsonString(item, "dueAt") != nullptr ? GetJsonString(item, "dueAt") : ""
            });
        }
    }

    todo_items_ = std::move(cached_items);
    if (cJSON_IsNumber(selected_index)) {
        todo_selected_index_ = selected_index->valueint;
    } else {
        todo_selected_index_ = todo_items_.empty() ? -1 : 0;
    }
    if (todo_items_.empty()) {
        todo_selected_index_ = -1;
    } else {
        todo_selected_index_ = std::clamp(
            todo_selected_index_,
            0,
            static_cast<int>(todo_items_.size()) - 1);
    }
    if (last_action != nullptr && last_action[0] != '\0') {
        todo_last_action_text_ = last_action;
    } else if (!todo_items_.empty()) {
        todo_last_action_text_ = "缓存待办";
    }

    ESP_LOGI(kTag, "Loaded %u cached todo items",
             static_cast<unsigned>(todo_items_.size()));
    cJSON_Delete(root);
}

void LanMicApp::SaveCachedTodoState() {
    cJSON* root = cJSON_CreateObject();
    cJSON_AddNumberToObject(root, "selectedIndex", todo_selected_index_);
    if (!todo_last_action_text_.empty()) {
        cJSON_AddStringToObject(root, "lastActionText", todo_last_action_text_.c_str());
    }

    cJSON* items = cJSON_CreateArray();
    for (const auto& todo : todo_items_) {
        if (todo.title.empty()) {
            continue;
        }
        cJSON* item = cJSON_CreateObject();
        cJSON_AddStringToObject(item, "id", todo.id.c_str());
        cJSON_AddStringToObject(item, "title", todo.title.c_str());
        cJSON_AddBoolToObject(item, "completed", todo.completed);
        if (!todo.due_at.empty()) {
            cJSON_AddStringToObject(item, "dueAt", todo.due_at.c_str());
        }
        cJSON_AddItemToArray(items, item);
    }
    cJSON_AddItemToObject(root, "items", items);

    char* text = cJSON_PrintUnformatted(root);
    if (text != nullptr) {
        const size_t length = std::strlen(text);
        Settings nvs(kLanMicNamespace, true);
        if (length <= kCachedTodoStateMaxBytes) {
            nvs.SetString(kCachedTodoStateKey, text);
        } else {
            ESP_LOGW(kTag,
                     "Cached todo state too large (%u bytes), not saving",
                     static_cast<unsigned>(length));
            nvs.EraseKey(kCachedTodoStateKey);
        }
        cJSON_free(text);
    }
    cJSON_Delete(root);
}

void LanMicApp::LoadPendingTodoOps() {
    Settings nvs(kLanMicNamespace);
    const std::string serialized = nvs.GetString(kPendingTodoOpsKey, "");
    if (serialized.empty()) {
        return;
    }

    cJSON* root = cJSON_Parse(serialized.c_str());
    if (!cJSON_IsArray(root)) {
        if (root != nullptr) {
            cJSON_Delete(root);
        }
        ESP_LOGW(kTag, "Ignoring corrupt pending todo ops");
        Settings writable(kLanMicNamespace, true);
        writable.EraseKey(kPendingTodoOpsKey);
        return;
    }

    pending_todo_ops_.clear();
    cJSON* item = nullptr;
    cJSON_ArrayForEach(item, root) {
        const char* type = GetJsonString(item, "type");
        const char* id = GetJsonString(item, "id");
        if (type == nullptr || id == nullptr || id[0] == '\0') {
            continue;
        }
        PendingTodoOp op;
        if (std::strcmp(type, "toggle") == 0) {
            op.type = PendingTodoOpType::Toggle;
            op.completed = GetJsonBool(item, "completed", false);
        } else if (std::strcmp(type, "delete") == 0) {
            op.type = PendingTodoOpType::Delete;
            op.completed = false;
        } else {
            continue;
        }
        op.id = id;
        pending_todo_ops_.push_back(op);
    }
    cJSON_Delete(root);

    if (!pending_todo_ops_.empty()) {
        ESP_LOGI(kTag, "Loaded %u pending todo ops",
                 static_cast<unsigned>(pending_todo_ops_.size()));
    }
}

void LanMicApp::SavePendingTodoOps() {
    Settings nvs(kLanMicNamespace, true);
    if (pending_todo_ops_.empty()) {
        nvs.EraseKey(kPendingTodoOpsKey);
        return;
    }

    cJSON* root = cJSON_CreateArray();
    for (const auto& op : pending_todo_ops_) {
        if (op.id.empty()) {
            continue;
        }
        cJSON* item = cJSON_CreateObject();
        cJSON_AddStringToObject(
            item,
            "type",
            op.type == PendingTodoOpType::Toggle ? "toggle" : "delete");
        cJSON_AddStringToObject(item, "id", op.id.c_str());
        if (op.type == PendingTodoOpType::Toggle) {
            cJSON_AddBoolToObject(item, "completed", op.completed);
        }
        cJSON_AddItemToArray(root, item);
    }

    char* text = cJSON_PrintUnformatted(root);
    if (text != nullptr) {
        nvs.SetString(kPendingTodoOpsKey, text);
        cJSON_free(text);
    }
    cJSON_Delete(root);
}

void LanMicApp::OpenTodoMenu(TodoMenuKind kind) {
    if (has_pending_transcript_ || phase_ == Phase::Recording || phase_ == Phase::Transcribing) {
        return;
    }
    todo_menu_kind_ = kind;
    todo_menu_selected_item_ = 0;
    todo_menu_open_ = true;
    active_page_ = kind == TodoMenuKind::Live ? Page::Summary : Page::Todo;
    UpdateDisplay();
}

void LanMicApp::CloseTodoMenu() {
    todo_menu_open_ = false;
    todo_menu_kind_ = TodoMenuKind::Todo;
    todo_menu_selected_item_ = 0;
    UpdateDisplay();
}

int LanMicApp::GetTodoMenuItemCount() const {
    if (todo_menu_kind_ == TodoMenuKind::ReconnectStuck) {
        return 4;
    }
    if (todo_menu_kind_ == TodoMenuKind::TodoAction) {
        return 3;
    }
    if (todo_menu_kind_ == TodoMenuKind::Live) {
        return 5;
    }
    return 6;
}

std::string LanMicApp::GetTodoMenuItemLabel(int item) const {
    if (todo_menu_kind_ == TodoMenuKind::ReconnectStuck) {
        switch (item) {
            case 0:
                return "重试连接主机";
            case 1:
                return "进入离线待办";
            case 2:
                return "重启设备";
            case 3:
                return "返回";
            default:
                return "";
        }
    }

    if (todo_menu_kind_ == TodoMenuKind::Live) {
        switch (item) {
            case 0:
                return "切换到待办";
            case 1:
                return "重新连接主机";
            case 2:
                return "重启设备";
            case 3:
                return "设置";
            case 4:
                return "返回";
            default:
                return "";
        }
    }

    if (todo_menu_kind_ == TodoMenuKind::TodoAction) {
        const bool has_item =
            !todo_items_.empty() &&
            todo_selected_index_ >= 0 &&
            todo_selected_index_ < static_cast<int>(todo_items_.size());
        const bool is_done = has_item && todo_items_[todo_selected_index_].completed;
        switch (item) {
            case 0:
                return is_done ? "标记未完成" : "标记完成";
            case 1:
                return "删除当前项";
            case 2:
                return "返回";
            default:
                return "";
        }
    }

    const bool has_item =
        !todo_items_.empty() &&
        todo_selected_index_ >= 0 &&
        todo_selected_index_ < static_cast<int>(todo_items_.size());
    const bool is_done = has_item && todo_items_[todo_selected_index_].completed;
    switch (item) {
        case 0:
            return is_done ? "标记未完成" : "标记完成";
        case 1:
            return "删除当前项";
        case 2:
            return "切换到编程";
        case 3:
            return "重新连接主机";
        case 4:
            return "重启设备";
        case 5:
            return "返回";
        default:
            return "";
    }
}

void LanMicApp::HandleTodoMenuInput(bool up_click, bool down_click, bool boot_press) {
    const int item_count = GetTodoMenuItemCount();
    if (item_count <= 0) {
        return;
    }
    if (up_click) {
        todo_menu_selected_item_ = (todo_menu_selected_item_ + item_count - 1) % item_count;
        UpdateDisplay();
    } else if (down_click) {
        todo_menu_selected_item_ = (todo_menu_selected_item_ + 1) % item_count;
        UpdateDisplay();
    } else if (boot_press) {
        ExecuteTodoMenuItem(todo_menu_selected_item_);
    }
}

void LanMicApp::ExecuteTodoMenuItem(int item) {
    auto restart_device = [this]() {
        if (!pending_todo_ops_.empty()) {
            status_text_ = "待同步";
            hint_text_ = "重启前请先重连";
            CloseTodoMenu();
            return;
        }
        status_text_ = "重启中";
        hint_text_ = "正在重连主机";
        UpdateDisplay();
        vTaskDelay(pdMS_TO_TICKS(300));
        esp_restart();
    };

    if (todo_menu_kind_ == TodoMenuKind::ReconnectStuck) {
        switch (item) {
            case 0:
                CloseTodoMenu();
                RequestReconnect("正在重试主机...");
                return;
            case 1:
                EnterOfflineTodoMode("离线待办");
                return;
            case 2:
                restart_device();
                return;
            case 3:
            default:
                CloseTodoMenu();
                return;
        }
    }

    if (todo_menu_kind_ == TodoMenuKind::Live) {
        switch (item) {
            case 0:
                CloseTodoMenu();
                SwitchPage(Page::Todo);
                return;
            case 1:
                CloseTodoMenu();
                RequestReconnect("正在刷新主机...");
                return;
            case 2:
                restart_device();
                return;
            case 3:
                CloseTodoMenu();
                EnterSettings();
                return;
            case 4:
            default:
                CloseTodoMenu();
                return;
        }
    }

    if (todo_menu_kind_ == TodoMenuKind::TodoAction) {
        switch (item) {
            case 0:
                ToggleSelectedTodo();
                CloseTodoMenu();
                return;
            case 1:
                DeleteSelectedTodo();
                CloseTodoMenu();
                return;
            case 2:
            default:
                CloseTodoMenu();
                return;
        }
    }

    const bool online = IsServerConnected();
    switch (item) {
        case 0:
            ToggleSelectedTodo();
            CloseTodoMenu();
            return;
        case 1:
            DeleteSelectedTodo();
            CloseTodoMenu();
            return;
        case 2:
            CloseTodoMenu();
            SwitchPage(Page::Summary);
            if (!online) {
                pending_normal_after_reconnect_ = true;
                RequestReconnect("正在重连编程模式...");
            }
            return;
        case 3:
            CloseTodoMenu();
            RequestReconnect(online ? "正在刷新主机..." : "正在重试主机...");
            return;
        case 4:
            restart_device();
            return;
        case 5:
        default:
            CloseTodoMenu();
            return;
    }
}

void LanMicApp::EnterOfflineTodoMode(const std::string& message) {
    DisconnectWebSocket();
    board_.SetPowerSaveLevel(PowerSaveLevel::LOW_POWER);
    offline_todo_mode_ = true;
    reconnect_stuck_prompt_ = connect_attempt_running_.load(std::memory_order_acquire);
    todo_menu_open_ = false;
    active_page_ = Page::Todo;
    network_state_ = IsWifiConnected() ? NetworkState::Wifi : NetworkState::Offline;
    phase_ = Phase::Idle;
    status_text_ = "离线待办";
    hint_text_ = "";
    todo_last_action_text_ = message;
    UpdateDisplay();
}

void LanMicApp::RequestReconnect(const std::string& message) {
    board_.SetPowerSaveLevel(PowerSaveLevel::BALANCED);
    if (!IsWifiConnected()) {
        network_state_ = NetworkState::Offline;
        status_text_ = "无 Wi‑Fi";
        hint_text_ = "请打开设置";
        UpdateDisplay();
        return;
    }

    const bool connect_attempt_running = connect_attempt_running_.load(std::memory_order_acquire);
    const int64_t now_ms = esp_timer_get_time() / 1000;
    const int64_t connect_attempt_started_ms = connect_attempt_started_ms_.load(std::memory_order_acquire);
    const bool connect_stuck = connect_attempt_running &&
                               connect_attempt_started_ms > 0 &&
                               (now_ms - connect_attempt_started_ms) >= kConnectAttemptWatchdogMs;

    if (connect_attempt_running) {
        connect_cancel_requested_.store(true, std::memory_order_release);
        manual_reconnect_requested_.store(true, std::memory_order_release);
        server_uri_.clear();

        if (connect_stuck && connect_task_handle_ != nullptr) {
            ESP_LOGW(kTag, "Force abort stuck connect task for manual reconnect");
            vTaskDelete(connect_task_handle_);
            connect_task_handle_ = nullptr;
            connect_attempt_started_ms_.store(0, std::memory_order_release);
            connect_attempt_running_.store(false, std::memory_order_release);
            ws_.reset();
            hello_sent_ = false;
        }
    }

    if (connect_attempt_running_.load(std::memory_order_acquire)) {
        status_text_ = "重试中";
        hint_text_ = "正在取消旧连接...";
        UpdateDisplay();
        return;
    }

    if (IsServerConnected()) {
        DisconnectWebSocket();
    }

    manual_reconnect_requested_.store(true, std::memory_order_release);
    server_uri_.clear();
    offline_todo_mode_ = false;
    reconnect_stuck_prompt_ = false;
    network_state_ = NetworkState::Wifi;
    status_text_ = "连接中";
    hint_text_ = message;
    phase_ = Phase::Idle;
    StartConnectAttemptAsync();
    UpdateDisplay();
}

void LanMicApp::SwitchPage(Page page) {
    if (has_pending_transcript_ || active_page_ == page) {
        return;
    }
    active_page_ = page;
    offline_todo_mode_ = page == Page::Todo ? offline_todo_mode_ : false;
    todo_menu_open_ = false;
    settings_editing_volume_ = false;
    if (display_ != nullptr) {
        const int interval = page == Page::Todo ? display_todo_refresh_ms_ : display_coding_refresh_ms_;
        display_->SetSampleIntervalMs(interval);
        display_->SetInverted(display_dark_style_);
    }
    if (page == Page::Todo || page == Page::Summary) {
        SyncVoiceModeToPage(page);
    }
    UpdateDisplay();
}

void LanMicApp::EnterSettings() {
    if (has_pending_transcript_) {
        return;
    }
    if (active_page_ != Page::Settings) {
        active_page_ = Page::Settings;
        todo_menu_open_ = false;
        settings_selected_item_ = 0;
        settings_editing_volume_ = false;
        UpdateDisplay();
    }
}

void LanMicApp::SaveVolume() {
    Settings nvs(kLanMicNamespace, true);
    nvs.SetInt(kVolumeKey, volume_);
}

void LanMicApp::Shutdown() {
    DisconnectWebSocket();
    status_text_ = "关机中...";
    hint_text_ = "按 BOOT 唤醒";
    active_page_ = Page::Summary;
    UpdateDisplay();
    vTaskDelay(pdMS_TO_TICKS(800));
    esp_sleep_enable_ext0_wakeup(static_cast<gpio_num_t>(BOOT_BUTTON_GPIO), 0);
    esp_deep_sleep_start();
}

void LanMicApp::HandleSettingsInput(bool up_click, bool down_click, bool boot_press) {
    if (settings_editing_volume_) {
        if (up_click) {
            volume_ = std::min(100, volume_ + 10);
            codec_->SetOutputVolume(volume_);
            UpdateDisplay();
        } else if (down_click) {
            volume_ = std::max(0, volume_ - 10);
            codec_->SetOutputVolume(volume_);
            UpdateDisplay();
        } else if (boot_press) {
            SaveVolume();
            settings_editing_volume_ = false;
            UpdateDisplay();
        }
        return;
    }

    if (up_click) {
        settings_selected_item_ = (settings_selected_item_ + kSettingsItemCount - 1) % kSettingsItemCount;
        UpdateDisplay();
    } else if (down_click) {
        settings_selected_item_ = (settings_selected_item_ + 1) % kSettingsItemCount;
        UpdateDisplay();
    } else if (boot_press) {
        ExecuteSettingsItem(settings_selected_item_);
    }
}

void LanMicApp::ExecuteSettingsItem(int item) {
    switch (item) {
        case kSettingsItemVolume:
            settings_editing_volume_ = true;
            UpdateDisplay();
            break;
        case kSettingsItemWifi:
            EnterWifiSetupMode();
            break;
        case kSettingsItemRestart:
            status_text_ = "重启中...";
            UpdateDisplay();
            vTaskDelay(pdMS_TO_TICKS(500));
            esp_restart();
            break;
        case kSettingsItemPowerOff:
            Shutdown();
            break;
        default:
            break;
    }
}

const char* LanMicApp::GetNetworkLabel() const {
    if (offline_todo_mode_ && network_state_ != NetworkState::Server) {
        return "离线";
    }
    switch (network_state_) {
        case NetworkState::Server:
            return "在线";
        case NetworkState::Wifi:
            return "无服务器";
        case NetworkState::Config:
            return "配网";
        case NetworkState::Offline:
        default:
            return "离线";
    }
}

const char* LanMicApp::GetToolLabel() const {
    if (send_target_ == "claude_code") {
        return "Claude";
    }
    if (send_target_ == "text_injector") {
        return "Inject";
    }
    return "Codex";
}

const char* LanMicApp::GetModeLabel() const {
    return (active_page_ == Page::Todo || offline_todo_mode_) ? "模式: 待办" : "模式: 编程";
}

std::string LanMicApp::GetPhaseLabel() const {
    switch (phase_) {
        case Phase::Recording:
            return "● 录音";
        case Phase::Transcribing:
            return "... 转写";
        case Phase::AwaitingAction:
            return "? 发送?";
        case Phase::Running:
            return "▶ AI处理中";
        case Phase::Error:
            return "! 错误";
        case Phase::Idle:
        default:
            return "";
    }
}

bool LanMicApp::ShouldShowIdleTodoPage() const {
    return offline_todo_mode_ &&
           phase_ == Phase::Idle &&
           !has_pending_transcript_ &&
           active_page_ != Page::Log &&
           active_page_ != Page::Settings &&
           !todo_menu_open_;
}

void LanMicApp::ShowIdleTodoPage() {
    if (ShouldShowIdleTodoPage()) {
        active_page_ = Page::Todo;
    }
}

std::string LanMicApp::GetFooterText() const {
    if (has_pending_transcript_) {
        return "BOOT追加 | ↑发送 | ↓撤销";
    }
    if (phase_ == Phase::Recording) {
        return "松开 BOOT 停止";
    }
    if (network_state_ == NetworkState::Config) {
        return "连接 AP 后打开 192.168.4.1";
    }
    if (todo_menu_open_) {
        return "↑/↓ 菜单 | BOOT 确认";
    }
    if (active_page_ == Page::Settings) {
        return settings_editing_volume_ ? "↑/↓ ±10 | BOOT 保存"
                                        : "↑/↓ 导航 | BOOT 确认 | 长按↑返回";
    }
    if (active_page_ == Page::Summary) {
        if (!plan_options_.empty()) {
            return "↑/↓ 选方案 | BOOT 应用";
        }
        return "长按↑菜单 | 长按输入/短按回车";
    }
    if (active_page_ == Page::Todo) {
        return IsServerConnected()
            ? "长按↑菜单 | 长按添加/短按完成"
            : "长按↑菜单 | ↑/↓ 选择";
    }
    return "↑/↓ 滚动 | 长按↑ | 长按↓设置";
}

std::string LanMicApp::BuildPromptBody() const {
    if (!plan_options_.empty()) {
        std::vector<std::string> rows;
        const int count = static_cast<int>(plan_options_.size());
        const int current = plan_selected_index_ < 0 ? 0 : std::clamp(plan_selected_index_, 0, count - 1);
        const int start = std::clamp(current - 1, 0, std::max(0, count - static_cast<int>(kPromptVisibleLines)));
        const int end = std::min(count, start + static_cast<int>(kPromptVisibleLines));
        for (int index = start; index < end; ++index) {
            std::string row = (index == current) ? "> " : "  ";
            row += std::to_string(index + 1);
            row += ". ";
            row += plan_options_[index];
            rows.push_back(row);
        }
        std::string body;
        for (size_t i = 0; i < rows.size(); ++i) {
            if (i > 0) {
                body += "\n";
            }
            body += rows[i];
        }
        return body;
    }
    if (!transcript_text_.empty()) {
        return transcript_text_;
    }
    if (!hint_text_.empty()) {
        return hint_text_;
    }
    if (offline_todo_mode_) {
        return "离线待办缓存";
    }
    // Default hint based on connection state
    switch (network_state_) {
        case NetworkState::Server:
            return active_page_ == Page::Todo
                ? "待办语音模式\n长按↑打开菜单"
                : "编程模式\n长按↑打开菜单";
        case NetworkState::Wifi:
            return "正在查找服务器...";
        case NetworkState::Config:
            return "打开 192.168.4.1";
        case NetworkState::Offline:
        default:
            return "连接 Wi‑Fi 中...";
    }
}

std::string LanMicApp::BuildReplyBody() const {
    if (!plan_options_.empty()) {
        return "按 BOOT 应用当前方案";
    }
    if (!latest_assistant_text_.empty()) {
        return latest_assistant_text_;
    }
    if (!cli_status_text_.empty()) {
        return cli_status_text_;
    }
    return "CLI 暂无回复";
}

std::vector<std::string> LanMicApp::WrapText(const std::string& text, size_t max_chars) const {
    return WrapUtf8Lines(text, max_chars, 0);
}

std::vector<std::string> LanMicApp::SliceLines(const std::vector<std::string>& lines, int offset, size_t max_lines) const {
    std::vector<std::string> visible;
    if (lines.empty()) {
        return visible;
    }

    const int clamped_offset = std::max(0, offset);
    const size_t start = static_cast<size_t>(clamped_offset);
    const size_t end = std::min(lines.size(), start + max_lines);
    for (size_t i = start; i < end; ++i) {
        visible.push_back(lines[i]);
    }
    return visible;
}

void LanMicApp::UpdateLed() {
    switch (phase_) {
        case Phase::Recording:
            ZectrixSetFactoryLedOverride(true, true);   // blink only while actively recording
            break;
        case Phase::Error:
            ZectrixSetFactoryLedOverride(true, false);  // keep LED off; error is shown on e-paper
            break;
        case Phase::Transcribing:
        case Phase::Running:
        case Phase::AwaitingAction:
            ZectrixSetFactoryLedOverride(true, false);  // keep LED off; status is shown on e-paper
            break;
        case Phase::Idle:
        default:
            ZectrixSetFactoryLedOverride(true, false);  // suppress distracting charge blink
            break;
    }
}

void LanMicApp::PlayBeep(int freq_hz, int duration_ms) {
    if (codec_ == nullptr || freq_hz <= 0 || duration_ms <= 0) {
        return;
    }
    const int sample_rate = codec_->output_sample_rate() > 0 ? codec_->output_sample_rate() : 16000;
    const int num_samples = sample_rate * duration_ms / 1000;
    if (num_samples <= 0) {
        return;
    }
    const int fade = std::min(num_samples / 4, sample_rate * 8 / 1000);
    const double step = 2.0 * M_PI * freq_hz / sample_rate;
    constexpr double kAmplitude = 10000.0;

    std::vector<int16_t> pcm(num_samples);
    for (int i = 0; i < num_samples; i++) {
        double s = std::sin(step * i) * kAmplitude;
        if (i < fade) {
            s *= static_cast<double>(i) / fade;
        } else if (i > num_samples - fade) {
            s *= static_cast<double>(num_samples - i) / fade;
        }
        pcm[i] = static_cast<int16_t>(s);
    }
    codec_->EnableOutput(true);
    codec_->OutputData(pcm);
}

void LanMicApp::DrawHorizontalLine(int y, int thickness) {
    if (display_ == nullptr || thickness <= 0) {
        return;
    }

    const int width = display_->width();
    const int bytes_per_row = (width + 7) >> 3;
    std::vector<uint8_t> buffer(bytes_per_row * thickness, 0xFF);
    display_->WriteRaw1bpp(0, y, width, thickness, buffer.data(), buffer.size());
}

void LanMicApp::DrawTodoDashLine(int y, int x_start, int x_end) {
    if (display_ == nullptr || y < 0 || y >= display_->height()) {
        return;
    }
    if (x_end <= x_start) {
        return;
    }
    const int width = x_end - x_start;
    if (width <= 0) {
        return;
    }
    const int bytes_per_row = (width + 7) / 8;
    std::vector<uint8_t> row_bytes(bytes_per_row, 0x00);
    for (int x = 0; x < width; ++x) {
        const bool draw = (x % 8) < 5;
        if (!draw) {
            continue;
        }
        const int bit_index = x;
        row_bytes[bit_index >> 3] |= static_cast<uint8_t>(1U << (7 - (bit_index & 7)));
    }
    display_->WriteRaw1bpp(x_start, y, width, 1, row_bytes.data(), row_bytes.size());
}

void LanMicApp::DrawTodoHeaderIcon(int x, int y) {
    if (display_ == nullptr) {
        return;
    }
    constexpr int w = 16;
    constexpr int h = 16;
    constexpr int bytes_per_row = (w + 7) / 8;
    std::vector<uint8_t> buffer(bytes_per_row * h, 0x00);

    auto set_pixel = [&](int px, int py) {
        if (px < 0 || px >= w || py < 0 || py >= h) {
            return;
        }
        const int bit_index = py * w + px;
        buffer[bit_index >> 3] |= static_cast<uint8_t>(1U << (7 - (bit_index & 7)));
    };

    for (int px = 2; px <= 13; ++px) {
        set_pixel(px, 2);
        set_pixel(px, 13);
    }
    for (int py = 3; py <= 12; ++py) {
        set_pixel(2, py);
        set_pixel(13, py);
    }
    for (int px = 5; px <= 10; ++px) {
        set_pixel(px, 1);
    }
    set_pixel(5, 2);
    set_pixel(10, 2);

    for (int py = 5; py <= 10; py += 2) {
        set_pixel(5, py);
        set_pixel(6, py);
        for (int px = 8; px <= 11; ++px) {
            set_pixel(px, py);
        }
    }

    display_->WriteRaw1bpp(x, y, w, h, buffer.data(), buffer.size());
}

void LanMicApp::DrawWifiIcon(int x, int y) {
    if (display_ == nullptr) {
        return;
    }
    display_->WriteRaw1bpp(x, y, 12, 12, kWifiIcon12x12, sizeof(kWifiIcon12x12));
}

void LanMicApp::DrawBatteryIcon(int x, int y, int level, bool charging) {
    if (display_ == nullptr) {
        return;
    }

    const int clamped_level = std::clamp(level, 0, 100);
    std::vector<uint8_t> buffer(kBatteryIcon14x8, kBatteryIcon14x8 + sizeof(kBatteryIcon14x8));
    int fill_columns = (clamped_level + 5) / 10;
    if (clamped_level > 0 && fill_columns == 0) {
        fill_columns = 1;
    }
    fill_columns = std::clamp(fill_columns, 0, 10);

    for (int row = 1; row <= 6; ++row) {
        for (int col = 1; col <= fill_columns; ++col) {
            const int bit_index = row * 16 + col;
            buffer[bit_index >> 3] |= static_cast<uint8_t>(1U << (7 - (bit_index & 7)));
        }
    }
    if (charging) {
        for (int row = 2; row <= 5; ++row) {
            const int bit_index = row * 16 + 5;
            buffer[bit_index >> 3] |= static_cast<uint8_t>(1U << (7 - (bit_index & 7)));
        }
        for (int col = 4; col <= 6; ++col) {
            const int bit_index = 4 * 16 + col;
            buffer[bit_index >> 3] |= static_cast<uint8_t>(1U << (7 - (bit_index & 7)));
        }
    }
    display_->WriteRaw1bpp(x, y, 14, 8, buffer.data(), buffer.size());
}

void LanMicApp::UpdateDisplay() {
    UpdateLed();

    if (display_ == nullptr) {
        return;
    }

    const int interval = active_page_ == Page::Todo ? display_todo_refresh_ms_ : display_coding_refresh_ms_;
    display_->SetSampleIntervalMs(interval);
    display_->SetInverted(display_dark_style_);

    const Page render_page = active_page_;
    const bool render_offline_todo_mode = offline_todo_mode_;

    std::vector<Display::TextItem> texts;
    auto single_line = [](const std::string& value, size_t max_chars) -> std::string {
        const auto lines = WrapUtf8Lines(value, max_chars, 1);
        return lines.empty() ? std::string() : lines.front();
    };

    std::string battery_text = "--";
    if (battery_known_) {
        battery_text = std::to_string(std::clamp(battery_level_, 0, 100));
        if (battery_charging_) {
            battery_text += "+";
        }
    }

    std::string quota_status_text;
    if (quota_5h_remaining_pct_ >= 0 || quota_week_remaining_pct_ >= 0) {
        const std::string q5 = quota_5h_remaining_pct_ >= 0 ? std::to_string(std::clamp(quota_5h_remaining_pct_, 0, 100)) : "--";
        const std::string qw = quota_week_remaining_pct_ >= 0 ? std::to_string(std::clamp(quota_week_remaining_pct_, 0, 100)) : "--";
        quota_status_text = "5H:" + q5 + " 7d:" + qw;
    }

    texts.push_back({GetNetworkLabel(), 28, 9, 16});
    texts.push_back({(render_page == Page::Todo || render_offline_todo_mode) ? "待办" : "编程", 96, 9, 16});
    texts.push_back({GetPhaseLabel(), 166, 9, 16});
    if (!quota_status_text.empty()) {
        texts.push_back({quota_status_text, 250, 9, 16});
    }
    texts.push_back({battery_text, 346, 9, 16});
    const char* page_label = render_page == Page::Summary ? "编程"
                           : render_page == Page::Todo    ? "待办"
                           : render_page == Page::Log     ? "日志"
                           :                               "设置";
    if (render_page != Page::Todo) {
        texts.push_back({single_line(repo_name_.empty() ? "Codex" : repo_name_, 18), 12, kContentHeaderY, 16});
        texts.push_back({page_label, 316, kContentHeaderY, 16});
    }

    if (render_page == Page::Summary) {
        if (todo_menu_open_ && todo_menu_kind_ == TodoMenuKind::Live) {
            texts.push_back({"编程菜单", 12, kPromptTitleY, 16});
            texts.push_back({single_line(GetModeLabel(), 16), 228, kPromptTitleY, 16});
            std::vector<std::string> rows;
            const int count = GetTodoMenuItemCount();
            for (int index = 0; index < count; ++index) {
                std::string row = (index == todo_menu_selected_item_) ? "> " : "  ";
                row += GetTodoMenuItemLabel(index);
                rows.push_back(single_line(row, kBodyCharsPerLine));
            }
            int y = kPromptBodyY;
            for (const auto& row : rows) {
                texts.push_back({row, 12, y, 16});
                y += kLineHeight;
            }
        } else {
            // Derive a readable status: phase takes priority, else connection state
            std::string status_display;
            if (phase_ == Phase::Recording || phase_ == Phase::Transcribing ||
                phase_ == Phase::AwaitingAction || phase_ == Phase::Running || phase_ == Phase::Error) {
                status_display = status_text_;
            } else if (network_state_ != NetworkState::Server) {
                status_display = GetNetworkLabel();
            } else {
                status_display = GetModeLabel();
            }
            texts.push_back({"输入", 12, kPromptTitleY, 16});
            texts.push_back({single_line(status_display, 16), 228, kPromptTitleY, 16});

            const auto prompt_lines = SliceLines(WrapText(BuildPromptBody(), kBodyCharsPerLine), 0, kPromptVisibleLines);
            int y = kPromptBodyY;
            for (const auto& line : prompt_lines) {
                texts.push_back({line, 12, y, 16});
                y += kLineHeight;
            }

            texts.push_back({"回复", 12, kReplyTitleY, 16});
            texts.push_back({single_line(cli_status_text_.empty() ? std::string(GetToolLabel()) + " 空闲" : cli_status_text_, 16), 228, kReplyTitleY, 16});

            const auto reply_lines = WrapText(BuildReplyBody(), kBodyCharsPerLine);
            const int summary_offset = std::clamp(
                summary_scroll_offset_,
                0,
                std::max(0, static_cast<int>(reply_lines.size()) - static_cast<int>(kReplyVisibleLines)));
            const auto assistant_lines = SliceLines(reply_lines, summary_offset, kReplyVisibleLines);
            y = kReplyBodyY;
            for (const auto& line : assistant_lines) {
                texts.push_back({line, 12, y, 16});
                y += kLineHeight;
            }
        }
    } else if (render_page == Page::Todo) {
        if (todo_menu_open_) {
            texts.push_back({"待办菜单", 12, kLogTitleY, 16});
            std::string todo_status = todo_last_action_text_.empty() ? GetModeLabel() : todo_last_action_text_;
            if (!pending_todo_ops_.empty()) {
                todo_status = "待同步 " + std::to_string(pending_todo_ops_.size());
            }
            texts.push_back({single_line(todo_status, 16), 228, kLogTitleY, 16});

            std::vector<std::string> rows;
            if (todo_menu_kind_ == TodoMenuKind::ReconnectStuck) {
                rows.push_back("重连卡住");
            } else if (todo_menu_kind_ == TodoMenuKind::TodoAction) {
                rows.push_back("待办操作");
            } else if (!IsServerConnected()) {
                rows.push_back("离线待办");
            } else {
                rows.push_back(GetModeLabel());
            }
            const int count = GetTodoMenuItemCount();
            for (int index = 0; index < count; ++index) {
                std::string row = (index == todo_menu_selected_item_) ? "> " : "  ";
                row += GetTodoMenuItemLabel(index);
                rows.push_back(single_line(row, kBodyCharsPerLine));
            }

            int y = kLogBodyY;
            for (const auto& line : rows) {
                texts.push_back({line, 12, y, 16});
                y += kLineHeight;
            }
        } else {
            constexpr int kTodoHeaderBottomY = 95;
            constexpr int kTodoRowStartY = 106;
            constexpr int kTodoRowHeight = 30;
            constexpr int kTodoCheckboxX = 14;
            constexpr int kTodoTimeX = 286;
            constexpr int kTodoRowsVisible = 5;

            tm todo_tm = {};
            bool has_time = false;
            RtcPcf8563* rtc = ZectrixGetRtc();
            if (rtc != nullptr) {
                has_time = rtc->GetTime(todo_tm);
            }

            DrawTodoHeaderIcon(12, 43);
            texts.push_back({has_time ? FormatTodoClockText(todo_tm) : "--:--", 38, 42, 24});
            texts.push_back({has_time ? FormatTodoDateText(todo_tm) : "--/-- --", 254, 45, 16});
            DrawHorizontalLine(kTodoHeaderBottomY, 1);

            if (todo_items_.empty()) {
                texts.push_back({"□ 暂无待办", 12, 118, 16});
                texts.push_back({IsServerConnected() ? "长按↑打开菜单" : "离线缓存为空", 12, 138, 16});
                texts.push_back({GetModeLabel(), 12, 158, 16});
            } else {
                const int max_start = std::max(0, static_cast<int>(todo_items_.size()) - kTodoRowsVisible);
                const int start_index = std::clamp(
                    todo_selected_index_ < 0 ? 0 : todo_selected_index_ - (kTodoRowsVisible / 2),
                    0,
                    max_start);
                const int end_index = std::min(
                    static_cast<int>(todo_items_.size()),
                    start_index + kTodoRowsVisible);

                int row_slot = 0;
                for (int index = start_index; index < end_index; ++index, ++row_slot) {
                    const auto& item = todo_items_[index];
                    const int row_y = kTodoRowStartY + (row_slot * kTodoRowHeight);
                    const bool selected = index == todo_selected_index_;
                    const std::string checkbox = item.completed ? "■" : "□";
                    std::string left = checkbox + " ";
                    if (selected) {
                        left += ">";
                    }
                    left += single_line(item.title, 16);
                    texts.push_back({left, kTodoCheckboxX, row_y, 16});

                    std::string right_text = FormatTodoRightTimeText(item.due_at);
                    texts.push_back({right_text, kTodoTimeX, row_y, 16});
                    DrawTodoDashLine(row_y + 20, 12, 372);
                }
            }
        }
    } else if (render_page == Page::Log) {
        texts.push_back({"日志", 12, kLogTitleY, 16});
        texts.push_back({single_line(cli_status_text_.empty() ? std::string(GetToolLabel()) + " 空闲" : cli_status_text_, 16), 228, kLogTitleY, 16});

        std::vector<std::string> wrapped;
        for (const auto& item : cli_log_lines_) {
            const auto lines = WrapText(item, kBodyCharsPerLine);
            wrapped.insert(wrapped.end(), lines.begin(), lines.end());
        }
        if (wrapped.empty()) {
            wrapped.push_back("暂无日志");
        }

        const int log_offset = std::clamp(
            log_scroll_offset_,
            0,
            std::max(0, static_cast<int>(wrapped.size()) - static_cast<int>(kLogVisibleLines)));
        int y = kLogBodyY;
        for (const auto& line : SliceLines(wrapped, log_offset, kLogVisibleLines)) {
            texts.push_back({line, 12, y, 16});
            y += kLineHeight;
        }
    } else {
        // Settings page
        texts.push_back({"设置", 12, kLogTitleY, 16});
        if (settings_editing_volume_) {
            texts.push_back({"↑/↓ ±10 BOOT 确认", 180, kLogTitleY, 14});
        }

        // Menu items
        const std::string vol_label = "音量: " + std::to_string(volume_) + "%";
        const char* items[kSettingsItemCount] = {
            vol_label.c_str(),
            "重置网络",
            "重启",
            "关机"
        };

        int y = kLogBodyY;
        for (int i = 0; i < kSettingsItemCount; ++i) {
            std::string row = (i == settings_selected_item_) ? "> " : "  ";
            row += items[i];
            if (i == kSettingsItemVolume && settings_editing_volume_) {
                row += " *";
            }
            texts.push_back({row, 12, y, 16});
            y += kLineHeight * 2;  // extra spacing for readability
        }
    }

    texts.push_back({GetFooterText(), 12, kFooterTextY, 16});

    display_->DrawTexts(texts, true);
    DrawHorizontalLine(kStatusBarBottomY);
    DrawHorizontalLine(kHeaderLineY);
    if (render_page == Page::Summary) {
        DrawHorizontalLine(kPromptDividerY);
    }
    DrawHorizontalLine(kFooterTopY);
    DrawWifiIcon(10, 8);
    DrawBatteryIcon(382, 12, battery_known_ ? battery_level_ : 0, battery_charging_);
    display_->RequestUrgentRefresh();
}

void LanMicApp::Run() {
    if (!Initialize()) {
        ESP_LOGE(kTag, "Initialization failed");
        while (true) {
            vTaskDelay(pdMS_TO_TICKS(1000));
        }
    }

    bool last_pressed = false;
    int64_t boot_pressed_since_ms = 0;
    bool todo_hold_started = false;
    int64_t last_todo_boot_release_ms = 0;
    bool todo_boot_short_pending = false;
    int64_t last_reconnect_ms = 0;
    int64_t reconnect_interval_ms = kReconnectIntervalMinMs;
    int64_t last_battery_poll_ms = 0;
    int64_t last_ws_ping_ms = 0;
    int64_t awaiting_pong_since_ms = 0;
    int64_t awaiting_pong_baseline_ms = 0;
    int64_t reconnect_prompt_started_ms = 0;
    // Tracks when the current "disconnected stretch" started.
    // Initialised to now so a cold boot with no server still gets a full grace
    // period before sleeping, but reset on every disconnect so a board that had
    // been happily connected for hours does not immediately deep-sleep after
    // the very first failed reconnect attempt.
    int64_t disconnected_since_ms = esp_timer_get_time() / 1000;

    while (true) {
        const int64_t now_ms = esp_timer_get_time() / 1000;
        if (todo_boot_short_pending &&
            (todo_menu_open_ ||
             has_pending_transcript_ ||
             phase_ == Phase::Recording ||
             phase_ == Phase::Transcribing ||
             active_page_ != Page::Todo)) {
            todo_boot_short_pending = false;
            last_todo_boot_release_ms = 0;
        }
        if (todo_boot_short_pending &&
            !IsPttPressed() &&
            (now_ms - last_todo_boot_release_ms) >= kTodoBootDoubleClickWindowMs) {
            const bool can_toggle_selected_todo =
                active_page_ == Page::Todo &&
                !todo_menu_open_ &&
                !has_pending_transcript_ &&
                (phase_ == Phase::Idle || phase_ == Phase::Running || phase_ == Phase::Error);
            todo_boot_short_pending = false;
            last_todo_boot_release_ms = 0;
            if (can_toggle_selected_todo) {
                ToggleSelectedTodo();
            }
        }
        if (connect_attempt_completed_.exchange(false, std::memory_order_acq_rel)) {
            reconnect_stuck_prompt_ = false;
            if (IsServerConnected()) {
                reconnect_interval_ms = kReconnectIntervalMinMs;
                disconnected_since_ms = now_ms;
                last_ws_ping_ms = 0;
                awaiting_pong_since_ms = 0;
                awaiting_pong_baseline_ms = 0;
            } else if (server_uri_.empty() && cached_server_uri_.empty() && GetFallbackServerUri().empty()) {
                reconnect_interval_ms = kReconnectIntervalMinMs;
            } else {
                reconnect_interval_ms = std::min(reconnect_interval_ms * 2, kReconnectIntervalMaxMs);
            }
        }
        const int64_t connect_attempt_started_ms =
            connect_attempt_started_ms_.load(std::memory_order_acquire);
        if (connect_attempt_running_.load(std::memory_order_acquire) &&
            connect_attempt_started_ms > 0 &&
            (now_ms - connect_attempt_started_ms) >= kConnectAttemptWatchdogMs &&
            !reconnect_stuck_prompt_) {
            ESP_LOGE(kTag,
                     "Connect attempt watchdog fired: started_ms=%lld now_ms=%lld",
                     static_cast<long long>(connect_attempt_started_ms),
                     static_cast<long long>(now_ms));
            reconnect_stuck_prompt_ = true;
            offline_todo_mode_ = true;
            todo_menu_kind_ = TodoMenuKind::ReconnectStuck;
            todo_menu_selected_item_ = 0;
            todo_menu_open_ = true;
            reconnect_prompt_started_ms = now_ms;
            status_text_ = "重连卡住";
            hint_text_ = "请选择操作";
            phase_ = Phase::Error;
            active_page_ = Page::Todo;
            UpdateDisplay();
        }
        if (ws_disconnected_pending_.exchange(false)) {
            hello_sent_ = false;
            network_state_ = IsWifiConnected() ? NetworkState::Wifi : NetworkState::Offline;
            status_text_ = "连接已断开";
            hint_text_ = "将自动重试";
            phase_ = Phase::Idle;
            if (active_page_ == Page::Todo || offline_todo_mode_) {
                offline_todo_mode_ = true;
                todo_last_action_text_ = "离线待办";
                active_page_ = Page::Todo;
            } else {
                active_page_ = Page::Summary;
            }
            disconnected_since_ms = now_ms;
            reconnect_interval_ms = kReconnectIntervalMinMs;
            last_reconnect_ms = 0;
            last_ws_ping_ms = 0;
            awaiting_pong_since_ms = 0;
            awaiting_pong_baseline_ms = 0;
            todo_boot_short_pending = false;
            last_todo_boot_release_ms = 0;
            UpdateDisplay();
        }
        if ((now_ms - last_battery_poll_ms) >= kBatteryPollIntervalMs) {
            last_battery_poll_ms = now_ms;
            RefreshBatteryStatus();
        }

        // Navigation buttons always work regardless of WiFi state
        if (up_long_pressed_.exchange(false)) {
            if (IsNavButtonPressed(TODO_DOWN_BUTTON_GPIO)) {
                EnterWifiSetupMode();
            } else if (active_page_ == Page::Todo || offline_todo_mode_) {
                OpenTodoMenu(TodoMenuKind::Todo);
            } else if (active_page_ == Page::Summary) {
                OpenTodoMenu(TodoMenuKind::Live);
            } else {
                SwitchPage(Page::Todo);
            }
        }
        if (down_long_pressed_.exchange(false)) {
            if (IsNavButtonPressed(TODO_UP_BUTTON_GPIO)) {
                EnterWifiSetupMode();
            } else if (active_page_ == Page::Log) {
                EnterSettings();
            } else if (active_page_ == Page::Settings) {
                SwitchPage(Page::Todo);
            } else {
                SwitchPage(Page::Log);
            }
        }

        const bool up_double_click = up_double_clicked_.exchange(false);
        const bool down_double_click = down_double_clicked_.exchange(false);
        const bool up_click = up_clicked_.exchange(false) || (todo_menu_open_ && up_double_click);
        const bool down_click = down_clicked_.exchange(false) || down_double_click;

        if (up_double_click &&
            !todo_menu_open_ &&
            !has_pending_transcript_ &&
            (active_page_ == Page::Todo || active_page_ == Page::Summary) &&
            (phase_ == Phase::Idle || phase_ == Phase::Error || phase_ == Phase::Running)) {
            SwitchPage(active_page_ == Page::Todo ? Page::Summary : Page::Todo);
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }

        if (active_page_ == Page::Settings) {
            const bool pressed_now = IsPttPressed();
            const bool boot_press  = pressed_now && !last_pressed;
            if (boot_press) last_pressed = true;
            if (!pressed_now) last_pressed = false;
            HandleSettingsInput(up_click, down_click, boot_press);
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }

        if (todo_menu_open_) {
            if (todo_menu_kind_ == TodoMenuKind::ReconnectStuck &&
                reconnect_prompt_started_ms > 0 &&
                (now_ms - reconnect_prompt_started_ms) >= kReconnectPromptTimeoutMs) {
                reconnect_prompt_started_ms = 0;
                EnterOfflineTodoMode("离线待办");
                vTaskDelay(pdMS_TO_TICKS(10));
                continue;
            }
            const bool pressed_now = IsPttPressed();
            const bool boot_press  = pressed_now && !last_pressed;
            if (boot_press) last_pressed = true;
            if (!pressed_now) last_pressed = false;
            HandleTodoMenuInput(up_click, down_click, boot_press);
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }

        if (!IsWifiConnected()) {
            if (!offline_todo_mode_ &&
                !todo_menu_open_ &&
                !has_pending_transcript_ &&
                phase_ == Phase::Idle &&
                (now_ms - disconnected_since_ms) >= kReconnectPromptTimeoutMs) {
                EnterOfflineTodoMode("离线待办");
                vTaskDelay(pdMS_TO_TICKS(10));
                continue;
            }
            if (offline_todo_mode_ && active_page_ == Page::Todo) {
                if (up_click) {
                    MoveTodoSelection(-1);
                }
                if (down_click) {
                    MoveTodoSelection(1);
                }
                const bool pressed_now = IsPttPressed();
                if (pressed_now && !last_pressed) {
                    last_pressed = true;
                    boot_pressed_since_ms = now_ms;
                    todo_hold_started = false;
                } else if (!pressed_now && last_pressed) {
                    if (!todo_hold_started && boot_pressed_since_ms > 0) {
                        const int64_t elapsed_since_last_release = now_ms - last_todo_boot_release_ms;
                        if (todo_boot_short_pending && elapsed_since_last_release <= kTodoBootDoubleClickWindowMs) {
                            todo_boot_short_pending = false;
                            last_todo_boot_release_ms = 0;
                            DeleteSelectedTodo();
                        } else {
                            todo_boot_short_pending = true;
                            last_todo_boot_release_ms = now_ms;
                        }
                    }
                    boot_pressed_since_ms = 0;
                    todo_hold_started = false;
                    last_pressed = false;
                }
            }
            vTaskDelay(pdMS_TO_TICKS(200));
            continue;
        }

        if (!IsServerConnected() &&
            !connect_attempt_running_.load(std::memory_order_acquire) &&
            !offline_todo_mode_ &&
            (now_ms - last_reconnect_ms) >= reconnect_interval_ms) {
            last_reconnect_ms = now_ms;
            StartConnectAttemptAsync();
        }

        if (IsWifiConnected() &&
            !IsServerConnected() &&
            !connect_attempt_running_.load(std::memory_order_acquire) &&
            !offline_todo_mode_ &&
            !todo_menu_open_ &&
            !has_pending_transcript_ &&
            phase_ == Phase::Idle &&
            (now_ms - disconnected_since_ms) >= kReconnectPromptTimeoutMs) {
            reconnect_stuck_prompt_ = true;
            offline_todo_mode_ = true;
            todo_menu_kind_ = TodoMenuKind::ReconnectStuck;
            todo_menu_selected_item_ = 0;
            todo_menu_open_ = true;
            reconnect_prompt_started_ms = now_ms;
            status_text_ = "无服务器";
            hint_text_ = "请选择操作";
            active_page_ = Page::Todo;
            UpdateDisplay();
        }

        // Time-based sleep: if no connection has been established within
        // kNoConnectionSleepMs, enter deep sleep to save battery.
        if (!IsServerConnected() &&
            !connect_attempt_running_.load(std::memory_order_acquire) &&
            !offline_todo_mode_ &&
            (now_ms - disconnected_since_ms) >= kNoConnectionSleepMs) {
            DisconnectWebSocket();
            status_text_ = "无服务器";
            hint_text_ = "按 BOOT 重试";
            active_page_ = Page::Summary;
            UpdateDisplay();
            vTaskDelay(pdMS_TO_TICKS(800));
            esp_sleep_enable_ext0_wakeup(static_cast<gpio_num_t>(BOOT_BUTTON_GPIO), 0);
            esp_sleep_enable_timer_wakeup(5ULL * 60 * 1000 * 1000);  // 5 minutes
            esp_deep_sleep_start();
        }

        if (IsServerConnected()) {
            if (awaiting_pong_since_ms == 0 && (now_ms - last_ws_ping_ms) >= kClientPingIntervalMs) {
                const int64_t pong_baseline_ms = ws_->GetLastPongMs();
                last_ws_ping_ms = now_ms;
                if (!ws_->Ping()) {
                    ESP_LOGW(kTag, "WebSocket ping send failed; reconnecting");
                    const bool should_stay_offline_todo =
                        active_page_ == Page::Todo || offline_todo_mode_;
                    DisconnectWebSocket();
                    network_state_ = IsWifiConnected() ? NetworkState::Wifi : NetworkState::Offline;
                    status_text_ = "服务器超时";
                    hint_text_ = should_stay_offline_todo ? "离线待办" : "正在重试主机...";
                    phase_ = Phase::Idle;
                    if (should_stay_offline_todo) {
                        EnterOfflineTodoMode("离线待办");
                    } else {
                        active_page_ = Page::Summary;
                    }
                    disconnected_since_ms = now_ms;
                    reconnect_interval_ms = kReconnectIntervalMinMs;
                    last_reconnect_ms = now_ms;
                    last_ws_ping_ms = 0;
                    awaiting_pong_since_ms = 0;
                    awaiting_pong_baseline_ms = 0;
                    if (!should_stay_offline_todo) {
                        StartConnectAttemptAsync();
                    }
                    UpdateDisplay();
                    vTaskDelay(pdMS_TO_TICKS(50));
                    continue;
                }
                awaiting_pong_since_ms = now_ms;
                awaiting_pong_baseline_ms = pong_baseline_ms;
            }
            const int64_t last_pong_ms = ws_->GetLastPongMs();
            if (awaiting_pong_since_ms > 0 && last_pong_ms > awaiting_pong_baseline_ms) {
                awaiting_pong_since_ms = 0;
                awaiting_pong_baseline_ms = 0;
            }
            const bool client_ping_timed_out =
                awaiting_pong_since_ms > 0 && (now_ms - awaiting_pong_since_ms) >= kPongTimeoutMs;
            const bool server_silent_too_long =
                awaiting_pong_since_ms == 0 &&
                last_pong_ms > 0 &&
                (now_ms - last_pong_ms) >= kServerSilenceTimeoutMs;
            if (client_ping_timed_out || server_silent_too_long) {
                ESP_LOGW(kTag,
                         "WebSocket heartbeat timed out: reason=%s last_pong_ms=%lld baseline_ms=%lld ping_ms=%lld now_ms=%lld",
                         client_ping_timed_out ? "client_ping" : "server_silence",
                         static_cast<long long>(last_pong_ms),
                         static_cast<long long>(awaiting_pong_baseline_ms),
                         static_cast<long long>(awaiting_pong_since_ms),
                         static_cast<long long>(now_ms));
                const bool should_stay_offline_todo =
                    active_page_ == Page::Todo || offline_todo_mode_;
                status_text_ = "服务器超时";
                hint_text_ = should_stay_offline_todo ? "离线待办" : "正在重试主机...";
                phase_ = Phase::Idle;
                if (should_stay_offline_todo) {
                    EnterOfflineTodoMode("离线待办");
                } else {
                    DisconnectWebSocket();
                    active_page_ = Page::Summary;
                }
                network_state_ = IsWifiConnected() ? NetworkState::Wifi : NetworkState::Offline;
                disconnected_since_ms = now_ms;
                reconnect_interval_ms = kReconnectIntervalMinMs;
                last_reconnect_ms = now_ms;
                last_ws_ping_ms = 0;
                awaiting_pong_since_ms = 0;
                awaiting_pong_baseline_ms = 0;
                if (!should_stay_offline_todo) {
                    StartConnectAttemptAsync();
                }
                UpdateDisplay();
                vTaskDelay(pdMS_TO_TICKS(50));
                continue;
            }
        }

        const bool selecting_plan =
            active_page_ == Page::Summary &&
            !has_pending_transcript_ &&
            !plan_options_.empty();

        if (up_click) {
            if (has_pending_transcript_) {
                if (IsServerConnected()) {
                    SendAction("action_send");
                } else {
                    disconnected_since_ms = now_ms;
                    reconnect_interval_ms = kReconnectIntervalMinMs;
                    last_reconnect_ms = now_ms;
                    StartConnectAttemptAsync();
                    status_text_ = "连接中";
                    hint_text_ = "正在重试主机...";
                    UpdateDisplay();
                }
            } else if (selecting_plan) {
                if (!SendPlanSelect(-1)) {
                    status_text_ = "方案选择失败";
                    hint_text_ = "检查连接";
                    UpdateDisplay();
                }
            } else if (active_page_ == Page::Todo) {
                MoveTodoSelection(-1);
            } else {
                HandleScroll(-1);
            }
        }
        if (down_click) {
            const bool normal_mode_undo =
                !has_pending_transcript_ &&
                voice_mode_ == VoiceMode::Normal &&
                active_page_ == Page::Summary &&
                (phase_ == Phase::Idle || phase_ == Phase::Running);
            if (has_pending_transcript_ || normal_mode_undo) {
                if (IsServerConnected()) {
                    SendAction("action_undo");
                } else {
                    disconnected_since_ms = now_ms;
                    reconnect_interval_ms = kReconnectIntervalMinMs;
                    last_reconnect_ms = now_ms;
                    StartConnectAttemptAsync();
                    status_text_ = "连接中";
                    hint_text_ = "正在重试主机...";
                    UpdateDisplay();
                }
            } else if (selecting_plan) {
                if (!SendPlanSelect(1)) {
                    status_text_ = "方案选择失败";
                    hint_text_ = "检查连接";
                    UpdateDisplay();
                }
            } else if (active_page_ == Page::Todo) {
                MoveTodoSelection(1);
            } else {
                HandleScroll(1);
            }
        }

        const bool pressed = IsPttPressed();
        if (pressed && !last_pressed) {
            ESP_LOGI(kTag, "BOOT press connected=%d connect_task=%d phase=%d",
                     IsServerConnected() ? 1 : 0,
                     connect_attempt_running_.load(std::memory_order_acquire) ? 1 : 0,
                     static_cast<int>(phase_));
            boot_pressed_since_ms = now_ms;
            todo_hold_started = false;
            const bool selecting_plan =
                active_page_ == Page::Summary &&
                !has_pending_transcript_ &&
                !plan_options_.empty();
            if (selecting_plan) {
                if (!IsServerConnected()) {
                    disconnected_since_ms = now_ms;
                    reconnect_interval_ms = kReconnectIntervalMinMs;
                    last_reconnect_ms = now_ms;
                    StartConnectAttemptAsync();
                    status_text_ = "连接中";
                    hint_text_ = "正在重试主机...";
                    UpdateDisplay();
                } else if (SendPlanApply()) {
                    status_text_ = "正在应用方案";
                    hint_text_ = "等待结果";
                    phase_ = Phase::Running;
                    plan_options_.clear();
                    plan_selected_index_ = -1;
                    summary_scroll_offset_ = 0;
                    UpdateDisplay();
                } else {
                    status_text_ = "方案应用失败";
                    hint_text_ = "检查连接";
                    UpdateDisplay();
                }
                last_pressed = true;
                vTaskDelay(pdMS_TO_TICKS(20));
                continue;
            }
            const bool defer_normal_short_enter_press =
                !has_pending_transcript_ &&
                IsServerConnected() &&
                send_target_ == "text_injector" &&
                voice_mode_ == VoiceMode::Normal &&
                (phase_ == Phase::Idle || phase_ == Phase::Running);
            const bool can_todo_direct_short_action =
                active_page_ == Page::Todo &&
                !has_pending_transcript_ &&
                (phase_ == Phase::Idle || phase_ == Phase::Error || phase_ == Phase::Running);
            const bool defer_page_press =
                defer_normal_short_enter_press ||
                can_todo_direct_short_action;
            if (defer_page_press) {
                last_pressed = true;
                vTaskDelay(pdMS_TO_TICKS(10));
                continue;
            }
            if (!IsServerConnected()) {
                disconnected_since_ms = now_ms;
                reconnect_interval_ms = kReconnectIntervalMinMs;
                last_reconnect_ms = now_ms;
                StartConnectAttemptAsync();
                hint_text_ = "正在重试主机...";
                status_text_ = "连接中";
                phase_ = Phase::Idle;
                UpdateDisplay();
            } else {
                SyncVoiceModeToActivePage();
                ESP_LOGI(kTag, "PTT start");
                SendPttStart();
                phase_ = Phase::Recording;
                status_text_ = "录音中";
                hint_text_ = "松开 BOOT 发送";
                CapturePrerollFrame();
                FlushPrerollFrames();
                StreamAudioFrame();
                UpdateDisplay();
            }
            last_pressed = true;
        }

        if (pressed &&
            last_pressed &&
            (active_page_ == Page::Todo || active_page_ == Page::Summary) &&
            !todo_hold_started &&
            boot_pressed_since_ms > 0 &&
            !has_pending_transcript_ &&
            (phase_ == Phase::Idle || phase_ == Phase::Error || phase_ == Phase::Running) &&
            IsServerConnected() &&
            (now_ms - boot_pressed_since_ms) >= kTodoBootHoldMs) {
            if (!SyncVoiceModeToActivePage()) {
                status_text_ = "模式错误";
                hint_text_ = "请重试";
                UpdateDisplay();
                vTaskDelay(pdMS_TO_TICKS(20));
                continue;
            }
            todo_hold_started = true;
            ESP_LOGI(kTag, "PTT start from page hold");
            SendPttStart();
            phase_ = Phase::Recording;
            status_text_ = "录音中";
            hint_text_ = "松开 BOOT 发送";
            CapturePrerollFrame();
            FlushPrerollFrames();
            StreamAudioFrame();
            UpdateDisplay();
        }

        if (!pressed && last_pressed) {
            ESP_LOGI(kTag, "BOOT release phase=%d", static_cast<int>(phase_));
            if (phase_ == Phase::Recording) {
                ESP_LOGI(kTag, "PTT stop");
                SendPttStop();
                phase_ = Phase::Transcribing;
                status_text_ = "转写中";
                UpdateDisplay();
            } else if (!todo_hold_started &&
                       boot_pressed_since_ms > 0 &&
                       !has_pending_transcript_ &&
                       (phase_ == Phase::Idle || phase_ == Phase::Running) &&
                       IsServerConnected() &&
                       send_target_ == "text_injector" &&
                       voice_mode_ == VoiceMode::Normal) {
                if (SendEnter()) {
                    status_text_ = "已发送回车";
                    hint_text_ = "短按 BOOT 回车";
                    phase_ = Phase::Idle;
                } else {
                    status_text_ = "回车失败";
                    hint_text_ = "检查连接";
                    phase_ = Phase::Error;
                }
                UpdateDisplay();
            } else if (active_page_ == Page::Todo &&
                       !todo_hold_started &&
                       boot_pressed_since_ms > 0 &&
                       !has_pending_transcript_) {
                const int64_t elapsed_since_last_release = now_ms - last_todo_boot_release_ms;
                if (todo_boot_short_pending && elapsed_since_last_release <= kTodoBootDoubleClickWindowMs) {
                    todo_boot_short_pending = false;
                    last_todo_boot_release_ms = 0;
                    DeleteSelectedTodo();
                } else {
                    todo_boot_short_pending = true;
                    last_todo_boot_release_ms = now_ms;
                }
            }
            boot_pressed_since_ms = 0;
            todo_hold_started = false;
            last_pressed = false;
            vTaskDelay(pdMS_TO_TICKS(20));
            continue;
        }

        if (pressed) {
            if (phase_ == Phase::Recording) {
                StreamAudioFrame();
                continue;
            }

            if (IsServerConnected() &&
                !has_pending_transcript_ &&
                (active_page_ == Page::Todo || active_page_ == Page::Summary)) {
                CapturePrerollFrame();
                vTaskDelay(pdMS_TO_TICKS(1));
            } else {
                vTaskDelay(pdMS_TO_TICKS(10));
            }
            continue;
        }

        CapturePrerollFrame();
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}
