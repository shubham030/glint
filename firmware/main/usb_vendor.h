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
    uint32_t tiles_dropped; /* queue full, alloc failure, or bad RLE */
    uint32_t resyncs;       /* bad magic / insane header recoveries */
    uint32_t seq_gaps;      /* frames the host sent that never arrived */
} glint_usb_stats_t;

/* Install TinyUSB with the vendor interface and start the RX parser task.
 * Parsed tiles land on `tile_queue` (items: glint_tile_msg_t*). */
esp_err_t usb_vendor_init(QueueHandle_t tile_queue);

void usb_vendor_get_stats(glint_usb_stats_t *out);

/* Queue a 12-byte event on the bulk IN pipe. Returns false if it could not be
 * queued — no host mounted, or the IN FIFO is full because nothing is draining
 * it. Touch events can be dropped safely (state is re-sent on the next change),
 * but STATS callers must check the result: committing "reported" for an event
 * that never left would lose the loss report permanently. */
bool usb_vendor_send_event(const glint_evt_t *evt);
