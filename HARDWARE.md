# Hardware

Three boards, one firmware image. `idf.py menuconfig` under "glint board" picks
which; `firmware/main/board.h` holds the profiles. The host learns the geometry
from the handshake, so adding a board is a firmware-only change.

The pin tables below are the assignments the firmware uses. They were derived
from working code for these specific units rather than from vendor
documentation, and boards from the same product line do vary. Anyone bringing up
a different unit should check them against their own board's schematic before
trusting them.

## ESP32-P4-WIFI6-Touch-LCD-3.5

The primary target. ESP32-P4NRW32, dual-core RISC-V, 32 MB in-package PSRAM,
16 MB flash. USB OTG 2.0 high speed on one Type-C, a CH343 USB-UART bridge on
the other. Wi-Fi comes from an onboard ESP32-C6 reached over SDIO (esp-hosted),
which must already carry esp-hosted slave firmware.

| | |
|---|---|
| Panel | ST7796, 320x480 IPS, 18-bit colour, about 165 PPI |
| Panel bus | SPI2_HOST at 80 MHz, SPI mode 3, mirrored X, colour-inverted, 16 bpp |
| Orientation | 320x480 portrait native; the host rotates for landscape |
| Touch | FT6336 over I2C, 2 points |
| Backlight | plain GPIO, on/off — no PWM dimming on this board |
| PMU | none |
| Also on the board | reserved 15-pin 0.5 mm MIPI-DSI pad, OV5647 camera, ES8311 codec |

| Function | GPIO |
|---|---|
| LCD MOSI | 20 |
| LCD SCLK | 21 |
| LCD CS | 23 |
| LCD DC | 26 |
| LCD RST | 27 |
| LCD backlight | 28 |
| I2C SDA | 7 |
| I2C SCL | 8 |
| Touch RST | 29 |
| Touch INT | 50 |

This board cannot present a serial device on its OTG port, so `glint bootloader`
is refused there and flashing goes over the UART Type-C. See
[NOTES.md](NOTES.md).

## Waveshare ESP32-S3-Touch-AMOLED-1.75

ESP32-S3 with a CO5300 AMOLED over QSPI. USB is full speed, so the link rather
than the panel bus is the limit here and RLE earns its keep.

| | |
|---|---|
| Panel | CO5300, 466x466 square AMOLED |
| Panel bus | QSPI at 40 MHz, SPI mode 0, four data lines, commands in band, no DC pin |
| Quirks | 6-pixel column offset; no TE line; no backlight — brightness is a panel command |
| Touch | CST9217 over I2C |
| PMU | AXP2101 present at 0x34, but the panel needs no rail work |

| Function | GPIO |
|---|---|
| LCD SCLK | 38 |
| LCD D0…D3 | 4, 5, 6, 7 |
| LCD CS | 12 |
| LCD RST | 39 |
| I2C SDA | 15 |
| I2C SCL | 14 |
| Touch RST | 40 |
| Touch INT | 11 |

Its single data port is muxed to USB-Serial-JTAG, so `glint bootloader` works.

## Waveshare ESP32-S3-Touch-LCD-3.5

Kept as a build target. It matches the P4 board's panel spec, but no unit has
been run here, so treat the profile as untested. USB is full speed.

| | |
|---|---|
| SoC | ESP32-S3R8, 8 MB octal PSRAM |
| Panel | ST7796, SPI2 at 80 MHz, SPI mode 0, colour-inverted, unmirrored |
| CS and RST | not GPIO-driven — tied on-board and PMU-powered |
| Touch | FT6336 at I2C address 0x38 |
| PMU | AXP2101 at 0x34 — its rails must be enabled before the panel works |

| Function | GPIO |
|---|---|
| LCD MOSI | 1 |
| LCD SCLK | 5 |
| LCD DC | 3 |
| LCD backlight | 6 (LEDC PWM) |
| I2C SDA | 8 |
| I2C SCL | 7 |

The AXP2101 is driven through the vendored XPowersLib component, configured as
the factory demo does.

## Building and flashing

```sh
make fw            # ESP32-P4, default build directory
make fw-s3         # ESP32-S3 3.5", build_s3/
make fw-amoled     # ESP32-S3 AMOLED 1.75", build_amoled/
make flash         # flash the P4
make flash-amoled  # flash the AMOLED board
make monitor       # serial console
```

Each variant builds in its own directory with its own sdkconfig, so switching
boards does not reconfigure the others in place.

The Makefile picks the serial port with `ls /dev/cu.usbmodem* | head -1`. With
more than one board attached that guess will be wrong, so pass the port
explicitly: `make flash PORT=/dev/cu.usbmodemXXXX`. To find the right node, list
`/dev/cu.usbmodem*` with the board unplugged and again with it plugged in, and
confirm with `esptool -p <port> chip_id`. On the P4 board the console and
flashing live on the UART Type-C while the OTG Type-C carries the glint link;
both can be connected at once, which is the comfortable bring-up arrangement.

Wi-Fi is off by default except on the AMOLED board. Enable it and set the SSID
under "glint board" in `menuconfig`. The credentials belong in the generated
`sdkconfig`, which is not tracked — never in a committed defaults file.

Only one process may write to a board at a time. If a flash aborts mid-write or
the board boot-loops afterwards, check for a second writer before bisecting your
own change; [NOTES.md](NOTES.md) describes the signature.

## Touch mappings, measured

The touch controller reports panel-native coordinates and the host applies the
orientation, so the mapping is a property of the board and not of the session.
Derive it with `glint touch --calibrate` and pass the flags it prints.
Recalibrate only if the panel is remounted or a different board is used.

### ESP32-P4 3.5" (FT6336)

Panel viewed in landscape:

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

Taps then post `leftMouseDown`/`leftMouseUp` pairs inside the panel's own region
of the desktop.

### AMOLED 1.75" (CST9217)

Measured by tapping all four corners with no flags applied, on a 932x932 desktop
at origin (-932, 0):

| tap | cursor landed |
|---|---|
| top-left | (-104, 212) |
| top-right | (-232, 836) |
| bottom-left | (-814, 172) |
| bottom-right | (-810, 766) |

Moving right swung *y* by 624 and barely moved *x*; moving down did the
opposite. The axes are swapped and the new Y is inverted:

```sh
glint display --touch --tp-swap --tp-flip-y
```

After applying, a top-left tap reads 25% across and 9% down, and a bottom-right
tap 76% and 88%. The values sit inside the corners because this panel's corners
are rounded away, which is also why the mapping is derived from relationships
between taps rather than from absolute extremes. See [NOTES.md](NOTES.md).
