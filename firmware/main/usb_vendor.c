#include "usb_vendor.h"

#include <string.h>
#include <sys/param.h>

#include "board.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lcd.h"
#include "tinyusb.h"
#include "tusb.h"

static const char *TAG = "usb_vendor";

#define FW_VERSION 0x00000100u

static QueueHandle_t s_tile_queue;
static SemaphoreHandle_t s_rx_sem;
static glint_usb_stats_t s_stats;

/* ---------------------------------------------------------------- desc -- */

enum {
    STRID_LANGID = 0,
    STRID_MANUFACTURER,
    STRID_PRODUCT,
    STRID_SERIAL,
    STRID_VENDOR_ITF,
};

static const tusb_desc_device_t s_device_desc = {
    .bLength = sizeof(tusb_desc_device_t),
    .bDescriptorType = TUSB_DESC_DEVICE,
    .bcdUSB = 0x0200,
    .bDeviceClass = 0x00, /* per-interface */
    .bDeviceSubClass = 0x00,
    .bDeviceProtocol = 0x00,
    .bMaxPacketSize0 = CFG_TUD_ENDPOINT0_SIZE,
    .idVendor = GLINT_USB_VID,
    .idProduct = GLINT_USB_PID,
    .bcdDevice = 0x0001,
    .iManufacturer = STRID_MANUFACTURER,
    .iProduct = STRID_PRODUCT,
    .iSerialNumber = STRID_SERIAL,
    .bNumConfigurations = 1,
};

#define EPNUM_VENDOR_OUT 0x01
#define EPNUM_VENDOR_IN  0x81

#define CONFIG_TOTAL_LEN (TUD_CONFIG_DESC_LEN + TUD_VENDOR_DESC_LEN)

/* Pure vendor-specific interface — nothing for the OS to claim (§10). */
static const uint8_t s_config_desc[] = {
    TUD_CONFIG_DESCRIPTOR(1, 1, 0, CONFIG_TOTAL_LEN, 0, 500),
    TUD_VENDOR_DESCRIPTOR(0, STRID_VENDOR_ITF, EPNUM_VENDOR_OUT,
                          EPNUM_VENDOR_IN, 64),
};

#if TUD_OPT_HIGH_SPEED
/* P4: same interface at High Speed — bulk max packet becomes 512. */
static const uint8_t s_config_desc_hs[] = {
    TUD_CONFIG_DESCRIPTOR(1, 1, 0, CONFIG_TOTAL_LEN, 0, 500),
    TUD_VENDOR_DESCRIPTOR(0, STRID_VENDOR_ITF, EPNUM_VENDOR_OUT,
                          EPNUM_VENDOR_IN, 512),
};

static const tusb_desc_device_qualifier_t s_qualifier = {
    .bLength = sizeof(tusb_desc_device_qualifier_t),
    .bDescriptorType = TUSB_DESC_DEVICE_QUALIFIER,
    .bcdUSB = 0x0200,
    .bDeviceClass = 0x00,
    .bDeviceSubClass = 0x00,
    .bDeviceProtocol = 0x00,
    .bMaxPacketSize0 = CFG_TUD_ENDPOINT0_SIZE,
    .bNumConfigurations = 1,
    .bReserved = 0,
};
#endif

static const char *s_string_desc[] = {
    (const char[]){0x09, 0x04}, /* 0: en-US */
    "shubham030",               /* 1: manufacturer */
    "glint",                    /* 2: product */
    "glint-000001",             /* 3: serial */
    "glint vendor interface",   /* 4 */
};

/* ------------------------------------------------------------- control -- */

static glint_hello_t s_hello; /* static: must outlive the control xfer */

bool tud_vendor_control_xfer_cb(uint8_t rhport, uint8_t stage,
                                tusb_control_request_t const *request)
{
    if (request->bmRequestType_bit.type != TUSB_REQ_TYPE_VENDOR) {
        return false;
    }
    if (stage != CONTROL_STAGE_SETUP) {
        return true; /* nothing to do in DATA/ACK stages */
    }

    switch (request->bRequest) {
    case GLINT_CMD_HELLO:
        s_hello = (glint_hello_t){
            .magic = GLINT_MAGIC_HELLO,
            .proto_ver = GLINT_PROTO_VER,
            .panel_w = BOARD_LCD_H_RES,
            .panel_h = BOARD_LCD_V_RES,
            .fmt_mask = 1u << GLINT_FMT_RGB565,
            .max_tile_len = BOARD_MAX_TILE_LEN,
            .touch_points = 2,
            .rsvd = 0,
            .fw_ver = FW_VERSION,
        };
        return tud_control_xfer(rhport, request, &s_hello, sizeof(s_hello));

    case GLINT_CMD_BACKLIGHT:
        lcd_backlight((uint8_t)(request->wValue & 0xFF));
        return tud_control_status(rhport, request);

    case GLINT_CMD_RESET: {
        /* Drop anything queued; the host follows with a FULL_REFRESH frame. */
        glint_tile_msg_t *msg;
        while (xQueueReceive(s_tile_queue, &msg, 0) == pdTRUE) {
            free(msg);
        }
        return tud_control_status(rhport, request);
    }

    case GLINT_CMD_SLEEP:
        lcd_sleep(request->wValue != 0);
        return tud_control_status(rhport, request);

    default:
        return false; /* stall unknown requests */
    }
}

