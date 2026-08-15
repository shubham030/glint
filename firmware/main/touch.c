#include "touch.h"

#include "board.h"
#include "driver/gpio.h"
#include "esp_check.h"
/* Everything below needs a touch controller. A board profile without one still
 * compiles this file, so the guard lives here rather than in the build: CMake
 * cannot see BOARD_HAS_TOUCH, which a custom profile defines in a header. */
#if BOARD_HAS_TOUCH

#if BOARD_HAS_FT6336
#include "ft6336.h"
#elif BOARD_HAS_CST9217
#include "esp_lcd_touch_cst9217.h"
#endif
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "protocol.h"
#include "usb_vendor.h"

static const char *TAG = "touch";

#define POLL_HZ        60
#define MAX_POINTS     2
#define MOVE_THRESHOLD 2 /* panel px; suppresses jitter on a still finger */

/* A report is an unordered set of positions, so contacts have to be tied to
 * slots somehow. The FT6336 supplies a hardware Touch ID per point, which is
 * exact; the vendored driver was discarding it (now fixed, see
 * esp_lcd_touch_ft6336.c) but some FT6x36 firmware reports 0x0F for an inactive
 * point and others never populate the nibble at all, so IDs are used only when
 * they look real and proximity remains the fallback. Without either, lifting
 * the first of two fingers renumbers the second. */
#define MATCH_RADIUS 60
#define TRACK_ID_NONE 0x0F

static esp_lcd_touch_handle_t s_tp;

typedef struct {
    bool down;
    bool has_id;
    uint8_t id;
    uint16_t x, y;
} point_state_t;

/* Nearest active slot within MATCH_RADIUS, skipping ones already taken this
 * cycle — a contact whose closest slot is claimed still belongs somewhere, and
 * bailing out here would drop it and fire a spurious UP. */
static int nearest_slot(
    const point_state_t *slots, const bool *claimed, uint16_t x, uint16_t y)
{
    int best = -1;
    long best_d2 = (long)MATCH_RADIUS * MATCH_RADIUS;

    for (int i = 0; i < MAX_POINTS; i++) {
        if (!slots[i].down || claimed[i]) {
            continue;
        }
        const long dx = (long)x - slots[i].x;
        const long dy = (long)y - slots[i].y;
        const long d2 = dx * dx + dy * dy;
        if (d2 < best_d2) { /* strict: an exact tie keeps the lower index */
            best_d2 = d2;
            best = i;
        }
    }
    return best;
}

/* Slot holding this hardware ID, if any. */
static int slot_by_id(
    const point_state_t *slots, const bool *claimed, uint8_t id)
{
    for (int i = 0; i < MAX_POINTS; i++) {
        if (slots[i].down && !claimed[i] && slots[i].has_id
            && slots[i].id == id) {
            return i;
        }
    }
    return -1;
}

/* IDs are only trustworthy when every reported point has a real one and they
 * are distinct; a driver that leaves the nibble at zero would collide. */
