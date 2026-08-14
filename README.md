# glint

glint turns a supported ESP32 board with an LCD into a small extra display for a
computer.

I built it because the usual 3.5" ESP32 panels are sharp enough for status
work, but most "USB display" projects either depend on proprietary stacks or
stop at a one-off demo. glint treats the panel as a real endpoint: firmware on
the board, a macOS host that creates a virtual display, and a Linux host that
can drive the same panel from a framebuffer.

## Demo

Demo video: coming soon.

I will add a recorded walkthrough here showing the macOS virtual display path,
the Linux framebuffer path, and the supported boards in use.

## What It Does

- **macOS host**: creates a real virtual display through private CoreGraphics
  API, then streams that display to the panel over USB or Wi-Fi.
- **Linux host**: mirrors a framebuffer to the same panel with a pure-Go host
  that uses usbfs directly and needs no X server.
- **Firmware**: receives tiled pixel updates over a USB vendor interface or TCP
  on Wi-Fi, paints them on the panel, and reports touch events back.

At this size and density it works best as a status panel: a docked terminal, a
dashboard, a timer, a monitor widget. Text is good. Gradients and photographs
are not the point.

## Motivation

I wanted a small display that behaves like part of the machine rather than a
screen driven by a custom app. On macOS that meant creating a real display and
streaming it. On Linux that meant keeping the wire protocol host-agnostic so a
Pi or desktop could drive the same panel without any virtual-display machinery.

## What Works Today

| Platform | Status | Notes |
|---|---|---|
| macOS | supported | Swift host, virtual display, USB and Wi-Fi, touch support |
| Linux | supported | pure-Go host, usbfs transport, framebuffer mirroring |
| Windows | partial | Go host builds for Wi-Fi use, but there is no documented user path yet |

## Supported Boards

I have tested glint on these boards:

| Board | Panel | Link |
|---|---|---|
| ESP32-P4-WIFI6-Touch-LCD-3.5 | ST7796 SPI, 320x480, FT6336 touch | USB high speed, Wi-Fi |
| Waveshare ESP32-S3-Touch-AMOLED-1.75 | CO5300 QSPI, 466x466, CST9217 touch | USB full speed, Wi-Fi |

Nothing in the host code is specific to those two boards. A board is one header
in `firmware/main/boards/` plus any panel- or touch-driver support it needs in
firmware. The panel size and capabilities come from the handshake, so both
hosts stay resolution-agnostic.

Hardware details, flashing notes, board bring-up, and touch mappings live in
[HARDWARE.md](HARDWARE.md).

## Quick Start

1. Install ESP-IDF v5.5 at `~/esp/esp-idf-v5.5`, or set `IDF_PATH`.
2. Connect a supported board.
3. Run:

```sh
make setup
```

`make setup` finds the board, suggests the matching profile, offers Wi-Fi
configuration, builds, flashes, and starts a display session.

If you prefer to do it by hand:

```sh
make            # build firmware + macOS host
make flash      # flash the board
make display    # macOS extended desktop on the panel
```

## Platform Guides

- [macOS guide](docs/macos.md)
- [Linux guide](docs/linux.md)

## Current Limits

- macOS cannot create a virtual display at the panel's native size, so the
  default desktop is downscaled 2:1. See [NOTES.md](NOTES.md).
- `CGVirtualDisplay` is private API and can break on a macOS update.
- HiDPI is ignored for virtual displays.
- The P4 board's backlight is a plain GPIO, so `CMD_BACKLIGHT` is effectively
  on/off there.
- The Linux USB path is usbfs-based and Linux-only.

## Verification

`make test` runs:

- Swift unit tests for the shared host logic
- host-compiled C tests for the firmware RLE decoder
- `go test ./...` across the Linux host packages

The Swift, Go, and firmware-side RLE implementations are pinned to the same
fixture so they agree byte-for-byte.

## Technical Docs

- [HARDWARE.md](HARDWARE.md): boards, pins, flashing, touch mappings
- [DESIGN.md](DESIGN.md): architecture and design decisions
- [PROTOCOL.md](PROTOCOL.md): wire format
- [NOTES.md](NOTES.md): platform constraints and non-obvious behavior
- [THIRD-PARTY.md](THIRD-PARTY.md): third-party code and licenses

## Repository Layout

```text
protocol/protocol.h         wire format source of truth
firmware/                   ESP-IDF firmware
host/Sources/GlintCore/     shared host logic: protocol, tiling, RLE
host/Sources/glint/         macOS host CLI and virtual-display path
linux/                      Linux host and transport code
packaging/                  LaunchAgent and udev rule
tools/                      setup helpers
```

## License

MIT — see [LICENSE](LICENSE). Third-party code keeps its own terms, listed in
[THIRD-PARTY.md](THIRD-PARTY.md).
