#include "lan_mic_app.h"
#include "lan_mic_app_internal.h"
#include "protocol_messages.h"

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

void LanMicApp::LoadPersistedNetworkState() {
    Settings nvs(kLanMicNamespace);
    volume_ = nvs.GetInt(kVolumeKey, 70);
    cached_server_uri_ = nvs.GetString(kLastServerUriKey, "");
    paired_host_id_ = nvs.GetString(kPairedHostIdKey, "");
    paired_host_name_ = nvs.GetString(kPairedHostNameKey, "");

    if (paired_host_id_.empty()) {
        paired_host_id_ = kDefaultHostId;
    }

    if (!paired_host_id_.empty()) {
        ESP_LOGI(kLanMicTag, "Loaded paired host: id=%s name=%s",
                 paired_host_id_.c_str(),
                 paired_host_name_.empty() ? "(unknown)" : paired_host_name_.c_str());
    }
    if (!cached_server_uri_.empty()) {
        ESP_LOGI(kLanMicTag, "Loaded cached server URI: %s", cached_server_uri_.c_str());
        if (cached_server_uri_.find(".local") != std::string::npos) {
            ESP_LOGW(kLanMicTag, "Discarding mDNS cached server URI; discovery will refresh IP: %s",
                     cached_server_uri_.c_str());
            ClearCachedServerUri();
        }
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
    ESP_LOGI(kLanMicTag, "Cached server URI: %s", cached_server_uri_.c_str());
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
    ESP_LOGI(kLanMicTag, "Paired host saved: id=%s name=%s",
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

    ESP_LOGI(kLanMicTag, "Cleared cached host pairing and server URI");
}

void LanMicApp::ClearCachedServerUri() {
    if (cached_server_uri_.empty()) {
        return;
    }

    Settings nvs(kLanMicNamespace, true);
    nvs.EraseKey(kLastServerUriKey);
    ESP_LOGW(kLanMicTag, "Cleared stale cached server URI: %s", cached_server_uri_.c_str());
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

void LanMicApp::UpdateNfcPairingUri(const std::string& pairing_code) {
    if (pairing_code.empty()) {
        return;
    }
    std::string uri = "vibe://pair?code=" + pairing_code;
    if (!paired_host_id_.empty()) {
        uri += "&hostId=" + paired_host_id_;
    }
    WriteNfcUriIfNeeded(uri, "pairing_mode");
}

std::string LanMicApp::GetSharedSecret() const {
    Settings nvs(kLanMicNamespace);
    const std::string stored = nvs.GetString(kLanSharedSecretKey, "");
    if (!stored.empty()) {
        return stored;
    }
    if (std::strlen(CONFIG_LAN_SHARED_SECRET) > 0) {
        return std::string(CONFIG_LAN_SHARED_SECRET);
    }
    return "";
}

void LanMicApp::SaveSharedSecret(const std::string& secret) {
    if (secret.empty()) {
        return;
    }
    Settings nvs(kLanMicNamespace, true);
    nvs.SetString(kLanSharedSecretKey, secret);
    ESP_LOGI(kLanMicTag, "Saved LAN shared secret to NVS");
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
        ESP_LOGW(kLanMicTag, "NFC power on failed before write: reason=%s", reason != nullptr ? reason : "unknown");
        return;
    }

    const esp_err_t ret = nfc->WriteUriNdef(uri);
    if (ret != ESP_OK) {
        ESP_LOGW(kLanMicTag,
                 "NFC write uri failed: reason=%s ret=%s uri=%s",
                 reason != nullptr ? reason : "unknown",
                 esp_err_to_name(ret),
                 uri.c_str());
        return;
    }

    nfc_last_uri_ = uri;
    ESP_LOGI(kLanMicTag,
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

    ESP_LOGI(kLanMicTag, "Request reconfigure WiFi by reboot");
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
            self->connect_task_handle_.store(nullptr, std::memory_order_release);
            self->connect_attempt_started_ms_.store(0, std::memory_order_release);
            self->connect_attempt_running_.store(false, std::memory_order_release);
            self->connect_attempt_completed_.store(true, std::memory_order_release);
            vTaskDelete(nullptr);
        },
        "lan_reconnect",
        kConnectTaskStackSize,
        this,
        kConnectTaskPriority,
        nullptr) != pdPASS) {
        connect_task_handle_.store(nullptr, std::memory_order_release);
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

    if (connect_cancel_requested_.load(std::memory_order_acquire)) {
        return false;
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

    if (connect_cancel_requested_.load(std::memory_order_acquire)) {
        return false;
    }

    NetworkInterface* network = board_.GetNetwork();
    if (network == nullptr) {
        ESP_LOGE(kLanMicTag, "Network interface is null");
        return false;
    }

    const std::string target_uri_text = target_uri;
    ESP_LOGI(kLanMicTag, "Connecting via %s: %s", target_source, target_uri_text.c_str());

    ws_ = network->CreateWebSocket(0);
    ws_->OnConnected([this, target_uri_text]() {
        ESP_LOGI(kLanMicTag, "WebSocket connected");
        pending_connect_uri_ = target_uri_text;
        ws_connected_pending_.store(true, std::memory_order_release);
    });
    ws_->OnDisconnected([this]() {
        ESP_LOGW(kLanMicTag, "WebSocket disconnected");
        ws_disconnected_pending_.store(true, std::memory_order_release);
    });
    ws_->OnError([this](int error) {
        ESP_LOGW(kLanMicTag, "WebSocket error=%d", error);
        ws_error_code_.store(error, std::memory_order_release);
        ws_error_pending_.store(true, std::memory_order_release);
    });
    ws_->OnData([this](const char* data, size_t len, bool binary) {
        if (!binary && data != nullptr && len > 0) {
            EnqueueServerMessage(data, len);
        }
    });

    if (connect_cancel_requested_.load(std::memory_order_acquire)) {
        ws_.reset();
        hello_sent_ = false;
        return false;
    }

    if (!ws_->Connect(target_uri)) {
        ESP_LOGW(kLanMicTag, "WebSocket connect failed: %s", target_uri);
        ws_.reset();
        hello_sent_ = false;
        if (std::strcmp(target_source, "discovery") == 0) {
            ESP_LOGW(kLanMicTag, "Discovered URI failed, forcing discovery next round");
            server_uri_.clear();
        } else if (std::strcmp(target_source, "cache") == 0) {
            ESP_LOGW(kLanMicTag, "Cache connect failed; clearing stale cache and forcing discovery");
            ClearCachedServerUri();
        }
        status_text_ = "连接失败";
        hint_text_ = target_uri;
        UpdateDisplay();
        return false;
    }

    hello_sent_ = false;
    auth_server_nonce_.clear();
    auth_challenge_received_ = false;
    return true;
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
        cJSON_AddStringToObject(request, "type", LAN_MSG_DEVICE_DISCOVER_HOST);
        cJSON_AddStringToObject(request, "service", kDiscoveryService);
        cJSON_AddStringToObject(request, "deviceId", board_.GetUuid().c_str());
        cJSON_AddStringToObject(request, "boardType", board_.GetBoardType().c_str());
        cJSON_AddStringToObject(request, "nonce", nonce.c_str());
        cJSON_AddStringToObject(request, "expectedHostId", requested_host_id.c_str());

        char* request_text = cJSON_PrintUnformatted(request);
        cJSON_Delete(request);
        if (request_text == nullptr) {
            return false;
        }

        for (int attempt = 0; attempt < kDiscoveryAttempts; ++attempt) {
            int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
            if (sock < 0) {
                ESP_LOGW(kLanMicTag, "Discovery socket create failed: errno=%d", errno);
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
                ESP_LOGW(kLanMicTag, "Discovery bind failed: errno=%d", errno);
                close(sock);
                continue;
            }

            struct sockaddr_in broadcast_addr = {};
            broadcast_addr.sin_family = AF_INET;
            broadcast_addr.sin_port = htons(CONFIG_LAN_DISCOVERY_PORT);
            broadcast_addr.sin_addr.s_addr = inet_addr("255.255.255.255");

            ESP_LOGI(kLanMicTag,
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
                ESP_LOGW(kLanMicTag, "Discovery broadcast failed: errno=%d", errno);
                close(sock);
                continue;
            }

            // Set non-blocking mode — ESP32/lwIP's SO_RCVTIMEO does not
            // reliably wake recvfrom(), so we use select() instead.
            int flags = fcntl(sock, F_GETFL, 0);
            fcntl(sock, F_SETFL, flags | O_NONBLOCK);

            const int64_t deadline_us = esp_timer_get_time() + (kDiscoveryTimeoutMs * 1000LL);
            while (esp_timer_get_time() < deadline_us) {
                const int64_t remaining_us = deadline_us - esp_timer_get_time();
                if (remaining_us <= 0) {
                    break;
                }

                fd_set read_fds;
                FD_ZERO(&read_fds);
                FD_SET(sock, &read_fds);
                struct timeval select_timeout = {};
                select_timeout.tv_sec = remaining_us / 1000000;
                select_timeout.tv_usec = remaining_us % 1000000;
                const int select_result = select(sock + 1, &read_fds, nullptr, nullptr, &select_timeout);
                if (select_result <= 0) {
                    continue;
                }

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
                    if (errno == EAGAIN || errno == EWOULDBLOCK) {
                        continue;
                    }
                    break;
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

                const bool type_ok = type != nullptr && strcmp(type, LAN_MSG_SERVER_DISCOVER_REPLY) == 0;
                const bool service_ok = service == nullptr || strcmp(service, kDiscoveryService) == 0;
                const bool host_ok = requested_host_id.empty() ||
                                     (host_id != nullptr && requested_host_id == host_id);
                bool auth_ok = true;
                if (!GetSharedSecret().empty()) {
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
                    ESP_LOGI(kLanMicTag, "Discovered host: %s (%s)", server_uri_.c_str(), hint_text_.c_str());
                    cJSON_Delete(response);
                    close(sock);
                    cJSON_free(request_text);
                    return true;
                }

                if (type_ok && service_ok && ws_url != nullptr && ws_url[0] != '\0' && !host_ok) {
                    ESP_LOGW(kLanMicTag,
                             "Discovery reply ignored by host filter: expected=%s got=%s",
                             requested_host_id.c_str(),
                             host_id != nullptr ? host_id : "(none)");
                } else if (type_ok && service_ok && host_ok && !auth_ok) {
                    ESP_LOGW(kLanMicTag, "Discovery reply auth failed for host=%s", host_id != nullptr ? host_id : "(none)");
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
        ESP_LOGW(kLanMicTag,
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
    const std::string secret = GetSharedSecret();
    if (secret.empty()) {
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
        reinterpret_cast<const unsigned char*>(secret.data()),
        secret.size(),
        reinterpret_cast<const unsigned char*>(payload.data()),
        payload.size(),
        digest);
    if (ret != 0) {
        ESP_LOGW(kLanMicTag, "HMAC failed: %d", ret);
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
    if (!paired_host_id_.empty()) {
        return "正在查找客户端...";
    }
    return "正在发现主机...";
}

void LanMicApp::EnterWifiSetupMode() {
    ESP_LOGW(kLanMicTag, "Clearing saved Wi-Fi and scheduling reboot into config mode");
    ClearPersistedHost();
    DisconnectWebSocket();
    xEventGroupClearBits(wifi_event_group_, kWifiConnectedBit);
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

void LanMicApp::RecoverWifiForReconnect(const char* reason) {
    ESP_LOGW(kLanMicTag, "WiFi recovery triggered: %s", reason ? reason : "unknown");
    // Cancel any in-flight connect attempt
    if (connect_attempt_running_.load(std::memory_order_acquire)) {
        connect_cancel_requested_.store(true, std::memory_order_release);
        // Wait briefly for the connect task to notice the cancel
        for (int i = 0; i < 20 && connect_attempt_running_.load(std::memory_order_acquire); ++i) {
            vTaskDelay(pdMS_TO_TICKS(50));
        }
    }
    DisconnectWebSocket();
    server_uri_.clear();
    last_wifi_recovery_ms_ = esp_timer_get_time() / 1000;

    // Reset WiFi: disconnect, clear IP cache, reconnect
    esp_wifi_disconnect();
    vTaskDelay(pdMS_TO_TICKS(200));
    esp_netif_t* netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    if (netif != nullptr) {
        esp_netif_dhcpc_stop(netif);
        esp_netif_dhcpc_start(netif);
    }
    esp_wifi_connect();

    network_state_ = NetworkState::Offline;
    status_text_ = "重置 WiFi";
    hint_text_ = reason ? reason : "正在恢复连接...";
    phase_ = Phase::Idle;
    if (active_page_ != Page::Todo || !offline_todo_mode_) {
        active_page_ = Page::Summary;
    }
    UpdateDisplay();
}

void LanMicApp::EnterOfflineDeepSleep() {
    ESP_LOGI(kLanMicTag, "Entering offline deep sleep after prolonged disconnection");
    DisconnectWebSocket();
    board_.SetPowerSaveLevel(PowerSaveLevel::LOW_POWER);

    // Persist any pending offline todo state before sleeping
    if (offline_todo_mode_) {
        const int64_t now_ms = esp_timer_get_time() / 1000;
        FlushCachedTodoStateIfNeeded(now_ms, true);
        SavePendingTodoOps();
    }

    // Wake sources: BOOT button + 15-minute timer
    esp_sleep_enable_ext0_wakeup(static_cast<gpio_num_t>(BOOT_BUTTON_GPIO), 0);
    esp_sleep_enable_timer_wakeup(static_cast<uint64_t>(kOfflineSleepRetryIntervalUs));

    status_text_ = "省电休眠";
    hint_text_ = "按 BOOT 或等 15 分钟唤醒";
    UpdateDisplay();
    vTaskDelay(pdMS_TO_TICKS(500));  // Let display update before sleeping

    esp_deep_sleep_start();
}

bool LanMicApp::IsPttPressed() const {
    return gpio_get_level(BOOT_BUTTON_GPIO) == 0;
}

bool LanMicApp::IsNavButtonPressed(gpio_num_t gpio_num) const {
    return gpio_get_level(gpio_num) == 0;
}
