#include "app_ota.h"

#include <esp_app_desc.h>
#include <esp_http_client.h>
#include <esp_log.h>
#include <esp_ota_ops.h>
#include <esp_system.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <mbedtls/sha256.h>

#include <atomic>
#include <cctype>
#include <memory>
#include <vector>

namespace {

constexpr char kTag[] = "AppOta";
constexpr size_t kHttpBufferSize = 4096;
constexpr uint32_t kOtaTaskStackSize = 8 * 1024;
constexpr UBaseType_t kOtaTaskPriority = 3;

std::atomic<bool> g_running{false};

struct OtaTaskContext {
    FirmwareOtaOffer offer;
    FirmwareOtaProgressFn progress;
};

bool HexToSha256(const std::string& hex, uint8_t out[32]) {
    if (hex.size() != 64) {
        return false;
    }
    auto nibble = [](char ch) -> int {
        if (ch >= '0' && ch <= '9') return ch - '0';
        if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
        if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
        return -1;
    };
    for (size_t i = 0; i < 32; ++i) {
        const int hi = nibble(hex[i * 2]);
        const int lo = nibble(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) {
            return false;
        }
        out[i] = static_cast<uint8_t>((hi << 4) | lo);
    }
    return true;
}

void Report(FirmwareOtaProgressFn& progress, const char* phase, int pct, const char* error) {
    if (progress) {
        progress(phase, pct, error);
    }
}

void OtaTaskEntry(void* param) {
    std::unique_ptr<OtaTaskContext> ctx(static_cast<OtaTaskContext*>(param));
    FirmwareOtaProgressFn progress = ctx->progress;
    const FirmwareOtaOffer offer = ctx->offer;
    ctx.reset();

    uint8_t expected_sha[32] = {};
    if (!offer.sha256_hex.empty() && !HexToSha256(offer.sha256_hex, expected_sha)) {
        Report(progress, "verify", 0, "invalid_sha256");
        Report(progress, "result", 0, "invalid_sha256");
        g_running.store(false);
        vTaskDelete(nullptr);
        return;
    }

    const esp_partition_t* update_partition = esp_ota_get_next_update_partition(nullptr);
    if (update_partition == nullptr) {
        Report(progress, "flash", 0, "no_ota_partition");
        Report(progress, "result", 0, "no_ota_partition");
        g_running.store(false);
        vTaskDelete(nullptr);
        return;
    }

    esp_http_client_config_t http_cfg = {};
    http_cfg.url = offer.url.c_str();
    http_cfg.timeout_ms = 30000;
    http_cfg.keep_alive_enable = true;
    esp_http_client_handle_t client = esp_http_client_init(&http_cfg);
    if (client == nullptr) {
        Report(progress, "download", 0, "http_init_failed");
        Report(progress, "result", 0, "http_init_failed");
        g_running.store(false);
        vTaskDelete(nullptr);
        return;
    }

    esp_err_t err = esp_http_client_open(client, 0);
    if (err != ESP_OK) {
        ESP_LOGE(kTag, "HTTP open failed: %s", esp_err_to_name(err));
        esp_http_client_cleanup(client);
        Report(progress, "download", 0, "http_open_failed");
        Report(progress, "result", 0, "http_open_failed");
        g_running.store(false);
        vTaskDelete(nullptr);
        return;
    }

    const int content_length = esp_http_client_fetch_headers(client);
    int64_t total_bytes = content_length > 0 ? content_length : static_cast<int64_t>(offer.size);
    if (offer.size > 0) {
        total_bytes = static_cast<int64_t>(offer.size);
    }

    esp_ota_handle_t ota_handle = 0;
    err = esp_ota_begin(update_partition, OTA_WITH_SEQUENTIAL_WRITES, &ota_handle);
    if (err != ESP_OK) {
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        Report(progress, "flash", 0, "ota_begin_failed");
        Report(progress, "result", 0, "ota_begin_failed");
        g_running.store(false);
        vTaskDelete(nullptr);
        return;
    }

    mbedtls_sha256_context sha_ctx;
    mbedtls_sha256_init(&sha_ctx);
    mbedtls_sha256_starts(&sha_ctx, 0);

    std::vector<char> buffer(kHttpBufferSize);
    int64_t downloaded = 0;
    int last_pct = -1;
    Report(progress, "download", 0, nullptr);

    while (true) {
        const int read_len = esp_http_client_read(client, buffer.data(), buffer.size());
        if (read_len < 0) {
            err = ESP_FAIL;
            break;
        }
        if (read_len == 0) {
            break;
        }
        err = esp_ota_write(ota_handle, buffer.data(), read_len);
        if (err != ESP_OK) {
            break;
        }
        mbedtls_sha256_update(&sha_ctx, reinterpret_cast<const unsigned char*>(buffer.data()), read_len);
        downloaded += read_len;
        if (total_bytes > 0) {
            const int pct = static_cast<int>((downloaded * 100) / total_bytes);
            if (pct != last_pct) {
                last_pct = pct;
                Report(progress, "download", pct, nullptr);
            }
        }
    }

    esp_http_client_close(client);
    esp_http_client_cleanup(client);

    if (err != ESP_OK) {
        esp_ota_abort(ota_handle);
        mbedtls_sha256_free(&sha_ctx);
        Report(progress, "download", last_pct, "download_failed");
        Report(progress, "result", 0, "download_failed");
        g_running.store(false);
        vTaskDelete(nullptr);
        return;
    }

    Report(progress, "verify", 0, nullptr);
    if (!offer.sha256_hex.empty()) {
        uint8_t actual_sha[32] = {};
        mbedtls_sha256_finish(&sha_ctx, actual_sha);
        mbedtls_sha256_free(&sha_ctx);
        if (memcmp(actual_sha, expected_sha, sizeof(actual_sha)) != 0) {
            esp_ota_abort(ota_handle);
            Report(progress, "verify", 0, "sha256_mismatch");
            Report(progress, "result", 0, "sha256_mismatch");
            g_running.store(false);
            vTaskDelete(nullptr);
            return;
        }
    } else {
        mbedtls_sha256_free(&sha_ctx);
    }

    Report(progress, "flash", 100, nullptr);
    err = esp_ota_end(ota_handle);
    if (err != ESP_OK) {
        Report(progress, "flash", 0, "ota_end_failed");
        Report(progress, "result", 0, "ota_end_failed");
        g_running.store(false);
        vTaskDelete(nullptr);
        return;
    }

    err = esp_ota_set_boot_partition(update_partition);
    if (err != ESP_OK) {
        Report(progress, "flash", 0, "set_boot_failed");
        Report(progress, "result", 0, "set_boot_failed");
        g_running.store(false);
        vTaskDelete(nullptr);
        return;
    }

    const char* version = offer.version.empty()
                              ? esp_app_get_description()->version
                              : offer.version.c_str();
    Report(progress, "reboot", 100, nullptr);
    Report(progress, "result", 100, nullptr);
    ESP_LOGI(kTag, "OTA complete, rebooting to version %s", version);
    vTaskDelay(pdMS_TO_TICKS(500));
    esp_restart();
}

} // namespace

bool StartFirmwareOta(const FirmwareOtaOffer& offer, FirmwareOtaProgressFn progress) {
    if (offer.url.empty()) {
        return false;
    }
    bool expected = false;
    if (!g_running.compare_exchange_strong(expected, true)) {
        return false;
    }

    auto* ctx = new OtaTaskContext{offer, std::move(progress)};
    if (xTaskCreate(&OtaTaskEntry, "lan_fw_ota", kOtaTaskStackSize, ctx, kOtaTaskPriority, nullptr) != pdPASS) {
        delete ctx;
        g_running.store(false);
        return false;
    }
    return true;
}

bool IsFirmwareOtaRunning() {
    return g_running.load();
}
