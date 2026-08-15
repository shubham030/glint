/* FT6x36-compatible touch controller, implemented in this project.
 *
 * See ft6336.c for why this is not a component dependency: the parts these
 * boards carry report no vendor id, which off-the-shelf drivers treat as a
 * fatal error.
 */
#pragma once

#include "esp_lcd_panel_io.h"
#include "esp_lcd_touch.h"

/* I2C address, fixed on this family. */
#define FT6336_I2C_ADDRESS 0x38

#define FT6336_IO_I2C_CONFIG()                 \
    {                                          \
        .dev_addr = FT6336_I2C_ADDRESS,        \
        .control_phase_bytes = 1,              \
        .dc_bit_offset = 0,                    \
        .lcd_cmd_bits = 8,                     \
        .flags = {.disable_control_phase = 1}, \
        .scl_speed_hz = 400 * 1000,            \
    }

esp_err_t ft6336_new(const esp_lcd_panel_io_handle_t io,
                     const esp_lcd_touch_config_t *config,
                     esp_lcd_touch_handle_t *out_touch);
