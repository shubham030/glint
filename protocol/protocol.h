/*
 * vdisp wire protocol — single source of truth for README.md §5.
 *
 * Little-endian throughout. Deviations from the original design doc:
 *
 *  - vd_tile_hdr_t is 24 bytes, not 20: the doc's own field list sums to 24.
 *  - HELLO is returned as the IN data stage of CMD_HELLO (a vendor control
 *    read), not as an async bulk-IN event. The host must know geometry before
 *    it can do anything; a synchronous control read is the natural shape.
 *    VD_EVT_HELLO stays reserved for a future device-initiated re-announce.
 */
#pragma once

#include <stdint.h>

#define VD_USB_VID 0xCAFE /* TinyUSB test VID — fine for personal use */
#define VD_USB_PID 0x4010

#define VD_MAGIC_HELLO 0x4C483450u /* 'P4HL' */
#define VD_MAGIC_TILE  0x44543450u /* 'P4TD' */
#define VD_MAGIC_EVT   0x56453450u /* 'P4EV' */

#define VD_PROTO_VER 1

/* fmt values; fmt_mask advertises support as (1 << fmt) */
#define VD_FMT_RGB565     0 /* raw RGB565, little-endian on the wire */
#define VD_FMT_RGB565_RLE 1
#define VD_FMT_JPEG       2

/* vd_tile_hdr_t.flags */
#define VD_TILE_LAST_IN_FRAME (1u << 0)
#define VD_TILE_FULL_REFRESH  (1u << 1)

/* vd_evt_t.type */
#define VD_EVT_DOWN  1
#define VD_EVT_MOVE  2
#define VD_EVT_UP    3
#define VD_EVT_HELLO 4
#define VD_EVT_STATS 5

/* Vendor control bRequest (bmRequestType: vendor | interface) */
#define VD_CMD_HELLO     0x01 /* IN, returns vd_hello_t */
#define VD_CMD_BACKLIGHT 0x02 /* OUT, wValue = 0..255 */
#define VD_CMD_RESET     0x03 /* OUT, drop state, force full refresh */
#define VD_CMD_SLEEP     0x04 /* OUT, wValue 1=panel off 0=panel on */

#pragma pack(push, 1)

typedef struct {
    uint32_t magic;        /* VD_MAGIC_HELLO */
    uint16_t proto_ver;    /* VD_PROTO_VER */
    uint16_t panel_w;
    uint16_t panel_h;
    uint16_t fmt_mask;
    uint32_t max_tile_len; /* largest single payload the device accepts */
    uint16_t touch_points;
    uint16_t rsvd;
    uint32_t fw_ver;
} vd_hello_t;

typedef struct {
    uint32_t magic;        /* VD_MAGIC_TILE */
    uint16_t seq;          /* frame sequence, wraps */
    uint16_t flags;
    uint16_t x, y;         /* top-left, panel coords */
    uint16_t w, h;
    uint16_t fmt;
    uint16_t rsvd;
    uint32_t payload_len;  /* bytes following this header */
} vd_tile_hdr_t;

typedef struct {
    uint32_t magic;        /* VD_MAGIC_EVT */
    uint8_t  type;
    uint8_t  id;           /* touch point id */
    uint16_t x, y;
    uint16_t rsvd;
} vd_evt_t;

#pragma pack(pop)

_Static_assert(sizeof(vd_hello_t) == 24, "hello must be 24 bytes");
_Static_assert(sizeof(vd_tile_hdr_t) == 24, "tile header must be 24 bytes");
_Static_assert(sizeof(vd_evt_t) == 12, "event must be 12 bytes");
