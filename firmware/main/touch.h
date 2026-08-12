#pragma once

#include <stdbool.h>

#include "board.h"
#include "driver/i2c_master.h"
#include "esp_err.h"

/* Start the FT6336 poll task; emits touch events on the vendor bulk IN pipe.
 * Coordinates are panel-native (0..319, 0..479) — the host owns the mapping
 * to display space, since only it knows the rotation in use. */
esp_err_t touch_init(i2c_master_bus_handle_t bus);

/* Whether the touch controller came up. False on a board with no touch driver,
 * and on one whose controller did not answer.
 *
 * touch.c is only compiled for boards with a driver (see main/CMakeLists.txt),
 * so the others need the answer without the translation unit — hence the inline
 * false rather than a link-time error. */
#if BOARD_HAS_FT6336
bool touch_available(void);
#else
static inline bool touch_available(void) { return false; }
#endif
