# glint

glint turns a supported ESP32 board with an LCD into an extra display for a
computer.

The firmware is an ESP-IDF application. It receives tiles of pixels over a USB
vendor interface or over TCP on Wi-Fi, paints them on the panel, and reports
touch events back. Two hosts drive it:

- **macOS** (Swift) creates a real virtual display through private CoreGraphics
  API. Windows drag onto it and it appears in System Settings. Nothing is
  installed: no kext, no driver signing.
- **Linux** (pure Go, no cgo) mirrors a framebuffer to the panel. On a
  Raspberry Pi this needs no X server.

At 3.5" and 165 PPI this suits a status panel — a docked terminal, a monitor
widget, a timer — better than a general second monitor. Text is legible;
gradients and photographs are not its strength.

## Boards

I have tested it on these two boards, and the measurements in this README come
from them:

| Board | Panel | Link |
|---|---|---|
| ESP32-P4-WIFI6-Touch-LCD-3.5 | ST7796 SPI, 320x480, FT6336 touch | USB high speed, Wi-Fi |
| Waveshare ESP32-S3-Touch-AMOLED-1.75 | CO5300 QSPI, 466x466, CST9217 touch | USB full speed, Wi-Fi |

Nothing here is specific to them. A board is one header in
`firmware/main/boards/` giving a pin map and a few panel quirks; `menuconfig`
picks which one is built. To use different hardware, copy
`firmware/main/boards/template.h` to `custom.h`, fill it in, and select "Custom
board" — the build names anything you leave out. The panel's size and
capabilities reach both hosts through the handshake, so neither host changes.
[HARDWARE.md](HARDWARE.md) covers pins, flashing, porting and touch mappings.

## macOS

ESP-IDF v5.5 builds the firmware; the Makefile expects it at
`~/esp/esp-idf-v5.5`. The host needs a Swift toolchain and libusb
(`brew install libusb`); `Package.swift` declares a macOS 13 minimum, and the
virtual-display behaviour described below was observed on macOS 26.5.

```sh
make            # build firmware + host
make flash      # flash the panel over its UART port
make display    # extended desktop on the panel
```

`make display` finds a panel by itself: USB when a cable is in, otherwise the
first panel answering on the network. Wi-Fi is off by default on the SPI boards
(`menuconfig` → Wi-Fi; see [HARDWARE.md](HARDWARE.md)), so a freshly flashed one
is USB-only until it is enabled and given credentials. Each board advertises `_glint._tcp` as
`glint-<id>.local`. USB is preferred when both are available, being about four
times faster. The virtual display lives exactly as long as the process; the
process waits for a panel to appear and exits when one goes away, so a
supervisor can restart it. `make install-agent` runs it at login.

```sh
make panels                              # every panel reachable, both transports
make display-wifi PANEL=glint-335b.local # wireless only; empty PANEL auto-picks
glint display --usb                      # USB only
glint display --serial glint-335b        # that board, on either transport
glint display --portrait                 # panel upright: 640x960 desktop
glint display --touch --tp-swap --tp-flip-x  # touch drives the cursor
glint doctor                             # panel, permissions, private API
glint mirror --landscape                 # mirror the main display instead
glint image photo.heic --fill            # push one still
glint bars --seconds 10                  # transport test
glint touch --calibrate                  # derive the touch mapping from taps
glint stats                              # device counters (drops, resyncs)
glint backlight 128 | glint sleep 1
```

`make panels` runs `glint --list`, which marks a panel already serving another
session as in use. The Linux host spells the same command `glint panels`.

Colour shaping: `--sat P --con P` (percent, defaults 130 and 110), `--flat` for
none. Desktop size: `--width W --height H --1x`. Frame cap: `--fps N`. `--full`
disables tiling, which is useful for measurement. `glint display` needs Screen
Recording permission and `--touch` also needs Accessibility; `glint doctor`
reports on both.

## Linux and Raspberry Pi

The protocol is host-agnostic, so a Pi drives the same panel with no
virtual-display machinery. The Go host (Go 1.21 or newer) has no cgo and no
module dependencies — USB goes through usbfs ioctls — so cross-compiling needs
neither libusb nor a network.

