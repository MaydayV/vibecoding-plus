#ifndef LAN_MIC_APP_INTERNAL_H
#define LAN_MIC_APP_INTERNAL_H

#include <cJSON.h>

#ifdef ESP_PLATFORM
#include <freertos/FreeRTOS.h>
#else
#include <cstdint>
using EventBits_t = uint32_t;
using UBaseType_t = unsigned int;
#ifndef BIT0
#define BIT0 (1 << 0)
#endif
#endif

#include <ctime>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

extern const char kLanMicTag[];
extern const char kDiscoveryService[];
extern const char kDefaultHostId[];
extern const char kLanMicNamespace[];
extern const char kVolumeKey[];
extern const char kLastServerUriKey[];
extern const char kPairedHostIdKey[];
extern const char kPairedHostNameKey[];
extern const char kPendingTodoOpsKey[];
extern const char kCachedTodoStateKey[];
extern const char kLanSharedSecretKey[];

extern const EventBits_t kWifiConnectedBit;
extern const int kFrameDurationMs;
extern const int kSampleRate;
extern const int kFrameSamples;
extern const size_t kPrerollFrameCount;
extern const int kDiscoveryAttempts;
extern const int kDiscoveryTimeoutMs;
extern const int kDiscoveryRetryDelayMs;
extern const int64_t kReconnectIntervalMinMs;
extern const int64_t kReconnectIntervalMaxMs;
extern const int64_t kClientPingIntervalMs;
extern const int64_t kPongTimeoutMs;
extern const int64_t kServerSilenceTimeoutMs;
extern const int64_t kConnectAttemptWatchdogMs;
extern const int kReconnectFailuresBeforeWifiRecovery;
extern const int64_t kWifiRecoveryCooldownMs;
extern const int64_t kOfflineSleepRetryAwakeMs;
extern const int64_t kOfflineSleepRetryIntervalUs;
extern const int64_t kReconnectPromptTimeoutMs;
extern const int64_t kTodoBootHoldMs;
extern const int64_t kTodoBootDoubleClickWindowMs;
extern const int64_t kInjectorBootDoubleClickWindowMs;
extern const int64_t kNavDoubleClickWindowMs;
extern const int64_t kNavLongPressMs;
extern const int64_t kNavShortPressMinMs;
extern const int64_t kNavShortPressMaxMs;
extern const uint32_t kConnectTaskStackSize;
extern const UBaseType_t kConnectTaskPriority;
extern const int64_t kNoConnectionSleepMs;
extern const size_t kBodyCharsPerLine;
extern const size_t kPromptVisibleLines;
extern const size_t kReplyVisibleLines;
extern const size_t kLogVisibleLines;
extern const int kStatusBarBottomY;
extern const int kHeaderLineY;
extern const int kPromptDividerY;
extern const int kFooterTopY;
extern const int kContentHeaderY;
extern const int kPromptTitleY;
extern const int kPromptBodyY;
extern const int kReplyTitleY;
extern const int kReplyBodyY;
extern const int kLogTitleY;
extern const int kLogBodyY;
extern const int kFooterTextY;
extern const int kLineHeight;
extern const int kBatteryPollIntervalMs;
extern const size_t kCachedTodoStateMaxBytes;
extern const int64_t kTodoNvsDebounceMs;
extern const int kProtocolVersion;
extern const int kOtaProgressStepPct;
extern const int64_t kOtaProgressIntervalMs;
extern const int64_t kAudioOutputTailMarginMs;

extern const uint8_t kWifiIcon12x12[];
extern const size_t kWifiIcon12x12Size;
extern const uint8_t kBatteryIcon14x8[];
extern const size_t kBatteryIcon14x8Size;

std::string FormatTwoDigits(int value);
std::string FormatTodoClockText(const tm& local_tm);
std::string FormatTodoDateText(const tm& local_tm);
std::string FormatTodoRightTimeText(const std::string& due_at);
std::vector<std::string> WrapUtf8Lines(const std::string& text, size_t max_chars, size_t max_lines = 0);
const char* GetJsonString(cJSON* root, const char* key);
bool GetJsonBool(cJSON* root, const char* key, bool fallback);

#endif
