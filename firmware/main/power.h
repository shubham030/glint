/* AXP2101 PMU bring-up, verbatim from the Waveshare factory demo
 * (esp_axp2101_port.cpp). C-callable; the XPowersLib C++ guts stay in
 * power.cpp. */
#pragma once

#include "driver/i2c_master.h"
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t power_init(i2c_master_bus_handle_t bus_handle);
void pmu_isr_handler(void);

#ifdef __cplusplus
}
#endif
