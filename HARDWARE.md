# Actual hardware

## Primary target: ESP32-P4-WIFI6-Touch-LCD-3.5 (the CarPlay board)

The design doc's board is real and on the desk — it's the same unit the
carplay/mapcast project targets (ESP32-P4 rev v1.3, 16MB flash, CH343
USB-UART bridge on the second Type-C). Product page:
https://www.waveshare.com/esp32-p4-wifi6-touch-lcd-3.5.htm (confirms ST7796
SPI + FT6336 I2C, reserved 15-pin DSI pad, OV5647 camera, ES8311 codec). The
wiki page was missing from Waveshare's AllPages index when checked 2026-08-08,
so pin facts below come from the proven mapcast firmware
(`carplay/firmware/mapcast/main/display.c`); the CarPlay schematic PDF lives
at `carplay/hardware/` (source for FT6336 I2C pins when M5 needs them).

**macOS virtual-display mode limits (26.5):** WindowServer halves any mode
whose smallest dimension is under ~500 px and refuses to switch back
(CGError 1001). Accepted exact: landscape 960×640 (2:1, default) and 800×534
(1.67:1); portrait 640×960 (2:1, default). Panel-native 480×320/320×480 is
not achievable.

The doc's §3 analysis stands for this board: USB 2.0 HS feeds an ~8–10 MB/s
SPI panel — SPI is the bottleneck, dirty-rect tiling is the design driver.

| | |
|---|---|
| Panel | ST7796, SPI2_HOST @ 80 MHz, **SPI mode 3**, BGR order, colour-inverted, 16bpp |
| Native orientation | 320×480 portrait (mapcast adds swap_xy for landscape; glint stays portrait) |
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
| LCD backlight | 28 (glint drives it with LEDC PWM for CMD_BACKLIGHT) |

### A shared board is a failure mode

Three projects flash this same P4 — carplay/mapcast, glint, and macropad
(MacroVault) — and none of them pins the board by identity, so two Claude
sessions can flash it minutes apart. Their app regions overlap (glint's ~359 KB
app at `0x10000` swallows macropad's otadata at `0x0F000` and app at `0x20000`),
so each write corrupts the other.

**The failure signature misleads in both directions**, which is what makes this
worth writing down: every tool involved reports a plausible *local* cause. A
mid-write abort reads as a flaky UART; the resulting boot loop reads as a crash
in whatever you changed last. On 2026-08-11 one session bisected its own new
code and this one blamed the UART, and neither suspected a second writer.

> If a shared board shows an unexplained boot loop or a mid-write abort, look
> for a second writer *before* bisecting your own change.

Tells that it is another writer, not your bug:

- `esp_image: segment N ... vaddr=<ASCII-looking>` and a
  `verify_load_addresses` assert — that is another firmware's bytes where a
  segment header belongs. Confirm with `esptool image_info <your .bin>`: if the
  local file validates, the file is fine and the flash is not.
- A flash that writes the bootloader, verifies, then dies with *"device reports
  readiness to read but returned no data"*.
- `lsof /dev/cu.usbmodem*` is necessary but **not sufficient** — a squatter on a
  duty cycle (a 35 s capture loop, say) passes a short sample.

`ps -Ao pid,command | grep esptool` names the offending project; `ListAgents` and
`SendMessage` reach that session directly. Recovery is `erase_flash` then a
**full** flash — never app-only, or the previous owner's partition table
survives and will not match your bootloader.

### Flashing

Over the CH343 UART port (`/dev/cu.usbmodem5B91…`) — verified working
2026-08-08 with esptool (the older "DFU only / UART damaged" note about this
board no longer holds). The OTG Type-C is the vendor-interface port; both can
be connected at once, which is the comfortable bring-up setup: console+flash
on one cable, glint link on the other.

Flashing glint replaces the mapcast (CarPlay) firmware — rebuild it from
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

## Flashing the P4 needs the UART port

`glint bootloader` cannot help on this board. Its OTG Type-C is wired to the
**UTMI (high-speed) PHY** — the boot log says so outright, `usb_phy: Using UTMI
PHY instead of requested internal PHY` — while USB-Serial-JTAG needs the
internal FS PHY. So no serial device can ever appear on the data port, and
honouring a bootloader request there produces a board that is neither a working
panel nor flashable until it is power-cycled. The firmware now refuses the
request on this board (`BOARD_CAN_SERIAL_BOOT 0`) and says why in the log.

Flash over the second Type-C (CH343 UART), which on macOS appears as
`/dev/cu.usbmodem*` and answers `esptool chip_id`. The S3 boards have one data
port muxed to USB-Serial-JTAG, so `glint bootloader` does work there.

## Touch mapping (measured)

The FT6336 reports panel-native coordinates and the host applies orientation, so
the mapping is a property of the board, not of the session. Measured on the P4
(`glint touch --calibrate`, panel viewed in landscape):

| tap | panel coords |
|---|---|
| top-left | (25, 453) |
| top-right | (33, 24) |
| bottom-left | (297, 449) |

Moving right changes *y* by 429 and *x* by 8, so the glass's Y axis carries the
screen's X and counts backwards:

```sh
glint display --touch --tp-swap --tp-flip-x
```

Verified end to end: taps post real `leftMouseDown`/`leftMouseUp` pairs at
coordinates inside the panel's own region of the desktop (corner taps at
(-946, 88), centre at (-553, 333) for a display at (-960, 0) 960x640).

### S3 AMOLED 1.75" (CST9217)

Different chip, different mapping. Measured by tapping all four corners with no
flags applied (screen coords on a 932x932 desktop at origin (-932, 0)):

| tap | cursor landed |
|---|---|
| top-left | (-104, 212) |
| top-right | (-232, 836) |
| bottom-left | (-814, 172) |
| bottom-right | (-810, 766) |

Moving right swung *y* by 624 and barely moved *x*; moving down did the
opposite. So the axes are swapped and the new Y is inverted:

```sh
glint display --touch --tp-swap --tp-flip-y
```

Verified after applying: top-left reads 25% across / 9% down, bottom-right 76% /
88%. The values sit inside the corners because this panel's corners are rounded
away — there is no glass at 0,0 to tap.

Recalibrate only if the panel is remounted or a different board is used.

## Boards ruled out

- The ESP32-S3 on `/dev/cu.usbmodem2101` (when connected) is the **moth**
  spare AMOLED unit — it runs `moth_ui_demo` (verified via app-descriptor
  read). Never flash it.
