#pragma once

#include <cstddef>
#include <functional>
#include <string>

struct FirmwareOtaOffer {
    std::string url;
    std::string version;
    std::string sha256_hex;
    size_t size = 0;
};

using FirmwareOtaProgressFn = std::function<void(const char* phase, int pct, const char* error)>;

bool StartFirmwareOta(const FirmwareOtaOffer& offer, FirmwareOtaProgressFn progress);
bool IsFirmwareOtaRunning();
bool ConfirmRunningFirmware();
