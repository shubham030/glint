#pragma once

#include <stdint.h>

#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#include "protocol.h"

/* One parsed tile, heap-allocated in PSRAM; consumer frees. Payload is
 * byte-swapped to panel order (big-endian RGB565) by the LCD task, not here. */
typedef struct {
    glint_tile_hdr_t hdr;
    uint8_t payload[];
} glint_tile_msg_t;

typedef struct {
    uint32_t tiles_rx;
    uint32_t tiles_dropped; /* queue full */
    uint32_t resyncs;       /* bad magic recoveries */
} glint_usb_stats_t;

/* Install TinyUSB with the vendor interface and start the RX parser task.
 * Parsed tiles land on `tile_queue` (items: glint_tile_msg_t*). */
esp_err_t usb_vendor_init(QueueHandle_t tile_queue);

void usb_vendor_get_stats(glint_usb_stats_t *out);

/* Queue a 12-byte event on the bulk IN pipe. Dropped if the host isn't
 * draining — touch state is re-sent on the next change, so a lost MOVE is
 * harmless (a lost UP is corrected by the next DOWN). */
void usb_vendor_send_event(const glint_evt_t *evt);
