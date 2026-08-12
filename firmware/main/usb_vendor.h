#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#include "protocol.h"
#include "stream.h"

/* Install TinyUSB with the vendor interface and start the RX parser task.
 * Parsed tiles land on `tile_queue` (items: glint_tile_msg_t*), framed by the
 * shared parser in stream.c — USB and the network feed the same code. */
esp_err_t usb_vendor_init(QueueHandle_t tile_queue);

/* Counters shared with every transport, so STATS reports the whole picture. */
glint_stream_stats_t *glint_stats(void);

/* Queue a 12-byte event on the bulk IN pipe. Returns false if it could not be
 * queued — no host mounted, or the IN FIFO is full because nothing is draining
 * it. Touch events can be dropped safely (state is re-sent on the next change),
 * but STATS callers must check the result: committing "reported" for an event
 * that never left would lose the loss report permanently. */
bool usb_vendor_send_event(const glint_evt_t *evt);

/* Sends an event to every live transport, USB and network. This is what event
 * producers should call; the USB-only variant above is one half of it. */
bool glint_event_broadcast(const glint_evt_t *evt);
