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
        case Phase::Upgrading:
            return "↑ 升级中";
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
    display_->WriteRaw1bpp(x, y, 12, 12, kWifiIcon12x12, kWifiIcon12x12Size);
}

void LanMicApp::DrawBatteryIcon(int x, int y, int level, bool charging) {
    if (display_ == nullptr) {
        return;
    }

    const int clamped_level = std::clamp(level, 0, 100);
    std::vector<uint8_t> buffer(kBatteryIcon14x8, kBatteryIcon14x8 + kBatteryIcon14x8Size);
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
        const std::string header_label = repo_name_.empty() ? std::string(GetToolLabel()) : repo_name_;
        texts.push_back({single_line(header_label, 18), 12, kContentHeaderY, 16});
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
            constexpr int kTodoRowStartY = 100;
            constexpr int kTodoRowHeight = 26;
            constexpr int kTodoCheckboxX = 14;
            constexpr int kTodoTimeX = 286;
            constexpr int kTodoRowsVisible = 6;

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