```sh
make pi                                        # builds arm64 and armv6
scp linux/glint-pi-arm64 <user>@<pi>:~/glint
scp packaging/70-glint.rules <user>@<pi>:~/    # usbfs permission, once
ssh <pi> ./glint fbinfo                        # framebuffer geometry, no panel needed
ssh <pi> ./glint fb -native -landscape         # the console, on the panel, 1:1
ssh <pi> ./glint fb -net auto -native          # the same with no data cable
```

64-bit Raspberry Pi OS needs `glint-pi-arm64`; `glint-pi-armv6` covers a Pi Zero
W and 32-bit Pi OS. `-native` sets the console to the panel's exact size and
streams without scaling, which macOS cannot do. Details in
[linux/README.md](linux/README.md).

## Measured performance

Full-frame throughput over USB, colour bars, no compression:

| | ESP32-P4 (high speed) | ESP32-S3 AMOLED (full speed) |
|---|---|---|
| Throughput | 7.9 MB/s | 0.46 MB/s |
| Full-screen frame rate | 25.7 fps at 320x480 | about 1 fps at 466x466 |
| Bound by | the ST7796 SPI bus, about 8 MB/s | the 1.2 MB/s full-speed USB ceiling |

Neither is bound by the host: profiling a full-frame send puts 94-100% of each
frame in the USB write, with render and encode together under 3 ms. What the
encoding does to a frame on the P4:

| | |
|---|---|
| Full frame, uncompressed | 300 KB |
| Dirty-tile push, typical desktop | 18 KB, 2.4 tiles per frame |
| Idle desktop | most frames send nothing |
| Flat 64x64 tile, RLE | 8192 bytes to 4 |
| Wi-Fi, same frames | 1.93 MB/s, 6.3 fps |

Linux host on a Raspberry Pi 3, colour bars with RLE: 49.3 fps over USB and
35.1 fps over Wi-Fi with tiling; 45.6 and 32.5 fps sending whole frames.

## Limits

- The macOS desktop is 960x640 downscaled 2:1, because macOS will not create a
  virtual display at the panel's native size. See [NOTES.md](NOTES.md).
- HiDPI is ignored for virtual displays.
- `CGVirtualDisplay` is private API and can break on any macOS update, as it can
  for every virtual-display tool on macOS.
- Backlight on the P4 board is a plain GPIO, so `CMD_BACKLIGHT` is on/off there.
- Screen Recording permission is required, and the recording indicator stays on.
- No Windows host. It would need MS OS 2.0 descriptors so WinUSB binds.

## Verification without hardware

`make test` runs the Swift unit tests for the platform-neutral host code (wire
format, tiling, RLE, touch mapping, option parsing), the host-compiled C tests
for the firmware's RLE decoder, and `go test ./...` across the Linux packages.

The three RLE implementations are pinned to each other by a shared fixture:
bytes from the Swift encoder are decoded by the firmware's own C decoder
(`firmware/test/rle_test.c`), and the Go encoder is asserted to produce those
same bytes (`linux/proto/fixture_test.go`).

## Layout

```
protocol/protocol.h   the wire format — single source of truth
PROTOCOL.md           what that header means
DESIGN.md             architecture and the reasoning behind it
HARDWARE.md           boards, pins, flashing, touch mappings
NOTES.md              platform constraints that shaped the design
firmware/             ESP-IDF v5.5: USB vendor / TCP → tiles → panel
  main/               board.h, lcd.c, usb_vendor.c, net.c, stream.c, touch.c
  test/               host-compiled tests for the pure C logic
  components/         third-party code, under its own licence
host/Sources/GlintCore/  wire format, tiling, RLE — platform-neutral, tested
host/Sources/glint/      CLI, capture, CGVirtualDisplay, touch, discovery
linux/                pure-Go host, no cgo, no dependencies
packaging/            LaunchAgent for login start, udev rule for usbfs
```

## Licence

The code in this repository is MIT, copyright Shubham. `firmware/components/`
contains third-party code that keeps its own licence — XPowersLib is MIT.
