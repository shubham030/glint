#include "stream.h"

#include <string.h>
#include <sys/param.h>

#include "board.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_system.h"
#include "lcd.h"
#include "rle.h"
#include "touch.h"



static const char *TAG = "stream";

#define FW_VERSION 0x00000100u

/* Compressed payloads are expanded through here. Parsing is single-threaded per
 * transport, but two transports could parse at once, so this is per-call. */
typedef struct {
    uint8_t *rle_scratch;
    bool have_seq;
    uint16_t last_seq;
} parser_state_t;

static volatile bool s_reset_requested;

/* Asks the next boot to leave USB as the ROM's serial/JTAG device instead of
 * claiming it for TinyUSB, so esptool can connect and flash normally.
 *
 * Deliberately NOT the RTC force-download strap: that bit survives every reset
 * and only clears on true power loss, so setting it strands the board in the
 * loader until it is physically unplugged — worse than the button it replaces.
 * An RTC_NOINIT flag survives the soft restart we are about to do and is
 * cleared by the boot that honours it, making it genuinely one-shot. */
static void glint_reboot_to_loader(void)
{
    glint_request_serial_boot();
    esp_restart();
}

void glint_stream_reset(void)
{
    s_reset_requested = true;
}

static bool header_is_sane(const glint_tile_hdr_t *hdr, uint32_t decoded_len,
                          bool have_scratch)
{
    if (hdr->w == 0 || hdr->h == 0 || hdr->payload_len == 0) {
        return false;
    }
    /* Bound the geometry before trusting decoded_len: w*h*2 is computed in
     * uint32 and a crafted 16-bit w/h pair could wrap it to a small value. */
    if (hdr->x + hdr->w > BOARD_LCD_H_RES ||
        hdr->y + hdr->h > BOARD_LCD_V_RES) {
        return false;
    }
    if (decoded_len > BOARD_MAX_TILE_LEN) {
        return false;
    }
    switch (hdr->fmt) {
    case GLINT_FMT_RGB565:
        return hdr->payload_len == decoded_len;
    case GLINT_FMT_RGB565_RLE:
        return have_scratch && hdr->payload_len <= decoded_len;
    default:
        return false;
    }
}

/* Low 16 bits of the factory MAC: stable across reboots and reflashes, and
 * different on every board. */
static uint16_t glint_device_id(void)
{
    uint8_t mac[6] = {0};
    if (esp_read_mac(mac, ESP_MAC_EFUSE_FACTORY) != ESP_OK) {
        return 0;
    }
    return (uint16_t)((mac[4] << 8) | mac[5]);
}

void glint_hello_fill(glint_hello_t *out)
{
    *out = (glint_hello_t){
        .magic = GLINT_MAGIC_HELLO,
        .proto_ver = GLINT_PROTO_VER,
        .panel_w = BOARD_LCD_H_RES,
        .panel_h = BOARD_LCD_V_RES,
        .fmt_mask = (1u << GLINT_FMT_RGB565) | (1u << GLINT_FMT_RGB565_RLE),
        .max_tile_len = BOARD_MAX_TILE_LEN,
        /* Reported honestly: a host that sees 0 knows not to wait for taps. */
        .touch_points = touch_available() ? 2 : 0,
        .dev_id = glint_device_id(),
        .fw_ver = FW_VERSION,
    };
}

bool glint_stream_serve_request(const glint_stream_io_t *io,
                               const glint_req_t *req,
                               QueueHandle_t tile_queue)
{
    switch (req->cmd) {
    case GLINT_CMD_HELLO: {
        if (io->write == NULL) {
            return false;
        }
        glint_hello_t hello;
        glint_hello_fill(&hello);
        return io->write(io->ctx, &hello, sizeof(hello));
    }
    case GLINT_CMD_BACKLIGHT:
        lcd_backlight((uint8_t)(req->value & 0xFF));
        return true;
    case GLINT_CMD_RESET: {
        glint_tile_msg_t *msg;
        while (xQueueReceive(tile_queue, &msg, 0) == pdTRUE) {
            free(msg);
        }
        glint_stream_reset();
        return true;
    }
    case GLINT_CMD_SLEEP:
        lcd_sleep(req->value != 0);
        return true;
    case GLINT_CMD_BOOTLOADER:
        /* This board has no UART bridge, so without this a reflash means
         * physically holding BOOT while tapping RESET. Forcing the download
         * strap in RTC and restarting gets there from software. */
        ESP_LOGW(TAG, "rebooting into the download loader on request");
        vTaskDelay(pdMS_TO_TICKS(50)); /* let the reply/log drain first */
        glint_reboot_to_loader();
        return true;
    default:
        ESP_LOGW(TAG, "unknown in-band request 0x%02x", req->cmd);
        return false;
    }
}

typedef enum {
    RX_HDR,
    RX_PAYLOAD,
} rx_state_t;

