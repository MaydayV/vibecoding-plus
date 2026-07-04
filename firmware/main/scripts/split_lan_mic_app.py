#!/usr/bin/env python3
"""Split lan_mic_app.cc into lan_mic_app*.cc modules."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "lan_mic_app.cc"

COMMON_INCLUDES = '''\
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

'''

def ranges(*specs):
    out = set()
    for spec in specs:
        if isinstance(spec, tuple):
            out.update(range(spec[0], spec[1]))
        else:
            out.add(spec)
    return out

# Non-overlapping line assignments (1-based, end exclusive)
CORE = ranges((388, 494), (1447, 1686))
NET = ranges((494, 724), (743, 1283))
PROTO = ranges((1284, 1446), (1686, 2058))
INPUT = ranges((724, 743), (2058, 2851), (3442, 99999))
RENDER = ranges((2852, 3442))

def read_lines():
    return SRC.read_text(encoding="utf-8").splitlines(keepends=True)

def extract_by_lines(lines, keep_lines):
    return "".join(lines[i - 1] for i in sorted(keep_lines) if 1 <= i <= len(lines))

def replace_tag(text):
    return text.replace("kTag", "kLanMicTag")

def write_utils(lines):
    utils_body = "".join(lines[42:386])
    utils_body = utils_body.replace("namespace {\n\n", "")
    utils_body = utils_body.replace("constexpr char kTag[] = \"LanMicApp\";", 'const char kLanMicTag[] = "LanMicApp";')
    for old, new in [
        ("constexpr char kDiscoveryService", "const char kDiscoveryService"),
        ("constexpr char kDefaultHostId", "const char kDefaultHostId"),
        ("constexpr char kLanMicNamespace", "const char kLanMicNamespace"),
        ("constexpr char kVolumeKey", "const char kVolumeKey"),
        ("constexpr char kLastServerUriKey", "const char kLastServerUriKey"),
        ("constexpr char kPairedHostIdKey", "const char kPairedHostIdKey"),
        ("constexpr char kPairedHostNameKey", "const char kPairedHostNameKey"),
        ("constexpr char kPendingTodoOpsKey", "const char kPendingTodoOpsKey"),
        ("constexpr char kCachedTodoStateKey", "const char kCachedTodoStateKey"),
        ("constexpr EventBits_t kWifiConnectedBit", "const EventBits_t kWifiConnectedBit"),
        ("constexpr uint32_t kConnectTaskStackSize", "const uint32_t kConnectTaskStackSize"),
        ("constexpr UBaseType_t kConnectTaskPriority", "const UBaseType_t kConnectTaskPriority"),
        ("constexpr uint8_t kWifiIcon12x12", "const uint8_t kWifiIcon12x12"),
        ("constexpr uint8_t kBatteryIcon14x8", "const uint8_t kBatteryIcon14x8"),
    ]:
        utils_body = utils_body.replace(old, new)
    for name in [
        "kFrameDurationMs", "kSampleRate", "kFrameSamples", "kDiscoveryAttempts",
        "kDiscoveryTimeoutMs", "kDiscoveryRetryDelayMs", "kReconnectIntervalMinMs",
        "kReconnectIntervalMaxMs", "kClientPingIntervalMs", "kPongTimeoutMs",
        "kServerSilenceTimeoutMs", "kConnectAttemptWatchdogMs",
        "kReconnectFailuresBeforeWifiRecovery", "kWifiRecoveryCooldownMs",
        "kOfflineSleepRetryAwakeMs", "kReconnectPromptTimeoutMs", "kTodoBootHoldMs",
        "kTodoBootDoubleClickWindowMs", "kInjectorBootDoubleClickWindowMs",
        "kNavDoubleClickWindowMs", "kNavLongPressMs", "kNavShortPressMinMs",
        "kNavShortPressMaxMs", "kStatusBarBottomY", "kHeaderLineY",
        "kPromptDividerY", "kFooterTopY", "kContentHeaderY", "kPromptTitleY",
        "kPromptBodyY", "kReplyTitleY", "kReplyBodyY", "kLogTitleY", "kLogBodyY",
        "kFooterTextY", "kLineHeight", "kBatteryPollIntervalMs", "kProtocolVersion",
    ]:
        utils_body = utils_body.replace(f"constexpr int {name}", f"const int {name}")
        utils_body = utils_body.replace(f"constexpr int64_t {name}", f"const int64_t {name}")
        utils_body = utils_body.replace(f"constexpr size_t {name}", f"const size_t {name}")
    utils_body = utils_body.replace("constexpr int64_t kOfflineSleepRetryIntervalUs", "const int64_t kOfflineSleepRetryIntervalUs")
    utils_body = utils_body.replace("constexpr int64_t kNoConnectionSleepMs", "const int64_t kNoConnectionSleepMs")
    utils_body = utils_body.replace("constexpr size_t kPrerollFrameCount", "const size_t kPrerollFrameCount")
    utils_body = utils_body.replace("constexpr size_t kBodyCharsPerLine", "const size_t kBodyCharsPerLine")
    utils_body = utils_body.replace("constexpr size_t kPromptVisibleLines", "const size_t kPromptVisibleLines")
    utils_body = utils_body.replace("constexpr size_t kReplyVisibleLines", "const size_t kReplyVisibleLines")
    utils_body = utils_body.replace("constexpr size_t kLogVisibleLines", "const size_t kLogVisibleLines")
    utils_body = utils_body.replace("constexpr size_t kCachedTodoStateMaxBytes", "const size_t kCachedTodoStateMaxBytes")
    utils_body = utils_body.replace("constexpr int64_t kTodoNvsDebounceMs", "const int64_t kTodoNvsDebounceMs")
    utils_body = utils_body.replace("constexpr int kNavShortPressMaxMs = kNavLongPressMs - 1;",
                                    "const int kNavShortPressMaxMs = kNavLongPressMs - 1;")
    utils_body = utils_body.replace("constexpr int kFrameSamples = kSampleRate * kFrameDurationMs / 1000;",
                                    "const int kFrameSamples = kSampleRate * kFrameDurationMs / 1000;")
    utils_body = utils_body.replace("} // namespace\n", "")

    content = (
        '#include "lan_mic_app_internal.h"\n\n'
        '#include <cJSON.h>\n#include <cstdio>\n#include <ctime>\n#include <cctype>\n'
        '#include <algorithm>\n#include <string>\n#include <vector>\n\n'
        + utils_body
    )
    (ROOT / "lan_mic_app_utils.cc").write_text(content, encoding="utf-8")

def main():
    lines = read_lines()
    total = len(lines)
    input_lines = ranges((724, 743), (2058, 2851), (3442, total + 1))

    all_assigned = CORE | NET | PROTO | input_lines | RENDER
    missing = sorted(set(range(388, total + 1)) - all_assigned)
    pairs = [("CORE", CORE), ("NET", NET), ("PROTO", PROTO), ("INPUT", input_lines), ("RENDER", RENDER)]
    for i, (a, sa) in enumerate(pairs):
        for b, sb in pairs[i + 1:]:
            ov = sa & sb
            if ov:
                print(f"OVERLAP {a}/{b}: {sorted(ov)[:5]}... ({len(ov)} lines)")

    if missing:
        print("Unassigned:", missing)

    write_utils(lines)

    files = {
        "lan_mic_app.cc": CORE,
        "app_net.cc": NET,
        "app_protocol.cc": PROTO,
        "app_input.cc": input_lines,
        "app_render.cc": RENDER,
    }
    for fname, keep in files.items():
        body = replace_tag(extract_by_lines(lines, keep))
        (ROOT / fname).write_text(COMMON_INCLUDES + body, encoding="utf-8")
        print(f"Wrote {fname}: {len(keep)} lines")

    backup = ROOT / "lan_mic_app.cc.bak"
    if not backup.exists():
        backup.write_text("".join(lines), encoding="utf-8")

if __name__ == "__main__":
    main()
