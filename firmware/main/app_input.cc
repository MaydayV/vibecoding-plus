#include "lan_mic_app.h"
#include "lan_mic_app_internal.h"
#include "app_ota.h"
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

void LanMicApp::ConfigureButtons() {
    gpio_config_t cfg = {};
    cfg.pin_bit_mask = 1ULL << BOOT_BUTTON_GPIO;
    cfg.mode = GPIO_MODE_INPUT;
    cfg.pull_up_en = GPIO_PULLUP_ENABLE;
    cfg.pull_down_en = GPIO_PULLDOWN_DISABLE;
    cfg.intr_type = GPIO_INTR_DISABLE;
    ESP_ERROR_CHECK(gpio_config(&cfg));
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
        ESP_LOGW(kLanMicTag, "Ignoring corrupt cached todo state");
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

    todo_nvs_last_written_snapshot_ = serialized;
    todo_nvs_pending_snapshot_.clear();
    todo_nvs_dirty_ = false;

    ESP_LOGI(kLanMicTag, "Loaded %u cached todo items",
             static_cast<unsigned>(todo_items_.size()));
    cJSON_Delete(root);
}

std::string LanMicApp::BuildCachedTodoStateJson() const {
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
    std::string serialized;
    if (text != nullptr) {
        serialized = text;
        cJSON_free(text);
    }
    cJSON_Delete(root);
    return serialized;
}

void LanMicApp::SaveCachedTodoState() {
    const std::string serialized = BuildCachedTodoStateJson();
    if (serialized.empty()) {
        return;
    }
    if (serialized == todo_nvs_last_written_snapshot_) {
        todo_nvs_dirty_ = false;
        todo_nvs_pending_snapshot_.clear();
        return;
    }
    todo_nvs_pending_snapshot_ = serialized;
    todo_nvs_dirty_ = true;
    todo_nvs_dirty_since_ms_ = esp_timer_get_time() / 1000;
}