void glint_stream_run(const glint_stream_io_t *io, QueueHandle_t tile_queue,
                      glint_stream_stats_t *stats)
{
    parser_state_t st = {0};
    st.rle_scratch = heap_caps_malloc(BOARD_MAX_TILE_LEN,
                                     MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (st.rle_scratch == NULL) {
        ESP_LOGW(TAG, "%s: no RLE scratch — compressed tiles refused",
                 io->name);
    }

    rx_state_t state = RX_HDR;
    /* One header's worth of window, so a false magic can be slid past. */
    uint8_t hdr_buf[sizeof(glint_tile_hdr_t)];
    size_t hdr_fill = 0;
    glint_tile_msg_t *cur = NULL;
    uint8_t *dst_base = NULL;
    uint32_t want = 0;
    uint32_t decoded_len = 0;
    uint16_t fmt = GLINT_FMT_RGB565;
    size_t pay_fill = 0;

    for (;;) {
        if (s_reset_requested) {
            s_reset_requested = false;
            state = RX_HDR;
            hdr_fill = 0;
            pay_fill = 0;
            dst_base = NULL;
            st.have_seq = false;
            free(cur);
            cur = NULL;
        }

        if (state == RX_HDR) {
            const int got = io->read(io->ctx, hdr_buf + hdr_fill,
                                     sizeof(hdr_buf) - hdr_fill);
            if (got < 0) {
                break;
            }
            hdr_fill += (size_t)got;

            /* Decide as soon as the magic is in: an in-band request is only 8
             * bytes, so waiting for a full 24-byte tile header first would
             * deadlock against a host that sends a request and then waits for
             * its reply. */
            if (hdr_fill < sizeof(uint32_t)) {
                continue;
            }
            uint32_t magic;
            memcpy(&magic, hdr_buf, sizeof(magic));

            if (magic == GLINT_MAGIC_REQ) {
                if (hdr_fill < sizeof(glint_req_t)) {
                    continue; /* rest of the request still in flight */
                }
                glint_req_t req;
                memcpy(&req, hdr_buf, sizeof(req));
                glint_stream_serve_request(io, &req, tile_queue);
                const size_t left = hdr_fill - sizeof(req);
                memmove(hdr_buf, hdr_buf + sizeof(req), left);
                hdr_fill = left;
                continue;
            }

            if (magic != GLINT_MAGIC_TILE) {
                /* Slide one byte: a false magic can appear inside pixel data. */
                memmove(hdr_buf, hdr_buf + 1, hdr_fill - 1);
                hdr_fill -= 1;
                stats->resyncs++;
                continue;
            }
            if (hdr_fill < sizeof(hdr_buf)) {
                continue; /* a tile needs the whole header before validation */
            }

            glint_tile_hdr_t hdr;
            memcpy(&hdr, hdr_buf, sizeof(hdr));
            decoded_len = (uint32_t)hdr.w * hdr.h * 2;
            const bool usable =
                header_is_sane(&hdr, decoded_len, st.rle_scratch != NULL);
            if (!usable) {
                /* Slide one byte: the magic can occur by chance inside pixel
                 * data, and the window is exactly one header long, so
                 * discarding it whole could swallow a real header. */
                memmove(hdr_buf, hdr_buf + 1, sizeof(hdr_buf) - 1);
                hdr_fill = sizeof(hdr_buf) - 1;
                stats->resyncs++;
                continue;
            }
            hdr_fill = 0;

            if (st.have_seq && hdr.seq != st.last_seq &&
                hdr.seq != (uint16_t)(st.last_seq + 1)) {
                stats->seq_gaps++;
            }
            st.last_seq = hdr.seq;
            st.have_seq = true;

            fmt = hdr.fmt;
            cur = heap_caps_malloc(sizeof(glint_tile_msg_t) + decoded_len,
                                   MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
            if (cur == NULL) {
                stats->tiles_dropped++;
                dst_base = NULL;
            } else {
                cur->hdr = hdr;
                cur->hdr.fmt = GLINT_FMT_RGB565; /* the LCD task sees raw */
                cur->hdr.payload_len = decoded_len;
                dst_base = (fmt == GLINT_FMT_RGB565_RLE) ? st.rle_scratch
                                                         : cur->payload;
            }
            want = hdr.payload_len;
            pay_fill = 0;
            state = RX_PAYLOAD;
            continue;
        }

        uint8_t sink[512];
        uint8_t *dst = (dst_base != NULL) ? dst_base + pay_fill : sink;
        const size_t room = (dst_base != NULL)
                                ? (want - pay_fill)
                                : MIN(sizeof(sink), (size_t)(want - pay_fill));
        const int got = io->read(io->ctx, dst, room);
        if (got < 0) {
            break;
        }
        pay_fill += (size_t)got;
        if (pay_fill < want) {
            continue;
        }

        if (cur != NULL) {
            bool ok = true;
            if (fmt == GLINT_FMT_RGB565_RLE) {
                const int px = rle_decode(st.rle_scratch, want,
                                          (uint16_t *)cur->payload,
                                          decoded_len / 2);
                ok = px == (int)(decoded_len / 2);
                if (!ok) {
                    stats->resyncs++;
                }
            }
            if (!ok || xQueueSend(tile_queue, &cur, 0) != pdTRUE) {
                /* Either way this region is now stale, and tiles_dropped is
                 * the counter the host watches to force a full refresh. */
                stats->tiles_dropped++;
                free(cur);
            } else {
                stats->tiles_rx++;
            }
            cur = NULL;
        }
        dst_base = NULL;
        state = RX_HDR;
    }

    ESP_LOGI(TAG, "%s: link closed", io->name);
    free(cur);
    free(st.rle_scratch);
}
