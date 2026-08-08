# Actual hardware

## Primary target: ESP32-P4-WIFI6-Touch-LCD-3.5 (the CarPlay board)

The design doc's board is real and on the desk — it's the same unit the
carplay/mapcast project targets (ESP32-P4 rev v1.3, 16MB flash, CH343
USB-UART bridge on the second Type-C). It is *not* in Waveshare's public wiki
catalogue (checked 2026-08-08 — their P4 touch-LCD lineup lists only
3.4C/4B/4C/7B), so all pin facts below come from the proven mapcast firmware
(`carplay/firmware/mapcast/main/display.c`), not vendor docs.

The doc's §3 analysis stands for this board: USB 2.0 HS feeds an ~8–10 MB/s
SPI panel — SPI is the bottleneck, dirty-rect tiling is the design driver.

| | |
|---|---|
| Panel | ST7796, SPI2_HOST @ 80 MHz, **SPI mode 3**, BGR order, colour-inverted, 16bpp |
| Native orientation | 320×480 portrait (mapcast adds swap_xy for landscape; vdisp stays portrait) |
| USB | OTG 2.0 High Speed on its own Type-C (vendor interface); CH343 UART on the other Type-C (console + flashing) |
| Touch | FT6336 per the design doc — pins not yet traced (M5); mapcast doesn't use touch |
| PMU | none (no AXP2101 on this board) |

### Pins (from mapcast)

| Function | GPIO |
|---|---|
| LCD MOSI | 20 |
| LCD SCLK | 21 |
| LCD CS | 23 |
| LCD DC | 26 |
| LCD RST | 27 |
| LCD backlight | 28 (vdisp drives it with LEDC PWM for CMD_BACKLIGHT) |

### Flashing

Over the CH343 UART port (`/dev/cu.usbmodem5B91…`) — verified working
2026-08-08 with esptool (the older "DFU only / UART damaged" note about this
board no longer holds). The OTG Type-C is the vendor-interface port; both can
be connected at once, which is the comfortable bring-up setup: console+flash
on one cable, vdisp link on the other.

Flashing vdisp replaces the mapcast (CarPlay) firmware — rebuild it from
`~/Desktop/Personal/carplay/firmware/mapcast` to restore.

## Secondary target: Waveshare ESP32-S3-Touch-LCD-3.5

Kept as a build target (`idf.py set-target esp32s3`) since the firmware is
board-abstracted and this catalogue board matches the same panel spec. Caveat:
its USB is **Full Speed** (~1 MB/s real) — on that board the doc's §3
bottleneck flips to USB, making RLE compression (fmt 1) near-mandatory.

| | |
|---|---|
| SoC | ESP32-S3R8, 8MB octal PSRAM |
| Panel | ST7796 SPI2 @ 80 MHz, SPI mode 0, BGR + invert; CS/RST not GPIO-driven |
| PMU | AXP2101 @ 0x34 — rails must be enabled before the panel works (`power.cpp`, vendored XPowersLib, config verbatim from the factory demo) |
| Pins | MOSI 1, SCLK 5, DC 3, BL 6 (LEDC); I2C SDA 8 / SCL 7; touch FT6336 @ 0x38 |

## Boards ruled out

- The ESP32-S3 on `/dev/cu.usbmodem2101` (when connected) is the **moth**
  spare AMOLED unit — it runs `moth_ui_demo` (verified via app-descriptor
  read). Never flash it.
