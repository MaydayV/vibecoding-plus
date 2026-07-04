#pragma once

#include <driver/gpio.h>

#include <cstdint>

struct GpioInputEvents {
    bool click = false;
    bool double_click = false;
    bool long_press = false;
};

// Poll-based GPIO input: short click, optional double-click window, long press.
class GpioInputDriver {
public:
    GpioInputDriver(gpio_num_t gpio,
                    int64_t long_press_ms,
                    int64_t short_press_min_ms,
                    int64_t short_press_max_ms);

    void Poll(int64_t now_ms, int64_t double_window_ms);
    GpioInputEvents ConsumeEvents();
    bool IsPressed() const;

private:
    static void ConfigureGpio(gpio_num_t gpio);

    gpio_num_t gpio_;
    int64_t long_press_ms_;
    int64_t short_press_min_ms_;
    int64_t short_press_max_ms_;
    bool pressed_last_ = false;
    bool long_fired_ = false;
    bool waiting_second_click_ = false;
    int64_t press_started_ms_ = 0;
    int64_t first_release_ms_ = 0;
    GpioInputEvents pending_;
};
