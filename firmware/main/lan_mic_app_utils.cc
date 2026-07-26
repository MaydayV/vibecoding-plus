#include "lan_mic_app_internal.h"

#include <cJSON.h>
#include <cstdio>
#include <ctime>
#include <cctype>
#include <algorithm>
#include <string>
#include <vector>

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

const char kLanMicTag[] = "LanMicApp";
const char kDiscoveryService[] = "vibecoding-plus";
const char kDefaultHostId[] = "VibeServer";
const char kLanMicNamespace[] = "lan_mic";
const char kVolumeKey[] = "volume";
const char kLastServerUriKey[] = "last_srv_uri";
const char kPairedHostIdKey[] = "pair_host_id";
const char kPairedHostNameKey[] = "pair_host_nm";
const char kPendingTodoOpsKey[] = "todo_ops";
const char kCachedTodoStateKey[] = "todo_cache";
const char kLanSharedSecretKey[] = "lan_secret";
const EventBits_t kWifiConnectedBit = BIT0;
const int kFrameDurationMs = 20;
const int kSampleRate = 16000;
const int kFrameSamples = kSampleRate * kFrameDurationMs / 1000;
const size_t kPrerollFrameCount = 45;      // 900 ms @ 20 ms per frame
const int kDiscoveryAttempts = 3;
const int kDiscoveryTimeoutMs = 600;
const int kDiscoveryRetryDelayMs = 150;
const int64_t kReconnectIntervalMinMs = 2000;
const int64_t kReconnectIntervalMaxMs = 15000;
const int64_t kClientPingIntervalMs = 10000;
const int64_t kPongTimeoutMs = 15000;
const int64_t kServerSilenceTimeoutMs = 45000;
const int64_t kConnectAttemptWatchdogMs = 20000;
const int kReconnectFailuresBeforeWifiRecovery = 3;
const int64_t kWifiRecoveryCooldownMs = 30000;
const int64_t kOfflineSleepRetryAwakeMs = 60000;  // 1 minute retry window after timer wake
const int64_t kOfflineSleepRetryIntervalUs = 15LL * 60 * 1000 * 1000;  // 15 minutes
const int64_t kReconnectPromptTimeoutMs = 15000;
const int64_t kTodoBootHoldMs = 600;
const int64_t kTodoBootDoubleClickWindowMs = 250;
const int64_t kInjectorBootDoubleClickWindowMs = 350;
const int64_t kNavDoubleClickWindowMs = 450;
const int64_t kNavLongPressMs = 2000;
const int64_t kNavShortPressMinMs = 15;
const int64_t kNavShortPressMaxMs = kNavLongPressMs - 1;
const uint32_t kConnectTaskStackSize = 6 * 1024;
const UBaseType_t kConnectTaskPriority = 2;
// If no server connection is established within this window, enter deep sleep
// to preserve battery.  BOOT button or a 5-minute timer wakes the board for
// another retry cycle.  Pressing BOOT while disconnected resets this window.
const int64_t kNoConnectionSleepMs = 5LL * 60 * 1000;  // 5 minutes
const size_t kBodyCharsPerLine = 22;
const size_t kPromptVisibleLines = 3;
const size_t kReplyVisibleLines = 4;
const size_t kLogVisibleLines = 8;
const int kStatusBarBottomY = 31;
const int kHeaderLineY = 62;
const int kPromptDividerY = 156;
const int kFooterTopY = 264;
const int kContentHeaderY = 44;
const int kPromptTitleY = 74;
const int kPromptBodyY = 96;
const int kReplyTitleY = 168;
const int kReplyBodyY = 190;
const int kLogTitleY = 74;
const int kLogBodyY = 96;
const int kFooterTextY = 276;
const int kLineHeight = 18;
const int kBatteryPollIntervalMs = 15000;
const size_t kCachedTodoStateMaxBytes = 3500;
const int64_t kTodoNvsDebounceMs = 500;
const int kProtocolVersion = 1;
// OTA download progress arrives once per percent; forwarding every tick would
// mean up to 100 full e-paper redraws plus 100 WebSocket frames.
const int kOtaProgressStepPct = 10;
const int64_t kOtaProgressIntervalMs = 2000;
// Speaker amp stays on for at most one I2S DMA buffer after the last sample is
// queued; give it a small margin before powering the output back down.
const int64_t kAudioOutputTailMarginMs = 30;
const uint8_t kWifiIcon12x12[] = {
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

const uint8_t kBatteryIcon14x8[] = {
    0xFF, 0xFC,
    0x80, 0x04,
    0x80, 0x04,
    0x80, 0x04,
    0x80, 0x04,
    0x80, 0x04,
    0x80, 0x04,
    0xFF, 0xFC,
};

const size_t kWifiIcon12x12Size = sizeof(kWifiIcon12x12);
const size_t kBatteryIcon14x8Size = sizeof(kBatteryIcon14x8);


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


int DaysInMonth(int year, int month) {
    static const int kDaysByMonth[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (month < 1 || month > 12) {
        return 0;
    }
    if (month != 2) {
        return kDaysByMonth[month - 1];
    }
    const bool leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
    return leap ? 29 : 28;
}

bool ParseDigits(const std::string& text, size_t start, size_t length, int& value) {
    if (start + length > text.size() || length == 0) {
        return false;
    }
    int parsed = 0;
    for (size_t i = start; i < start + length; ++i) {
        const unsigned char ch = static_cast<unsigned char>(text[i]);
        if (!std::isdigit(ch)) {
            return false;
        }
        parsed = parsed * 10 + (text[i] - '0');
    }
    value = parsed;
    return true;
}

int64_t DaysFromCivil(int year, unsigned month, unsigned day) {
    year -= month <= 2;
    const int era = (year >= 0 ? year : year - 399) / 400;
    const unsigned yoe = static_cast<unsigned>(year - era * 400);
    const unsigned doy = (153 * (month + (month > 2 ? static_cast<unsigned>(-3) : 9)) + 2) / 5 + day - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return static_cast<int64_t>(era) * 146097 + static_cast<int64_t>(doe) - 719468;
}

bool ParseIsoDateMonthDay(const std::string& due_at, int& out_month, int& out_day) {
    if (due_at.size() < 10 || due_at[4] != '-' || due_at[7] != '-') {
        return false;
    }

    int year = 0;
    int month = 0;
    int day = 0;
    if (!ParseDigits(due_at, 0, 4, year) ||
        !ParseDigits(due_at, 5, 2, month) ||
        !ParseDigits(due_at, 8, 2, day)) {
        return false;
    }

    const int max_day = DaysInMonth(year, month);
    if (max_day == 0 || day < 1 || day > max_day) {
        return false;
    }

    out_month = month;
    out_day = day;

    if (due_at.size() <= 10 || due_at[10] != 'T') {
        return true;
    }

    int hour = 0;
    int minute = 0;
    int second = 0;
    if (due_at.size() < 16 || due_at[13] != ':' ||
        !ParseDigits(due_at, 11, 2, hour) ||
        !ParseDigits(due_at, 14, 2, minute)) {
        return true;
    }

    size_t pos = 16;
    if (pos < due_at.size() && due_at[pos] == ':') {
        if (pos + 3 > due_at.size() || !ParseDigits(due_at, pos + 1, 2, second)) {
            return true;
        }
        pos += 3;
    }

    if (pos < due_at.size() && due_at[pos] == '.') {
        ++pos;
        while (pos < due_at.size() && std::isdigit(static_cast<unsigned char>(due_at[pos]))) {
            ++pos;
        }
    }

    bool has_timezone = false;
    int timezone_offset_seconds = 0;
    if (pos < due_at.size() && (due_at[pos] == 'Z' || due_at[pos] == 'z')) {
        has_timezone = true;
    } else if (pos < due_at.size() && (due_at[pos] == '+' || due_at[pos] == '-')) {
        const bool positive = due_at[pos] == '+';
        int tz_hour = 0;
        int tz_minute = 0;
        if (pos + 6 <= due_at.size() && due_at[pos + 3] == ':' &&
            ParseDigits(due_at, pos + 1, 2, tz_hour) &&
            ParseDigits(due_at, pos + 4, 2, tz_minute)) {
            has_timezone = true;
            timezone_offset_seconds = tz_hour * 3600 + tz_minute * 60;
            if (!positive) {
                timezone_offset_seconds = -timezone_offset_seconds;
            }
        }
    }

    if (!has_timezone) {
        return true;
    }

    const int64_t epoch_seconds =
        DaysFromCivil(year, static_cast<unsigned>(month), static_cast<unsigned>(day)) * 86400 +
        static_cast<int64_t>(hour) * 3600 +
        static_cast<int64_t>(minute) * 60 +
        static_cast<int64_t>(second) -
        static_cast<int64_t>(timezone_offset_seconds);

    time_t epoch_time = static_cast<time_t>(epoch_seconds);
    tm local_tm = {};
    if (localtime_r(&epoch_time, &local_tm) == nullptr) {
        return true;
    }

    out_month = local_tm.tm_mon + 1;
    out_day = local_tm.tm_mday;
    return true;
}

std::string FormatTodoRightTimeText(const std::string& due_at) {
    int month = 0;
    int day = 0;
    if (!ParseIsoDateMonthDay(due_at, month, day)) {
        return "";
    }
    return FormatTwoDigits(month) + "/" + FormatTwoDigits(day);
}

std::vector<std::string> WrapUtf8Lines(const std::string& text, size_t max_chars, size_t max_lines) {
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

