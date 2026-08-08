#include <stdlib.h>

#include "board.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "lcd.h"
#include "usb_vendor.h"

#if BOARD_HAS_AXP2101
#include "driver/i2c_master.h"
#include "power.h"
#endif

static const char *TAG = "vdisp";

#define TILE_QUEUE_LEN 64

/* Drain tiles, swap RGB565LE (wire) to the panel's big-endian order in
 * place, and push to the ST7796. Runs on core 0; USB RX runs on core 1. */
static void lcd_task(void *arg)
{
    QueueHandle_t q = (QueueHandle_t)arg;

    for (;;) {
        vd_tile_msg_t *msg = NULL;
        if (xQueueReceive(q, &msg, portMAX_DELAY) != pdTRUE || msg == NULL) {
            continue;
        }

        uint16_t *px = (uint16_t *)msg->payload;
        const size_t n = msg->hdr.payload_len / 2;
        for (size_t i = 0; i < n; i++) {
            px[i] = __builtin_bswap16(px[i]);
        }

        esp_lcd_panel_draw_bitmap(lcd_panel(), msg->hdr.x, msg->hdr.y,
                                  msg->hdr.x + msg->hdr.w,
                                  msg->hdr.y + msg->hdr.h, px);
        free(msg);
    }
}

void app_main(void)
{
#if BOARD_HAS_AXP2101
    const i2c_master_bus_config_t i2c_cfg = {
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .i2c_port = I2C_NUM_0,
        .sda_io_num = BOARD_PIN_I2C_SDA,
        .scl_io_num = BOARD_PIN_I2C_SCL,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    i2c_master_bus_handle_t i2c_bus = NULL;
    ESP_ERROR_CHECK(i2c_new_master_bus(&i2c_cfg, &i2c_bus));
    ESP_ERROR_CHECK(power_init(i2c_bus));
#endif

    ESP_ERROR_CHECK(lcd_init());
    lcd_backlight(200);

    QueueHandle_t tile_queue = xQueueCreate(TILE_QUEUE_LEN,
                                            sizeof(vd_tile_msg_t *));
    assert(tile_queue != NULL);

    xTaskCreatePinnedToCore(lcd_task, "lcd", 4096, tile_queue, 9, NULL, 0);

    ESP_ERROR_CHECK(usb_vendor_init(tile_queue));

    ESP_LOGI(TAG, "vdisp fw ready: %dx%d", BOARD_LCD_H_RES, BOARD_LCD_V_RES);
}
