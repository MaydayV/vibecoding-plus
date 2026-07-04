#include "gpio_input_driver.h"

#include <driver/gpio.h>
#include <esp_log.h>

namespace {

constexpr char kTag[] = "GpioInput";

} // namespace

void GpioInputDriver::ConfigureGpio(gpio_num_t gpio) {
    if (gpio == GPIO_NUM_NC) {
        return;
    }
    gpio_config_t cfg = {};
    cfg.pin_bit_mask = 1ULL << gpio;
    cfg.mode = GPIO_MODE_INPUT;
    cfg.pull_up_en = GPIO_PULLUP_ENABLE;
    cfg.pull_down_en = GPIO_PULLDOWN_DISABLE;
    cfg.intr_type = GPIO_INTR_DISABLE;
    ESP_ERROR_CHECK(gpio_config(&cfg));
}

GpioInputDriver::GpioInputDriver(gpio_num_t gpio,
                                 int64_t long_press_ms,
                                 int64_t short_press_min_ms,
                                 int64_t short_press_max_ms)
    : gpio_(gpio),
      long_press_ms_(long_press_ms),
      short_press_min_ms_(short_press_min_ms),
      short_press_max_ms_(short_press_max_ms) {
    ConfigureGpio(gpio_);
    pressed_last_ = IsPressed();
}

bool GpioInputDriver::IsPressed() const {
    if (gpio_ == GPIO_NUM_NC) {
        return false;
    }
    return gpio_get_level(gpio_) == 0;
}

void GpioInputDriver::Poll(int64_t now_ms, int64_t double_window_ms) {
    const bool pressed_now = IsPressed();
    if (pressed_now && !pressed_last_) {
        press_started_ms_ = now_ms;
        long_fired_ = false;
    } else if (!pressed_now && pressed_last_) {
        const int64_t duration_ms = now_ms - press_started_ms_;
        if (!long_fired_ &&
            duration_ms >= short_press_min_ms_ &&
            duration_ms <= short_press_max_ms_) {
            if (waiting_second_click_ &&
                double_window_ms > 0 &&
                (now_ms - first_release_ms_) <= double_window_ms) {
                pending_.double_click = true;
                waiting_second_click_ = false;
                first_release_ms_ = 0;
            } else {
                pending_.click = true;
                if (double_window_ms > 0) {
                    waiting_second_click_ = true;
                    first_release_ms_ = now_ms;
                } else {
                    waiting_second_click_ = false;
                    first_release_ms_ = 0;
                }
            }
        }
        press_started_ms_ = 0;
        long_fired_ = false;
    } else if (pressed_now &&
               !long_fired_ &&
               press_started_ms_ > 0 &&
               (now_ms - press_started_ms_) >= long_press_ms_) {
        pending_.long_press = true;
        long_fired_ = true;
        waiting_second_click_ = false;
        first_release_ms_ = 0;
    }
    pressed_last_ = pressed_now;

    if (waiting_second_click_ &&
        (double_window_ms <= 0 || (now_ms - first_release_ms_) > double_window_ms)) {
        waiting_second_click_ = false;
        first_release_ms_ = 0;
    }
}

GpioInputEvents GpioInputDriver::ConsumeEvents() {
    GpioInputEvents events = pending_;
    pending_ = {};
    return events;
}
