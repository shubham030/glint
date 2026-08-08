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

#define POLL_HZ        60
#define MAX_POINTS     2
#define MOVE_THRESHOLD 2 /* panel px; suppresses jitter on a still finger */

/* The vendored FT6336 driver fills coordinates by array position and never
 * populates track_id, so a report is an unordered set of positions: when the
 * first of two fingers lifts, the second shifts down an index. Contacts are
 * therefore matched to slots by proximity, and a point further than this from
 * every known contact is treated as a new one. */
#define MATCH_RADIUS 60

static esp_lcd_touch_handle_t s_tp;

typedef struct {
    bool down;
    uint16_t x, y;
} point_state_t;

static int nearest_slot(const point_state_t *slots, uint16_t x, uint16_t y)
{
    int best = -1;
    long best_d2 = (long)MATCH_RADIUS * MATCH_RADIUS;

    for (int i = 0; i < MAX_POINTS; i++) {
        if (!slots[i].down) {
            continue;
        }
        const long dx = (long)x - slots[i].x;
        const long dy = (long)y - slots[i].y;
        const long d2 = dx * dx + dy * dy;
        if (d2 <= best_d2) {
            best_d2 = d2;
            best = i;
        }
    }
    return best;
}

static int free_slot(const point_state_t *slots, const bool *claimed)
{
    for (int i = 0; i < MAX_POINTS; i++) {
        if (!slots[i].down && !claimed[i]) {
            return i;
        }
    }
    return -1;
}

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
    point_state_t slots[MAX_POINTS] = {0};

    for (;;) {
        esp_lcd_touch_read_data(s_tp);

        esp_lcd_touch_point_data_t pts[MAX_POINTS] = {0};
        uint8_t count = 0;
        esp_lcd_touch_get_data(s_tp, pts, &count, MAX_POINTS);
        if (count > MAX_POINTS) {
            count = MAX_POINTS;
        }

        bool claimed[MAX_POINTS] = {0};

        for (uint8_t i = 0; i < count; i++) {
            const uint16_t x = pts[i].x;
            const uint16_t y = pts[i].y;

            int slot = nearest_slot(slots, x, y);
            if (slot >= 0 && claimed[slot]) {
                slot = -1; /* another contact already took it this cycle */
            }

            if (slot < 0) {
                slot = free_slot(slots, claimed);
                if (slot < 0) {
                    continue; /* more contacts than slots: ignore the extra */
                }
                claimed[slot] = true;
                slots[slot].down = true;
                slots[slot].x = x;
                slots[slot].y = y;
                emit(GLINT_EVT_DOWN, (uint8_t)slot, x, y);
                continue;
            }

            claimed[slot] = true;
            const int dx = (int)x - (int)slots[slot].x;
            const int dy = (int)y - (int)slots[slot].y;
            if (dx * dx + dy * dy < MOVE_THRESHOLD * MOVE_THRESHOLD) {
                continue; /* keep the old coords so jitter cannot drift */
            }
            slots[slot].x = x;
            slots[slot].y = y;
            emit(GLINT_EVT_MOVE, (uint8_t)slot, x, y);
        }

        for (int i = 0; i < MAX_POINTS; i++) {
            if (slots[i].down && !claimed[i]) {
                emit(GLINT_EVT_UP, (uint8_t)i, slots[i].x, slots[i].y);
                slots[i].down = false;
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
