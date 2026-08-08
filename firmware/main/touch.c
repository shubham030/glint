#include "touch.h"

#include "board.h"
#include "esp_check.h"
#include "esp_lcd_touch_ft6336.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "protocol.h"
#include "usb_vendor.h"

static const char *TAG = "touch";

#define POLL_HZ         60
#define MAX_POINTS      2
#define MOVE_THRESHOLD  2 /* panel px; suppresses jitter on a still finger */

static esp_lcd_touch_handle_t s_tp;

typedef struct {
    bool down;
    uint16_t x, y;
} point_state_t;

static void emit(uint8_t type, uint8_t id, uint16_t x, uint16_t y)
{
    const glint_evt_t evt = {
        .magic = GLINT_MAGIC_EVT,
        .type = type,
        .id = id,
        .x = x,
        .y = y,
        .rsvd = 0,
    };
    usb_vendor_send_event(&evt);
}

static void touch_task(void *arg)
{
    (void)arg;
    point_state_t prev[MAX_POINTS] = {0};

    for (;;) {
        esp_lcd_touch_read_data(s_tp);

        esp_lcd_touch_point_data_t pts[MAX_POINTS] = {0};
        uint8_t count = 0;
        esp_lcd_touch_get_data(s_tp, pts, &count, MAX_POINTS);

        bool seen[MAX_POINTS] = {0};
        for (uint8_t i = 0; i < count && i < MAX_POINTS; i++) {
            seen[i] = true;
            if (!prev[i].down) {
                emit(GLINT_EVT_DOWN, i, pts[i].x, pts[i].y);
            } else {
                const int dx = (int)pts[i].x - (int)prev[i].x;
                const int dy = (int)pts[i].y - (int)prev[i].y;
                if (dx * dx + dy * dy >= MOVE_THRESHOLD * MOVE_THRESHOLD) {
                    emit(GLINT_EVT_MOVE, i, pts[i].x, pts[i].y);
                } else {
                    continue; /* keep prev coords: no drift */
                }
            }
            prev[i].down = true;
            prev[i].x = pts[i].x;
            prev[i].y = pts[i].y;
        }

        for (uint8_t i = 0; i < MAX_POINTS; i++) {
            if (prev[i].down && !seen[i]) {
                emit(GLINT_EVT_UP, i, prev[i].x, prev[i].y);
                prev[i].down = false;
            }
        }

        vTaskDelay(pdMS_TO_TICKS(1000 / POLL_HZ));
    }
}

esp_err_t touch_init(i2c_master_bus_handle_t bus)
{
    esp_lcd_panel_io_i2c_config_t io_cfg = ESP_LCD_TOUCH_IO_I2C_FT6336_CONFIG();
    io_cfg.scl_speed_hz = 400 * 1000;
    esp_lcd_panel_io_handle_t io = NULL;
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_io_i2c(bus, &io_cfg, &io), TAG,
                        "touch io");

    const esp_lcd_touch_config_t cfg = {
        .x_max = BOARD_LCD_H_RES,
        .y_max = BOARD_LCD_V_RES,
        .rst_gpio_num = BOARD_PIN_TP_RST,
        .int_gpio_num = BOARD_PIN_TP_INT,
        .levels = {
            .reset = 0,
            .interrupt = 0,
        },
        /* Report panel-native coordinates; the host applies orientation. */
        .flags = {
            .swap_xy = 0,
            .mirror_x = 0,
            .mirror_y = 0,
        },
    };
    ESP_RETURN_ON_ERROR(esp_lcd_touch_new_i2c_ft6336(io, &cfg, &s_tp), TAG,
                        "ft6336");

    const BaseType_t ok =
        xTaskCreatePinnedToCore(touch_task, "touch", 4096, NULL, 5, NULL, 0);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "touch task");

    ESP_LOGI(TAG, "FT6336 up (%dx%d, %d Hz)", BOARD_LCD_H_RES, BOARD_LCD_V_RES,
             POLL_HZ);
    return ESP_OK;
}
