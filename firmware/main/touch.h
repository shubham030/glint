#pragma once

#include "driver/i2c_master.h"
#include "esp_err.h"

/* Start the FT6336 poll task; emits touch events on the vendor bulk IN pipe.
 * Coordinates are panel-native (0..319, 0..479) — the host owns the mapping
 * to display space, since only it knows the rotation in use. */
esp_err_t touch_init(i2c_master_bus_handle_t bus);

/* Whether the touch controller came up. False on a board with no touch driver,
 * and on one whose controller did not answer. */
bool touch_available(void);