void LanMicApp::FlushCachedTodoStateIfNeeded(int64_t now_ms, bool force) {
    if (!todo_nvs_dirty_) {
        return;
    }
    if (!force && (now_ms - todo_nvs_dirty_since_ms_) < kTodoNvsDebounceMs) {
        return;
    }

    const std::string& serialized = todo_nvs_pending_snapshot_;
    if (serialized.empty() || serialized == todo_nvs_last_written_snapshot_) {
        todo_nvs_dirty_ = false;
        return;
    }

    const size_t length = serialized.size();
    Settings nvs(kLanMicNamespace, true);
    if (length <= kCachedTodoStateMaxBytes) {
        nvs.SetString(kCachedTodoStateKey, serialized);
        todo_nvs_last_written_snapshot_ = serialized;
    } else {
        ESP_LOGW(kLanMicTag,
                 "Cached todo state too large (%u bytes), not saving",
                 static_cast<unsigned>(length));
        nvs.EraseKey(kCachedTodoStateKey);
        todo_nvs_last_written_snapshot_.clear();
    }
    todo_nvs_dirty_ = false;
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
        ESP_LOGW(kLanMicTag, "Ignoring corrupt pending todo ops");
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
        ESP_LOGI(kLanMicTag, "Loaded %u pending todo ops",
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

    if (connect_attempt_running) {
        connect_cancel_requested_.store(true, std::memory_order_release);
        manual_reconnect_requested_.store(true, std::memory_order_release);
        server_uri_.clear();
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
void LanMicApp::Run() {
    if (!Initialize()) {
        ESP_LOGE(kLanMicTag, "Initialization failed");
        while (true) {
            vTaskDelay(pdMS_TO_TICKS(1000));
        }
    }

    bool last_pressed = false;
    int64_t boot_pressed_since_ms = 0;
    bool todo_hold_started = false;
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
        DrainPendingEvents(now_ms);
        FlushCachedTodoStateIfNeeded(now_ms);
        const bool allow_up_mode_double =
            !todo_menu_open_ &&
            !has_pending_transcript_ &&
            (active_page_ == Page::Todo || active_page_ == Page::Summary) &&
            (phase_ == Phase::Idle || phase_ == Phase::Error || phase_ == Phase::Running);
        const int64_t up_double_window_ms = allow_up_mode_double ? kNavDoubleClickWindowMs : 0;
        up_nav_driver_.Poll(now_ms, up_double_window_ms);
        down_nav_driver_.Poll(now_ms, 0);
        const GpioInputEvents up_events = up_nav_driver_.ConsumeEvents();
        const GpioInputEvents down_events = down_nav_driver_.ConsumeEvents();

        if (todo_boot_tap_.pending() &&
            (todo_menu_open_ ||
             has_pending_transcript_ ||
             phase_ == Phase::Recording ||
             phase_ == Phase::Transcribing ||
             active_page_ != Page::Todo)) {
            todo_boot_tap_.Cancel();
        }
        if (todo_boot_tap_.PollSingleReady(now_ms, IsPttPressed())) {
            const bool can_toggle_selected_todo =
                active_page_ == Page::Todo &&
                !todo_menu_open_ &&
                !has_pending_transcript_ &&
                (phase_ == Phase::Idle || phase_ == Phase::Running || phase_ == Phase::Error);
            if (can_toggle_selected_todo) {
                ToggleSelectedTodo();
            }
        }
        if (injector_boot_tap_.pending() &&
            (phase_ == Phase::Recording ||
             phase_ == Phase::Transcribing ||
             has_pending_transcript_ ||
             !IsServerConnected() ||
             send_target_ != "text_injector" ||
             voice_mode_ != VoiceMode::Normal)) {
            injector_boot_tap_.Cancel();
        }
        if (injector_boot_tap_.PollSingleReady(now_ms, IsPttPressed())) {
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
        }
        if (connect_attempt_completed_.exchange(false, std::memory_order_acq_rel)) {
            reconnect_stuck_prompt_ = false;
            if (IsServerConnected()) {
                reconnect_interval_ms = kReconnectIntervalMinMs;
                reconnect_failure_count_ = 0;
                disconnected_since_ms = now_ms;
                last_ws_ping_ms = 0;
                awaiting_pong_since_ms = 0;
                awaiting_pong_baseline_ms = 0;
            } else if (server_uri_.empty() && cached_server_uri_.empty() && GetFallbackServerUri().empty()) {
                reconnect_interval_ms = kReconnectIntervalMinMs;
            } else {
                reconnect_interval_ms = std::min(reconnect_interval_ms * 2, kReconnectIntervalMaxMs);
                reconnect_failure_count_++;
                // After N consecutive failures, try WiFi recovery
                if (reconnect_failure_count_ >= kReconnectFailuresBeforeWifiRecovery &&
                    (now_ms - last_wifi_recovery_ms_) >= kWifiRecoveryCooldownMs) {
                    RecoverWifiForReconnect("连续重连失败");
                    reconnect_interval_ms = kReconnectIntervalMinMs;
                    last_reconnect_ms = now_ms;
                }
            }
        }
        const int64_t connect_attempt_started_ms =
            connect_attempt_started_ms_.load(std::memory_order_acquire);
        if (connect_attempt_running_.load(std::memory_order_acquire) &&
            connect_attempt_started_ms > 0 &&
            (now_ms - connect_attempt_started_ms) >= kConnectAttemptWatchdogMs &&
            !reconnect_stuck_prompt_) {
            ESP_LOGE(kLanMicTag,
                     "Connect attempt watchdog fired: started_ms=%lld now_ms=%lld",
                     static_cast<long long>(connect_attempt_started_ms),
                     static_cast<long long>(now_ms));
            // Try WiFi recovery first before showing stuck prompt
            if ((now_ms - last_wifi_recovery_ms_) >= kWifiRecoveryCooldownMs) {
                RecoverWifiForReconnect("连接看门狗");
                reconnect_interval_ms = kReconnectIntervalMinMs;
                last_reconnect_ms = now_ms;
            } else {
                // WiFi recovery was recent; show manual stuck prompt
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
        }
        if (ws_disconnected_pending_.exchange(false)) {
            hello_sent_ = false;
            network_state_ = IsWifiConnected() ? NetworkState::Wifi : NetworkState::Offline;
            status_text_ = "连接已断开";
            hint_text_ = "将自动重试";
            if (!cached_server_uri_.empty()) {
                RefreshNfcForOfflineSetup(cached_server_uri_);
            }
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
            reconnect_failure_count_ = 0;
            last_reconnect_ms = 0;
            last_ws_ping_ms = 0;
            awaiting_pong_since_ms = 0;
            awaiting_pong_baseline_ms = 0;
            todo_boot_tap_.Cancel();
            injector_boot_tap_.Cancel();
            UpdateDisplay();
        }
        if ((now_ms - last_battery_poll_ms) >= kBatteryPollIntervalMs) {
            last_battery_poll_ms = now_ms;
            RefreshBatteryStatus();
        }

        // Navigation buttons always work regardless of WiFi state
        if (up_events.long_press) {
            if (down_nav_driver_.IsPressed()) {
                EnterWifiSetupMode();
            } else if (active_page_ == Page::Todo || offline_todo_mode_) {
                OpenTodoMenu(TodoMenuKind::Todo);
            } else if (active_page_ == Page::Summary) {
                OpenTodoMenu(TodoMenuKind::Live);
            } else {
                SwitchPage(Page::Todo);
            }
        }
        if (down_events.long_press) {
            if (up_nav_driver_.IsPressed()) {
                EnterWifiSetupMode();
            } else if (active_page_ == Page::Log) {
                EnterSettings();
            } else if (active_page_ == Page::Settings) {
                SwitchPage(Page::Todo);
            } else {
                SwitchPage(Page::Log);
            }
        }

        const bool up_double_click = up_events.double_click;
        const bool down_double_click = down_events.double_click;
        const bool up_click = up_events.click || (todo_menu_open_ && up_double_click);
        const bool down_click = down_events.click || down_double_click;
        if (up_click || down_click || up_double_click || down_double_click) {
            TouchUserInput(now_ms);
        }

        if (up_double_click &&
            !has_pending_transcript_ &&
            (active_page_ == Page::Todo || active_page_ == Page::Summary) &&
            (phase_ == Phase::Idle || phase_ == Phase::Error || phase_ == Phase::Running)) {
            if (todo_menu_open_) {
                todo_menu_open_ = false;
            }
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
                        if (todo_boot_tap_.OnShortRelease(now_ms) ==
                            DeferredTapTracker::ReleaseResult::DoubleTap) {
                            DeleteSelectedTodo();
                        }
                    }
                    boot_pressed_since_ms = 0;
                    todo_hold_started = false;
                    last_pressed = false;
                }
            }
            // Deep sleep after prolonged disconnection to preserve battery
            const int64_t idle_anchor_ms = std::max(disconnected_since_ms, last_user_input_ms_);
            if (!todo_menu_open_ &&
                !has_pending_transcript_ &&
                (now_ms - idle_anchor_ms) >= kNoConnectionSleepMs) {
                EnterOfflineDeepSleep();
                // Never reaches here — deep sleep does not return
            }
            vTaskDelay(pdMS_TO_TICKS(50));
            continue;
        }

        if (!IsServerConnected() &&
            !connect_attempt_running_.load(std::memory_order_acquire) &&
            (now_ms - last_reconnect_ms) >= reconnect_interval_ms) {
            // Ensure WiFi is not in deep power-save so discovery broadcasts
            // can actually be sent and received.
            board_.SetPowerSaveLevel(PowerSaveLevel::BALANCED);
            last_reconnect_ms = now_ms;
            StartConnectAttemptAsync();
        }

        // Deep sleep for WiFi-connected-but-server-unreachable after prolonged disconnection
        const int64_t server_idle_anchor_ms = std::max(disconnected_since_ms, last_user_input_ms_);
        if (IsWifiConnected() &&
            !IsServerConnected() &&
            !connect_attempt_running_.load(std::memory_order_acquire) &&
            !todo_menu_open_ &&
            !has_pending_transcript_ &&
            (now_ms - server_idle_anchor_ms) >= kNoConnectionSleepMs) {
            EnterOfflineDeepSleep();
            // Never reaches here
        }

        if (IsWifiConnected() &&
            !IsServerConnected() &&
            !connect_attempt_running_.load(std::memory_order_acquire) &&
            !offline_todo_mode_ &&
            !todo_menu_open_ &&
            !has_pending_transcript_ &&
            phase_ == Phase::Idle &&
            (now_ms - disconnected_since_ms) >= kReconnectPromptTimeoutMs) {
            // Enter offline todo mode silently — do NOT open the menu,
            // so the main loop continues to reach the reconnect trigger
            // and keeps retrying in the background.
            offline_todo_mode_ = true;
            status_text_ = "重连中";
            hint_text_ = "正在自动重试主机...";
            network_state_ = IsWifiConnected() ? NetworkState::Wifi : NetworkState::Offline;
            UpdateDisplay();
        }

        if (IsServerConnected()) {
            if (awaiting_pong_since_ms == 0 && (now_ms - last_ws_ping_ms) >= kClientPingIntervalMs) {
                const int64_t pong_baseline_ms = ws_->GetLastPongMs();
                last_ws_ping_ms = now_ms;
                if (!ws_->Ping()) {
                    ESP_LOGW(kLanMicTag, "WebSocket ping send failed; reconnecting");
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
                ESP_LOGW(kLanMicTag,
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
            if (has_pending_transcript_ && send_target_ != "text_injector") {
                if (IsServerConnected()) {
                    SendAction(LAN_MSG_DEVICE_ACTION_SEND);
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
            if (has_pending_transcript_ && send_target_ != "text_injector") {
                if (IsServerConnected()) {
                    SendAction(LAN_MSG_DEVICE_ACTION_UNDO);
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
        if (phase_ == Phase::Upgrading || IsFirmwareOtaRunning()) {
            vTaskDelay(pdMS_TO_TICKS(50));
            continue;
        }
        if (pressed && !last_pressed) {
            ESP_LOGI(kLanMicTag, "BOOT press connected=%d connect_task=%d phase=%d",
                     IsServerConnected() ? 1 : 0,
                     connect_attempt_running_.load(std::memory_order_acquire) ? 1 : 0,
                     static_cast<int>(phase_));
            boot_pressed_since_ms = now_ms;
            TouchUserInput(now_ms);
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
                ESP_LOGI(kLanMicTag, "PTT start");
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
            ESP_LOGI(kLanMicTag, "PTT start from page hold");
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
            ESP_LOGI(kLanMicTag, "BOOT release phase=%d", static_cast<int>(phase_));
            if (phase_ == Phase::Recording) {
                ESP_LOGI(kLanMicTag, "PTT stop");
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
                if (injector_boot_tap_.OnShortRelease(now_ms) ==
                    DeferredTapTracker::ReleaseResult::DoubleTap) {
                    if (SendClearInput()) {
                        status_text_ = "已清空输入";
                        hint_text_ = "连按两次 BOOT 清空";
                        phase_ = Phase::Idle;
                    } else {
                        status_text_ = "清空失败";
                        hint_text_ = "检查连接";
                        phase_ = Phase::Error;
                    }
                } else {
                    status_text_ = "短按 BOOT";
                    hint_text_ = "再按一次清空";
                    phase_ = Phase::Idle;
                }
                UpdateDisplay();
            } else if (active_page_ == Page::Todo &&
                       !todo_hold_started &&
                       boot_pressed_since_ms > 0 &&
                       !has_pending_transcript_) {
                todo_boot_tap_.OnShortRelease(now_ms);
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
                (active_page_ == Page::Todo || active_page_ == Page::Summary) &&
                (battery_charging_ || !battery_known_)) {
                CapturePrerollFrame();
                vTaskDelay(pdMS_TO_TICKS(1));
            } else {
                vTaskDelay(pdMS_TO_TICKS(10));
            }
            continue;
        }

        // Only capture preroll when voice input is plausible (connected +
        // on a voice-capable page and no pending transcript).  On other
        // pages or when disconnected, skip the 20 ms codec read so the
        // CPU can idle longer between button polls.
        const bool voice_ready = IsServerConnected() &&
            !has_pending_transcript_ &&
            !todo_menu_open_ &&
            (active_page_ == Page::Summary || active_page_ == Page::Todo) &&
            (battery_charging_ || !battery_known_);
        if (voice_ready) {
            CapturePrerollFrame();
            vTaskDelay(pdMS_TO_TICKS(1));
        } else {
            vTaskDelay(pdMS_TO_TICKS(50));
        }
    }
}
