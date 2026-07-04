#pragma once

#include <cstdint>

// Tracks short-tap vs double-tap on release; single-tap fires after window elapses.
class DeferredTapTracker {
public:
    explicit DeferredTapTracker(int64_t window_ms) : window_ms_(window_ms) {}

    enum class ReleaseResult { None, FirstPending, DoubleTap };

    ReleaseResult OnShortRelease(int64_t now_ms) {
        if (pending_ && last_release_ms_ > 0 &&
            (now_ms - last_release_ms_) <= window_ms_) {
            pending_ = false;
            last_release_ms_ = 0;
            return ReleaseResult::DoubleTap;
        }
        pending_ = true;
        last_release_ms_ = now_ms;
        return ReleaseResult::FirstPending;
    }

    bool PollSingleReady(int64_t now_ms, bool still_pressed) {
        if (!pending_ || still_pressed || last_release_ms_ == 0) {
            return false;
        }
        if ((now_ms - last_release_ms_) >= window_ms_) {
            pending_ = false;
            last_release_ms_ = 0;
            return true;
        }
        return false;
    }

    void Cancel() {
        pending_ = false;
        last_release_ms_ = 0;
    }

    bool pending() const { return pending_; }

private:
    int64_t window_ms_;
    bool pending_ = false;
    int64_t last_release_ms_ = 0;
};