static bool ids_usable(const esp_lcd_touch_point_data_t *pts, uint8_t count)
{
    for (uint8_t i = 0; i < count; i++) {
        if (pts[i].track_id == TRACK_ID_NONE) {
            return false;
        }
        for (uint8_t j = 0; j < i; j++) {
            if (pts[i].track_id == pts[j].track_id) {
                return false;
            }
        }
    }
    return count > 0;
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
    glint_event_broadcast(&evt);
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
        const bool by_id = ids_usable(pts, count);

        for (uint8_t i = 0; i < count; i++) {
            const uint16_t x = pts[i].x;
            const uint16_t y = pts[i].y;

            const int slot = by_id
                                 ? slot_by_id(slots, claimed, pts[i].track_id)
                                 : nearest_slot(slots, claimed, x, y);

            if (slot < 0) {
                const int fresh = free_slot(slots, claimed);
                if (fresh < 0) {
                    continue; /* more contacts than slots: ignore the extra */
                }
                claimed[fresh] = true;
                slots[fresh].down = true;
                slots[fresh].has_id = by_id;
                slots[fresh].id = pts[i].track_id;
                slots[fresh].x = x;
                slots[fresh].y = y;
                emit(GLINT_EVT_DOWN, (uint8_t)fresh, x, y);
                continue;
            }

            claimed[slot] = true;
            /* Refresh the ID even on a proximity match, so a slot cannot keep a
             * stale one and be mismatched once IDs are usable again. */
            slots[slot].has_id = by_id;
            slots[slot].id = pts[i].track_id;

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

/* Set once the controller answers and the polling task is running. The
 * handshake reports it, so a host can say "this board has no touch" instead of
 * waiting for taps that cannot come. */
static bool s_available;

bool touch_available(void) { return s_available; }

/* Logs every device that answers on the bus. Called only when the touch
 * controller does not, because "touch init failed" on its own cannot tell a
 * wiring fault from the wrong driver: a board with a GT911 (0x5d/0x14) or a
 * CST816 (0x15) fails exactly like an absent FT6336 (0x38). The board has no
 * UART attached in normal use, so this is the one chance to say what is there.
 */
static void scan_bus(i2c_master_bus_handle_t bus)
{
    int found = 0;
    for (uint8_t addr = 0x08; addr < 0x78; addr++) {
        if (i2c_master_probe(bus, addr, 50) == ESP_OK) {
            ESP_LOGW(TAG, "  i2c device at 0x%02x", addr);
            found++;
        }
    }
    if (found == 0) {
        ESP_LOGW(TAG, "  nothing answered on the i2c bus at all");
    }
}

/* Pulses the controller's reset line and waits for it to boot.
 *
 * Not every driver does this: the registry FT6336 component leaves RST alone,
 * so the chip acknowledges its address while every register still reads 0x00
 * and the driver rejects it as an invalid vendor id. The pin is a board fact,
 * so the reset belongs here rather than in a driver. Datasheet asks for at
 * least 5 ms low; the chip is readable a couple of hundred milliseconds after
 * release.
 */
static void reset_controller(void)
{
#if defined(BOARD_PIN_TP_RST)
    if (BOARD_PIN_TP_RST == GPIO_NUM_NC) {
        return;
    }
    const gpio_config_t cfg = {
        .pin_bit_mask = 1ULL << BOARD_PIN_TP_RST,
        .mode = GPIO_MODE_OUTPUT,
    };
    if (gpio_config(&cfg) != ESP_OK) {
        return;
    }
    gpio_set_level(BOARD_PIN_TP_RST, 0);
    vTaskDelay(pdMS_TO_TICKS(10));
    gpio_set_level(BOARD_PIN_TP_RST, 1);
    vTaskDelay(pdMS_TO_TICKS(250));
#endif
}

/* Everything below the controller is shared: both drivers present the same
 * esp_lcd_touch interface, so the polling task, the slot matching and the event
 * emission do not know which chip is underneath. */
static esp_err_t new_controller(esp_lcd_panel_io_handle_t io,
                                const esp_lcd_touch_config_t *cfg)
{
#if BOARD_HAS_FT6336
    return ft6336_new(io, cfg, &s_tp);
#elif BOARD_HAS_CST9217
    return esp_lcd_touch_new_i2c_cst9217(io, cfg, &s_tp);
#else
    (void)io;
    (void)cfg;
    return ESP_ERR_NOT_SUPPORTED;
#endif
}

esp_err_t touch_init(i2c_master_bus_handle_t bus)
{
#if BOARD_HAS_FT6336
    esp_lcd_panel_io_i2c_config_t io_cfg = FT6336_IO_I2C_CONFIG();
#elif BOARD_HAS_CST9217
    esp_lcd_panel_io_i2c_config_t io_cfg = ESP_LCD_TOUCH_IO_I2C_CST9217_CONFIG();
#endif
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
    /* The driver drives RST and gives the controller time to come up, so it
     * must run before any probing: gating on a bare i2c probe first skipped a
     * chip that only answers *after* its reset pulse, and reported perfectly
     * good touch hardware as absent. Diagnose only once this has really
     * failed. */
    const esp_err_t err = new_controller(io, &cfg);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "%s init failed (%s) — scanning the i2c bus:",
                 BOARD_TOUCH_NAME, esp_err_to_name(err));
        scan_bus(bus);
        return err;
    }

    const BaseType_t ok =
        xTaskCreatePinnedToCore(touch_task, "touch", 4096, NULL, 5, NULL, 0);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "touch task");

    s_available = true;
    ESP_LOGI(TAG, "%s up (%dx%d, %d Hz)", BOARD_TOUCH_NAME, BOARD_LCD_H_RES,
             BOARD_LCD_V_RES, POLL_HZ);
    return ESP_OK;
}

#endif /* BOARD_HAS_TOUCH */
