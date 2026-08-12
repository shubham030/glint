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
#include "stream.h"

#if CONFIG_GLINT_ENABLE_WIFI
#include "net.h"
#endif
#include "tinyusb.h"
#include "tusb.h"

static const char *TAG = "usb_vendor";

#define FW_VERSION 0x00000100u

static QueueHandle_t s_tile_queue;
static SemaphoreHandle_t s_rx_sem;
static glint_stream_stats_t s_stats;

glint_stream_stats_t *glint_stats(void)
{
    return &s_stats;
}

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
        glint_hello_fill(&s_hello);
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
        glint_stream_reset(); /* also rewind the byte-stream parser */
        return tud_control_status(rhport, request);
    }

    case GLINT_CMD_SLEEP:
        lcd_sleep(request->wValue != 0);
        return tud_control_status(rhport, request);

    case GLINT_CMD_BOOTLOADER: {
        /* Ack first: the host should not see the transfer fail because we
         * rebooted mid-reply. */
        const glint_req_t req = {.cmd = GLINT_CMD_BOOTLOADER};
        tud_control_status(rhport, request);
        glint_stream_serve_request(NULL, &req, s_tile_queue);
        return true;
    }

    default:
        return false; /* stall unknown requests */
    }
}

/* ----------------------------------------------------------------- rx -- */

/* The parser holds position inside a tile across loop iterations, but the byte
 * stream does not survive a cable swap or a host restart: whatever it was
 * waiting for never arrives, and the next session's first bytes would be eaten
 * as the tail of a dead payload. Both USB mount transitions and CMD_RESET
 * therefore rewind it. (Without this it still recovers by rescanning for a
 * magic, but garbles a frame first — and on this board cables get swapped
 * constantly.) */

void tud_mount_cb(void)
{
    glint_stream_reset();
}

void tud_umount_cb(void)
{
    glint_stream_reset();
}

void tud_vendor_rx_cb(uint8_t itf, uint8_t const *buffer, uint16_t bufsize)
{
    (void)itf;
    (void)buffer; /* data is drained from the class FIFO in rx_task */
    (void)bufsize;
    xSemaphoreGive(s_rx_sem);
}

/* Transport adapter: hand the shared parser bytes from the class FIFO. */
static int usb_read(void *ctx, void *buf, size_t max)
{
    (void)ctx;
    if (max == 0) {
        return 0;
    }
    if (tud_vendor_available() == 0) {
        xSemaphoreTake(s_rx_sem, pdMS_TO_TICKS(100));
        return 0;
    }
    return (int)tud_vendor_read(buf, (uint32_t)max);
}

static void rx_task(void *arg)
{
    (void)arg;
    const glint_stream_io_t io = {
        .read = usb_read,
        .write = NULL, /* USB answers control out of band */
        .ctx = NULL,
        .name = "usb",
    };
    /* Never returns: usb_read reports 0 rather than an error when idle, so the
     * parser waits for the host instead of tearing down. */
    glint_stream_run(&io, s_tile_queue, &s_stats);
    vTaskDelete(NULL);
}

/* --------------------------------------------------------------- stats -- */

/* Report only when something changed: an idle link should be silent.
 *
 * The counters are read exactly once per tick and `last` only advances after
 * the event is actually queued. Reading them more than once would let an
 * increment land between reads and be recorded as already-reported, and
 * committing before the send would lose every report made while the host was
 * not draining bulk IN — which is the normal case, not a race. Either way the
 * loss is permanent and silent, and both hosts' resync depends on this signal.
 */
static void stats_task(void *arg)
{
    (void)arg;
    glint_stream_stats_t last = {0};

    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        const glint_stream_stats_t now = s_stats; /* one read, used throughout */
        const uint32_t dropped = now.tiles_dropped + now.seq_gaps;
        if (dropped == last.tiles_dropped + last.seq_gaps &&
            now.resyncs == last.resyncs) {
            continue;
        }

        const glint_evt_t evt = {
            .magic = GLINT_MAGIC_EVT,
            .type = GLINT_EVT_STATS,
            .id = 0,
            .x = (uint16_t)(dropped > 0xFFFF ? 0xFFFF : dropped),
            .y = (uint16_t)(now.resyncs > 0xFFFF ? 0xFFFF : now.resyncs),
            .rsvd = 0,
        };
        /* Either transport counts: a report that reached neither must not be
         * recorded as sent. */
        const bool told = glint_event_broadcast(&evt);
        if (told) {
            last = now;
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

    ESP_RETURN_ON_FALSE(
        xTaskCreatePinnedToCore(stats_task, "usb_stats", 3072, NULL, 3, NULL, 0)
            == pdPASS,
        ESP_ERR_NO_MEM, TAG, "stats task");

    ESP_LOGI(TAG, "vendor interface up (vid=%04x pid=%04x)", GLINT_USB_VID,
             GLINT_USB_PID);
    return ESP_OK;
}

bool glint_event_broadcast(const glint_evt_t *evt)
{
    /* Every event goes to both transports, because the host can be on either
     * and the device does not know which. Touch used to call the USB-only
     * sender directly, which made taps invisible to a network host while the
     * panel and its controller were working perfectly — a failure that looks
     * exactly like broken touch hardware.
     *
     * `||` is deliberately not short-circuiting the second send: the USB call
     * must still run when the network one succeeds. */
    bool told = usb_vendor_send_event(evt);
#if CONFIG_GLINT_ENABLE_WIFI
    told = net_send_event(evt) || told;
#endif
    return told;
}

bool usb_vendor_send_event(const glint_evt_t *evt)
{
    if (!tud_vendor_mounted()) {
        return false;
    }
    if (tud_vendor_write_available() < sizeof(*evt)) {
        return false; /* host not draining; see header */
    }
    if (tud_vendor_write(evt, sizeof(*evt)) != sizeof(*evt)) {
        return false;
    }
    tud_vendor_write_flush();
    return true;
}
