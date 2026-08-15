/* FT6336-compatible capacitive touch, driving the esp_lcd_touch interface.
 *
 * Written here rather than pulled from a component because the panels this
 * firmware targets carry FT6x36-compatible parts whose identification
 * registers read back as zero. Drivers that gate initialisation on a vendor id
 * reject those chips outright, even though every touch register answers
 * correctly — the controller works, it simply will not say who it is. This
 * reads the data registers and nothing else.
 *
 * It also keeps the contact's track id, which the framework passes through as
 * esp_lcd_touch_point_data_t.track_id. Without it a report is an unordered set
 * of positions, so lifting one finger renumbers the others and the host has to
 * guess which contact moved where.
 *
 * Register map (FT6x36):
 *   0x02        number of contacts, low nibble
 *   0x03..0x06  contact 1: XH, XL, YH, YL
 *   0x09..0x0C  contact 2
 * XH's top two bits are the event flag; the low nibble is x's high bits.
 * YH's top nibble is the track id; the low nibble is y's high bits.
 */
#include "ft6336.h"

#include <string.h>

#include "driver/gpio.h"
#include "esp_check.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "ft6336";

#define REG_TOUCH_COUNT 0x02
#define REG_P1_BASE     0x03
#define REG_P2_BASE     0x09
#define POINT_STRIDE    6 /* 0x03 -> 0x09 */

/* Some parts report 0x0F in the id nibble for an unused contact. */
#define TRACK_ID_NONE 0x0F

static esp_err_t read_regs(esp_lcd_touch_handle_t tp, uint8_t reg, uint8_t *out,
                           size_t len)
{
    return esp_lcd_panel_io_rx_param(tp->io, reg, out, len);
}

static esp_err_t ft6336_read_data(esp_lcd_touch_handle_t tp)
{
    uint8_t count = 0;
    ESP_RETURN_ON_ERROR(read_regs(tp, REG_TOUCH_COUNT, &count, 1), TAG,
                        "touch count");
    count &= 0x0F;
    if (count > CONFIG_ESP_LCD_TOUCH_MAX_POINTS) {
        count = CONFIG_ESP_LCD_TOUCH_MAX_POINTS;
    }

    uint8_t ids[CONFIG_ESP_LCD_TOUCH_MAX_POINTS] = {0};
    uint16_t xs[CONFIG_ESP_LCD_TOUCH_MAX_POINTS] = {0};
    uint16_t ys[CONFIG_ESP_LCD_TOUCH_MAX_POINTS] = {0};

    for (uint8_t i = 0; i < count; i++) {
        uint8_t raw[4] = {0};
        const uint8_t base = (i == 0) ? REG_P1_BASE : REG_P2_BASE +
                                            (uint8_t)((i - 1) * POINT_STRIDE);
        ESP_RETURN_ON_ERROR(read_regs(tp, base, raw, sizeof(raw)), TAG,
                            "contact %u", i);
        xs[i] = (uint16_t)(((raw[0] & 0x0F) << 8) | raw[1]);
        ys[i] = (uint16_t)(((raw[2] & 0x0F) << 8) | raw[3]);
        ids[i] = (uint8_t)(raw[2] >> 4);
    }

    portENTER_CRITICAL(&tp->data.lock);
    tp->data.points = count;
    for (uint8_t i = 0; i < count; i++) {
        tp->data.coords[i].x = xs[i];
        tp->data.coords[i].y = ys[i];
        tp->data.coords[i].strength = 0;
        tp->data.coords[i].track_id = ids[i];
    }
    portEXIT_CRITICAL(&tp->data.lock);
    return ESP_OK;
}

static bool ft6336_get_xy(esp_lcd_touch_handle_t tp, uint16_t *x, uint16_t *y,
                          uint16_t *strength, uint8_t *point_num,
                          uint8_t max_point_num)
{
    portENTER_CRITICAL(&tp->data.lock);
    *point_num = (tp->data.points > max_point_num) ? max_point_num
                                                   : tp->data.points;
    for (uint8_t i = 0; i < *point_num; i++) {
        x[i] = tp->data.coords[i].x;
        y[i] = tp->data.coords[i].y;
        if (strength != NULL) {
            strength[i] = tp->data.coords[i].strength;
        }
    }
    tp->data.points = 0; /* consumed */
    portEXIT_CRITICAL(&tp->data.lock);
    return *point_num > 0;
}

static esp_err_t ft6336_get_track_id(esp_lcd_touch_handle_t tp,
                                     uint8_t *track_id, uint8_t point_num)
{
    portENTER_CRITICAL(&tp->data.lock);
    for (uint8_t i = 0; i < point_num; i++) {
        track_id[i] = tp->data.coords[i].track_id;
    }
    portEXIT_CRITICAL(&tp->data.lock);
    return ESP_OK;
}

static esp_err_t ft6336_del(esp_lcd_touch_handle_t tp)
{
    if (tp->config.rst_gpio_num != GPIO_NUM_NC) {
        gpio_reset_pin(tp->config.rst_gpio_num);
    }
    free(tp);
    return ESP_OK;
}

/* The controller answers its address while still in reset, with every register
 * reading zero, so the pulse has to happen before the first read. */
static void ft6336_reset(const esp_lcd_touch_config_t *config)
{
    if (config->rst_gpio_num == GPIO_NUM_NC) {
        return;
    }
    const gpio_config_t cfg = {
        .pin_bit_mask = 1ULL << config->rst_gpio_num,
        .mode = GPIO_MODE_OUTPUT,
    };
    if (gpio_config(&cfg) != ESP_OK) {
        return;
    }
    const uint32_t asserted = config->levels.reset ? 1 : 0;
    gpio_set_level(config->rst_gpio_num, asserted);
    vTaskDelay(pdMS_TO_TICKS(10));
    gpio_set_level(config->rst_gpio_num, !asserted);
    vTaskDelay(pdMS_TO_TICKS(200));
}

esp_err_t ft6336_new(const esp_lcd_panel_io_handle_t io,
                     const esp_lcd_touch_config_t *config,
                     esp_lcd_touch_handle_t *out_touch)
{
    ESP_RETURN_ON_FALSE(io && config && out_touch, ESP_ERR_INVALID_ARG, TAG,
                        "null argument");

    esp_lcd_touch_handle_t tp = calloc(1, sizeof(esp_lcd_touch_t));
    ESP_RETURN_ON_FALSE(tp != NULL, ESP_ERR_NO_MEM, TAG, "no memory");

    tp->io = io;
    tp->config = *config;
    tp->read_data = ft6336_read_data;
    tp->get_xy = ft6336_get_xy;
    tp->get_track_id = ft6336_get_track_id;
    tp->del = ft6336_del;
    portMUX_INITIALIZE(&tp->data.lock);

    ft6336_reset(config);

    /* One read proves the bus and the address; its value is deliberately not
     * checked against a vendor id, because the compatible parts these boards
     * ship report zero there. */
    uint8_t probe = 0;
    const esp_err_t err = read_regs(tp, REG_TOUCH_COUNT, &probe, 1);
    if (err != ESP_OK) {
        free(tp);
        ESP_LOGE(TAG, "no answer at the touch address: %s",
                 esp_err_to_name(err));
        return err;
    }

    ESP_LOGI(TAG, "up (%dx%d)", config->x_max, config->y_max);
    *out_touch = tp;
    return ESP_OK;
}
