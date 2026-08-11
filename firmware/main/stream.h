#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#include "protocol.h"

/* The tile parser is transport-agnostic: USB bulk and a TCP socket both deliver
 * the same magic-framed byte stream, split at arbitrary boundaries. A transport
 * supplies these two callbacks and the parser owns all framing, validation and
 * resynchronisation. */
typedef struct {
    /* Reads up to `max` bytes. Returns 0 when nothing is available yet (the
     * parser will call again) and negative when the link is gone. */
    int (*read)(void *ctx, void *buf, size_t max);
    /* Sends `len` bytes back — a HELLO reply, or events. May be NULL for a
     * transport that answers control out of band, as USB does. */
    bool (*write)(void *ctx, const void *buf, size_t len);
    void *ctx;
    const char *name; /* for logs */
} glint_stream_io_t;

typedef struct {
    uint32_t tiles_rx;
    uint32_t tiles_dropped;
    uint32_t resyncs;
    uint32_t seq_gaps;
} glint_stream_stats_t;

/* One parsed tile, allocated in PSRAM; the consumer frees it. */
typedef struct {
    glint_tile_hdr_t hdr;
    uint8_t payload[];
} glint_tile_msg_t;

/* Parses until the transport reports the link is gone. Parsed tiles are posted
 * to `tile_queue` as glint_tile_msg_t*. Counters accumulate into `stats`, which
 * may be shared with other transports. */
void glint_stream_run(const glint_stream_io_t *io, QueueHandle_t tile_queue,
                      glint_stream_stats_t *stats);

/* Discards any partially-received tile so the next header starts clean. Call on
 * connect/disconnect: a stream position cannot survive the peer going away. */
void glint_stream_reset(void);

/* Fills in the handshake this build advertises. Shared so USB control transfers
 * and in-band socket requests cannot describe the device differently. */
void glint_hello_fill(glint_hello_t *out);

/* Serves an in-band request (see glint_req_t). Returns false if the transport
 * could not be answered. */
bool glint_stream_serve_request(const glint_stream_io_t *io,
                                const glint_req_t *req,
                                QueueHandle_t tile_queue);