/* ----------------------------------------------------------------- rx -- */

void tud_vendor_rx_cb(uint8_t itf, uint8_t const *buffer, uint16_t bufsize)
{
    (void)itf;
    (void)buffer; /* data is drained from the class FIFO in rx_task */
    (void)bufsize;
    xSemaphoreGive(s_rx_sem);
}

typedef enum {
    RX_HDR,
    RX_PAYLOAD,
} rx_state_t;

static void rx_task(void *arg)
{
    (void)arg;

    rx_state_t state = RX_HDR;
    uint8_t hdr_buf[sizeof(glint_tile_hdr_t)];
    size_t hdr_fill = 0;
    glint_tile_msg_t *cur = NULL; /* NULL in RX_PAYLOAD = sink (alloc failed) */
    uint32_t want = 0;
    size_t pay_fill = 0;

    for (;;) {
        if (tud_vendor_available() == 0) {
            xSemaphoreTake(s_rx_sem, pdMS_TO_TICKS(100));
            continue;
        }

        if (state == RX_HDR) {
            const uint32_t got = tud_vendor_read(hdr_buf + hdr_fill,
                                                sizeof(hdr_buf) - hdr_fill);
            hdr_fill += got;
            if (hdr_fill < sizeof(hdr_buf)) {
                continue;
            }

            glint_tile_hdr_t hdr;
            memcpy(&hdr, hdr_buf, sizeof(hdr));
            if (hdr.magic != GLINT_MAGIC_TILE) {
                /* Resync: slide the window one byte and keep scanning. */
                memmove(hdr_buf, hdr_buf + 1, sizeof(hdr_buf) - 1);
                hdr_fill = sizeof(hdr_buf) - 1;
                s_stats.resyncs++;
                continue;
            }
            hdr_fill = 0;

            const bool sane = hdr.fmt == GLINT_FMT_RGB565 &&
                              hdr.payload_len > 0 &&
                              hdr.payload_len <= BOARD_MAX_TILE_LEN &&
                              hdr.payload_len == (uint32_t)hdr.w * hdr.h * 2 &&
                              hdr.x + hdr.w <= BOARD_LCD_H_RES &&
                              hdr.y + hdr.h <= BOARD_LCD_V_RES;
            if (!sane) {
                ESP_LOGW(TAG, "insane tile %ux%u@%u,%u fmt=%u len=%lu",
                         hdr.w, hdr.h, hdr.x, hdr.y, hdr.fmt,
                         (unsigned long)hdr.payload_len);
                s_stats.resyncs++;
                continue; /* header was valid-magic garbage; rescan stream */
            }

            cur = heap_caps_malloc(sizeof(glint_tile_msg_t) + hdr.payload_len,
                                   MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
            if (cur == NULL) {
                ESP_LOGE(TAG, "tile alloc %lu failed",
                         (unsigned long)hdr.payload_len);
                s_stats.tiles_dropped++;
                /* fall through to payload state with a null sink */
            } else {
                cur->hdr = hdr;
            }
            want = hdr.payload_len;
            pay_fill = 0;
            state = RX_PAYLOAD;
        } else {
            uint8_t sink[512];
            uint8_t *dst = (cur != NULL) ? cur->payload + pay_fill : sink;
            const size_t room = (cur != NULL) ? (want - pay_fill)
                                              : MIN(sizeof(sink),
                                                    (size_t)(want - pay_fill));
            const uint32_t got = tud_vendor_read(dst, room);
            pay_fill += got;

            if (pay_fill >= want) {
                if (cur != NULL) {
                    if (xQueueSend(s_tile_queue, &cur, 0) != pdTRUE) {
                        free(cur);
                        s_stats.tiles_dropped++;
                    } else {
                        s_stats.tiles_rx++;
                    }
                    cur = NULL;
                }
                state = RX_HDR;
            }
        }
    }
}

/* --------------------------------------------------------------- init -- */

esp_err_t usb_vendor_init(QueueHandle_t tile_queue)
{
    s_tile_queue = tile_queue;
    s_rx_sem = xSemaphoreCreateBinary();
    ESP_RETURN_ON_FALSE(s_rx_sem != NULL, ESP_ERR_NO_MEM, TAG, "sem");

    const tinyusb_config_t tusb_cfg = {
        .device_descriptor = &s_device_desc,
        .string_descriptor = s_string_desc,
        .string_descriptor_count =
            sizeof(s_string_desc) / sizeof(s_string_desc[0]),
        .external_phy = false,
#if TUD_OPT_HIGH_SPEED
        .fs_configuration_descriptor = s_config_desc,
        .hs_configuration_descriptor = s_config_desc_hs,
        .qualifier_descriptor = &s_qualifier,
#else
        .configuration_descriptor = s_config_desc,
#endif
    };
    ESP_RETURN_ON_ERROR(tinyusb_driver_install(&tusb_cfg), TAG, "tusb install");

    const BaseType_t ok = xTaskCreatePinnedToCore(rx_task, "usb_rx", 4096, NULL,
                                                  10, NULL, 1);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "rx task");

    ESP_LOGI(TAG, "vendor interface up (vid=%04x pid=%04x)", GLINT_USB_VID,
             GLINT_USB_PID);
    return ESP_OK;
}

void usb_vendor_get_stats(glint_usb_stats_t *out)
{
    *out = s_stats;
}
