# Actual hardware — ESP32-S3-Touch-LCD-3.5

The design doc names a "Waveshare ESP32-P4-WIFI6-Touch-LCD-3.5". Checked
2026-08-08: Waveshare's complete wiki catalogue has no P4 3.5" board — the P4
touch-LCD lineup is 3.4C (round, DSI), 4B, 4C, 7B. The doc's panel spec
(3.5" ST7796 SPI + FT6336, 320×480, ~165 PPI) is the
**[ESP32-S3-Touch-LCD-3.5](https://www.waveshare.com/wiki/ESP32-S3-Touch-LCD-3.5)**,
which is what the firmware targets.

## What changes vs. the design doc

**The §3 bottleneck flips.** The S3 has USB OTG **Full Speed only** — 12 Mbps
on the wire, ~1 MB/s of real bulk throughput. SPI at 80 MHz (~8–10 MB/s) is
now the *fast* side:

| Path | Throughput | Full 320×480 RGB565 frame (307KB) |
|---|---|---|
| USB FS bulk, real | ~1 MB/s | **~3 fps** |
| SPI @ 80MHz, real | ~7–8 MB/s | 15–25 fps |

Consequences:

- Dirty-rect tiling (M4) matters even more than the doc claims — full-frame
  updates are ~3 fps, so *everything* rides on update locality.
- `RGB565_RLE` (fmt 1, already reserved in the protocol) is worth implementing
  early — flat UI regions compress 10–50×, and the decode cost on the S3 is
  trivial against a 1 MB/s wire.
- §8 (DSI upgrade, hardware JPEG) does not apply to this board. The upgrade
  path is a future P4+DSI board — which the handshake already accommodates.
- The doc's advice stands: this is a status panel for mostly-static content.

**No second USB port.** The S3 exposes one USB OTG (GPIO19/20) on the Type-C.
The same connector carries either the vendor interface (our firmware) or the
USB-Serial-JTAG console (ROM/IDF default) — flashing and the vendor link share
the port. `idf.py flash` works over USB-Serial-JTAG in the bootloader
regardless of what the app firmware does with the OTG controller (hold BOOT +
tap RESET if the app has claimed it).

## Board facts (from the Waveshare factory demo, `01_factory`)

| | |
|---|---|
| SoC | ESP32-S3R8 (QFN56), 8MB octal PSRAM, 240 MHz |
| Flash | W25Q128 16MB NOR |
| PMU | AXP2101 @ I2C 0x34 — rails must be enabled before the panel works |
| Codec / IMU / RTC | ES8311, QMI8658, PCF85063 (unused here) |
| Panel | ST7796, SPI2_HOST @ 80 MHz (factory demo runs 80 MHz), BGR order, colour-inverted, 16bpp |
| Touch | FT6336 @ I2C 0x38, 2-point |

### Pins

| Function | GPIO |
|---|---|
| LCD MOSI | 1 |
| LCD SCLK | 5 |
| LCD DC | 3 |
| LCD CS | none (tied active on-board) |
| LCD RST | none (power-cycle via PMU) |
| LCD backlight | 6 (LEDC PWM, 5 kHz, 10-bit) |
| I2C SDA | 8 |
| I2C SCL | 7 |
| USB D− / D+ | 19 / 20 (fixed OTG pins) |

### Power-up order

AXP2101 rail init (voltages + enables exactly as the factory demo:
`firmware/main/power.cpp`, vendored `XPowersLib`) → backlight LEDC → SPI bus →
panel init (BGR, invert, disp_on). Skipping the PMU step leaves the panel dark
regardless of SPI traffic.

## Boards ruled out

- The board connected on 2026-08-08 (`ESP32-S3`, USB-Serial-JTAG
  `/dev/cu.usbmodem2101`) is the **moth** spare AMOLED unit — it runs
  `moth_ui_demo` (verified via app descriptor read). Do not flash it.
- The CarPlay ESP32-P4 3.5" board is in service and its UART is damaged
  (DFU-only). Not a candidate.
