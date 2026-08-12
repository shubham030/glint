# glint

An extra display for your computer, on a 3.5" ESP32 panel, over one USB cable.

A *glint* is small reflected light — which is what this is: the panel has no
content of its own, it shows borrowed pixels. macOS gets a real second display
(windows drag onto it, it appears in System Settings); the panel gets the
changed tiles of that desktop over a USB vendor interface. **No kext, no driver
signing, nothing installed.**

It is a **status panel, not a monitor**: a docked terminal tailing logs, a timer,
Activity Monitor, now-playing. See [DESIGN.md](DESIGN.md) §11 for why that
expectation is the honest one.

## Status

| | | |
|---|---|---|
| M0 | Transport + framing | ✅ |
| M1 | Static image → panel | ✅ fit / fill / rotate, any ImageIO format |
| M2 | Mirror the main display | ✅ |
| M3 | Real virtual display (`CGVirtualDisplay`) | ✅ extended desktop, 960×640 |
| M4 | Dirty-rect tiling | ✅ **300 KB → 18 KB per frame** (16.6×) |
| — | RGB565 RLE (fmt 1) | ✅ on by default; **7.9 MB/s, 25.7 fps** on the P4 |
| — | Wi-Fi transport (TCP, no data cable) | ✅ P4 1.93 MB/s, 6.3 fps |
| — | Second and third board (S3 SPI, S3 AMOLED) | ✅ one image, `menuconfig` picks the board |
| M5 | Touch → cursor | ⚠️ written; **calibration never run on hardware** |
| — | Linux / Pi host | ⚠️ pure Go, cross-compiles for Pi Zero W, **not on hardware** |
| M6 | DSI panel swap | future ([DESIGN.md](DESIGN.md) §8) |

Everything marked ⚠️ compiles and passes unit tests but has not touched
hardware — the honest distinction, kept here deliberately.

## What is left

`glint touch --calibrate` has never been run: it wants three taps on a real
panel and prints the `--tp-*` flags for that board. The Linux/Pi host has never
been run against hardware either (its USB path is raw usbfs ioctls).

## Quick start (macOS)

```sh
make            # build firmware + host
make flash      # flash the panel (UART Type-C port)
make display    # extended desktop on the panel
```

`make display` finds the panel by itself: **USB if a cable is in, otherwise the
first panel answering on the network** (each board advertises `_glint._tcp` as
`glint-<id>.local`). USB wins when both are available — it is an order of
magnitude faster, and a plugged-in cable is the clearer statement of intent.

It also waits, so starting it before the panel exists is fine, and it exits when
the panel goes away so a supervisor can restart it. `make install-agent` runs it
at login — which now covers a panel that is powered on the far side of the room
with no cable at all.

Naming one deliberately:

```sh
make panels                              # every panel reachable, both transports
make display-wifi                        # wireless only, auto-picked
make display-wifi PANEL=glint-335b.local # wireless, that board
glint display --usb                      # USB only
glint display --dev 1                     # the second panel on USB
```

`glint --list` marks a panel already serving another session as *in use*, since
the firmware takes one client at a time. On screen panels identify themselves by
board id (`glint 335b`), so macOS keeps each one's arrangement and resolution
separately.

Other modes:

```sh
glint display --portrait          # panel upright: 640×960 desktop
glint display --touch             # also post touch as mouse events
glint mirror --landscape          # mirror the main display instead
glint image photo.heic --fill     # push one still
glint bars --seconds 10           # transport test
glint touch --calibrate           # derive the touch mapping from 3 taps
glint stats                       # device counters (drops, resyncs)
glint backlight 128 | glint sleep 1
```

Colour shaping: `--sat P --con P` (percent; defaults 130/110), `--flat` for
none. Desktop size: `--width W --height H --1x`. Frame cap: `--fps N`.
`--full` disables tiling (useful for A/B measurement).

## Linux and Raspberry Pi

The protocol is host-agnostic, so a Pi can drive the same panel with no
virtual-display trickery — render something and tile it out. It has **no cgo and
no module dependencies**: USB goes straight to the kernel via usbfs ioctls, so
cross-compiling needs no libusb and no network.

```sh
make pi                                   # builds arm64 and armv6
scp linux/glint-pi-arm64 <user>@<pi>:~/glint
scp packaging/70-glint.rules <user>@<pi>:~/   # usbfs permission, once
ssh <pi> ./glint fbinfo                   # framebuffer geometry, no panel needed
ssh <pi> ./glint fb -fill                 # the console, on the panel
```

