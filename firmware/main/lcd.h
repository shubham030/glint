#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_lcd_panel_ops.h"

esp_err_t lcd_init(void);
esp_lcd_panel_handle_t lcd_panel(void);

/* 0..255, mapped onto the LEDC duty range */
void lcd_backlight(uint8_t level);

/* true = panel + backlight off (GLINT_CMD_SLEEP), false = back on */
void lcd_sleep(bool sleep);
