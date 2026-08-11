#pragma once

#include <stdbool.h>

#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#include "protocol.h"

/* Brings up a SoftAP and serves the same tile stream over TCP.
 *
 * SoftAP rather than joining a network: it needs no credentials, lands on a
 * fixed address, and a Mac can hold it on Wi-Fi while keeping Ethernet for
 * everything else. The panel is at 192.168.4.1, port GLINT_NET_PORT. */
esp_err_t net_init(QueueHandle_t tile_queue);

#define GLINT_NET_PORT 7788

/* Sends an event to the connected client, if any. Same contract as the USB
 * version: false means it could not be queued, and STATS callers must not
 * record a report they failed to deliver. */
bool net_send_event(const glint_evt_t *evt);