64-bit Raspberry Pi OS (a Pi 3 and up) needs the arm64 build; armv6 covers a Pi
Zero W. `fb` mirrors a Linux framebuffer — the console path that needs no X
server. See [linux/README.md](linux/README.md).

## Layout

```
protocol/protocol.h   the wire format — single source of truth
PROTOCOL.md           what that header means, and why
DESIGN.md             the original design doc (reasoning, hardware analysis)
HARDWARE.md           real pin maps, flashing, macOS mode limits
firmware/             ESP-IDF v5.5: TinyUSB vendor → tiles → ST7796
  main/               board.h, lcd.c, usb_vendor.c, touch.c, rle.c
  test/               host-compiled tests for the pure C logic
host/                 macOS: Swift + libusb
  Sources/GlintCore/  wire format, tiling, RLE (platform-neutral, tested)
  Sources/glint/      CLI, capture, CGVirtualDisplay, touch
linux/                pure-Go host (Pi Zero W and amd64)
packaging/            LaunchAgent for login start
```

## Verification without hardware

```sh
make test        # 23 Swift unit tests + C decoder tests + Go tests
```

All three RLE implementations are pinned to each other by a shared fixture:
bytes produced by the real Swift encoder are decoded by the real C decoder
(`firmware/test/rle_test.c`), and the Go encoder is asserted to emit those exact
bytes (`linux/proto/fixture_test.go`). If any implementation's format drifts,
that test fails instead of the panel smearing.

## Throughput, and what actually limits it

Both boards are limited by the link, not by the host: profiling a full-frame
send shows **94–100% of each frame is the USB write**, with render and encode
together under 3 ms.

| | ESP32-P4 (USB high speed) | ESP32-S3 (USB **full speed** only) |
|---|---|---|
| Full-frame throughput | **7.9 MB/s** | 0.46 MB/s |
| Full-screen frame rate | **25.7 fps** (320×480) | ~1 fps (466×466) |
| Bound by | the ST7796's ~8 MB/s SPI bus | the 1.2 MB/s full-speed USB ceiling |

**Batching packets into one bulk write was worth +74% on the P4** (4.53 → 7.89
MB/s), because a blocking transfer per tile left the link idle in between. The
same change measured *nothing* at full speed, where the link is so slow that
per-transfer overhead disappears — which is why it is worth measuring a change
on the hardware whose limit you are actually chasing.

The P4 now sits at its panel's SPI ceiling, so further gains there need the DSI
upgrade in [DESIGN.md](DESIGN.md) §8 rather than better software. The S3's lever
is content locality instead: dirty tiling brings a moving desktop from 424 KB to
~91 KB per frame, and RLE compresses flat regions on top.

Things that measured **no** improvement, so they are not worth retrying:
enlarging the device's vendor RX FIFO (64 B → 4096 B at full speed) and
bypassing the USB hub to attach the board directly.

## Measured numbers

What the encoding does to a frame, on the P4 (USB high speed, ST7796 SPI at
80 MHz). The rates for the link itself are in the table above.

| | |
|---|---|
| Full frame, uncompressed | 300 KB |
| Dirty-tile push (typical desktop) | 18 KB, 2.4 tiles/frame |
| Idle desktop | most frames send nothing at all |
| Flat 64×64 tile, RLE | 8192 bytes → 4 |
| Same frames over Wi-Fi | 1.93 MB/s, 6.3 fps — a 64 KB TCP window, up from 0.24 MB/s with lwIP's default 5.7 KB |

## Known limits

- **macOS refuses small virtual displays.** On 26.5, any mode whose smallest
  dimension is under ~500 px gets halved, and switching back fails with
  `CGError 1001`. Accepted: landscape 960×640 (default) or 800×534; portrait
  640×960. Panel-native 480×320 is not achievable, so text is always rendered
  at 2× and downscaled — that is the source of the slight softness, not the
  panel.
- **HiDPI is ignored** for virtual displays (tried both pixel- and point-sized
  modes). Lanczos + sharpen in the capture path was measurably *worse* for text
  than the stream scaler; don't redo either.
- **Backlight on the P4 board is on/off**, wired to a plain GPIO — no dimming
  headroom, so `CMD_BACKLIGHT` is effectively a switch there. Colour flatness is
  compensated host-side (`--sat`/`--con`); tuning the panel's gamma table in
  firmware is the untried fix at the source.
- **`CGVirtualDisplay` is private API.** It can break on any macOS update. This
  is the deal for every virtual-display tool on macOS.
- **Screen Recording permission** is required, and the purple indicator stays on.
