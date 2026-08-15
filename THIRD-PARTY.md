# Third-party code

The MIT licence in [LICENSE](LICENSE) covers this repository's own code. These
components are other people's work and keep their own terms.

## Vendored in this repository

| Component | Licence | Notes |
|---|---|---|
| `firmware/components/XPowersLib` | MIT | AXP2101 PMU driver; licence file included |

## Fetched by the build

The ESP-IDF component manager downloads these into
`firmware/managed_components/` from the [component
registry](https://components.espressif.com); each arrives with its own licence
file and none is redistributed here.

| Component | Licence |
|---|---|
| `espressif/esp_tinyusb`, `espressif/tinyusb` | MIT / Apache-2.0 |
| `espressif/esp_lcd_st7796`, `esp_lcd_co5300`, `esp_lcd_touch` | Apache-2.0 |
| `waveshare/esp_lcd_touch_cst9217` | Apache-2.0 |
| `espressif/mdns`, `esp_wifi_remote`, `esp_hosted` | Apache-2.0 |

ESP-IDF itself is Apache-2.0. The macOS host links libusb (LGPL-2.1) at run
time, installed separately with Homebrew. The Linux and Windows host has no
dependencies at all.
