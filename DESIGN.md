# Design

Why glint is built the way it is. [README.md](README.md) is the entry point,
[PROTOCOL.md](PROTOCOL.md) is the normative wire format, and
[NOTES.md](NOTES.md) collects the platform constraints referenced here.

## 1. Why the display has to be virtual

macOS supports exactly two ways to add a monitor:

- **DisplayPort Alt Mode**, which needs a real DisplayPort sink. These boards
  have none.
- **DisplayLink**, which is proprietary silicon plus a signed kext, and is not
  reimplementable.

So the display must be virtual on the Mac side, with its framebuffer streamed to
the board over a custom transport. Everything below follows from that.

`CGVirtualDisplay` and `CGVirtualDisplayDescriptor` are the route, and they are
private CoreGraphics API. Every virtual-display tool on macOS uses them —
BetterDisplay, DeskPad, FluffyDisplay, OpenDisplay — and every one of them
carries the same risk: the API can change under a macOS update with no warning.
That is an accepted cost, not a solved problem. `glint doctor` exercises the
same creation path a session uses, so a breakage reports itself rather than
turning into a mysteriously blank panel.

Espressif ship `esp-iot-solution/examples/usb/device/usb_extend_screen`, which
solves a similar problem. Its host half is Windows-only and its device half
assumes a MIPI-DSI panel with hardware JPEG decode, so it is a useful protocol
reference rather than a starting point.

## 2. The binding constraint is the panel bus, not the link

For the 320x480 SPI panel, one full RGB565 frame is 300 KB.

| Path | Throughput | One full frame |
|---|---|---|
| USB 2.0 high-speed bulk | 25-35 MB/s | about 100 fps |
| SPI at 80 MHz, in theory | 10 MB/s | about 32 fps |
| SPI at 80 MHz, measured | about 8 MB/s | 25.7 fps |

The panel bus is three to four times slower than the wire feeding it. Two
consequences follow.

**Dirty-rect tiling is required, not an optimisation.** The ST7796 accepts a
column and row address window, so only changed regions need to be pushed. A
terminal with a blinking cursor is a few KB per update; a typical desktop frame
is 18 KB against 300 KB for the whole screen. Static content is instant and
dragging a window crawls. There is no way around that at these rates, so the
design assumes mostly-static content.

**Raw pixels beat JPEG here.** 300 KB frames over high-speed USB is about
9 MB/s at 30 fps, which the link absorbs easily. Sending raw RGB565 means no
encode on the host, no decode on the device, lower latency and simpler firmware.
The P4's hardware JPEG codec would earn its keep driving a 1024x600 DSI panel;
at 320x480 it is dead weight. The protocol keeps a format field so JPEG can come
back when a faster panel makes it pay.

Run-length encoding sits between the two. It costs almost nothing to produce, it
collapses flat interface regions by three orders of magnitude, and the host only
uses it when the encoded tile is genuinely smaller than raw — so photographic
content silently stays uncompressed. On a full-speed board, where USB rather
than the panel is the bottleneck, this is the difference between usable and not.

On the host side the tiles of a frame are batched into one bulk write rather
than one transfer per tile. A blocking transfer per tile leaves the link idle
between tiles; batching is what takes the P4 from 4.5 to 7.9 MB/s.

## 3. Why a pure vendor-specific USB interface

The device exposes one vendor-specific interface and nothing else. A vendor
class has no in-kernel driver to bind it, so the host claims it from userspace
with no kext and no driver signing. If the device also advertised CDC or another
recognised class, the operating system could claim the composite device first
and the vendor interface becomes harder to grab.

The cost is that Windows will not bind WinUSB to a bare vendor interface without
MS OS 2.0 descriptors. That is the work a Windows host would need first.

## 4. Architecture

```
┌─ host ──────────────────────────────┐
│  macOS: CGVirtualDisplay            │   Linux: /dev/fb0
│            ↓                        │
│  capture a frame as BGRA            │
│            ↓                        │
│  dirty tiles against a hash grid    │
│            ↓                        │
│  BGRA → RGB565, optional RLE        │
│            ↓                        │
│  bulk OUT (libusb / usbfs)  or TCP  │
└────────────┬────────────────────────┘
             │
┌────────────┴─── device ─────────────┐
│  TinyUSB vendor class  or  socket   │
│            ↓                        │
│  one tile parser, either source     │
│            ↓                        │
│  queue of PSRAM tile allocations    │
│            ↓                        │
│  esp_lcd_panel_draw_bitmap → panel  │
│                                     │
│  touch poll → events → every link   │
└─────────────────────────────────────┘
```

Three tasks in the firmware, decoupled by a queue so a stalled link never blocks
the panel and a slow panel never blocks the link:

- a receive task per transport, parsing headers and copying payloads into
  per-tile PSRAM allocations;
- a panel task draining the queue into `esp_lcd_panel_draw_bitmap`;
- a touch task polling the controller at 60 Hz and emitting events.

The queue is 64 entries deep and each entry is a PSRAM allocation sized to its
own tile, so it costs what the traffic costs rather than reserving a fixed ring
up front. A full backlog of largest-case tiles is about 2.6 MB against the P4's
32 MB of PSRAM; a full refresh is 300 KB and steady state at 30 fps measures
about 0.59 MB/s, so it does not run near full. On overrun the newest tile is
dropped rather than the oldest: dropping the oldest would discard a tile already
accounted for, and the recovery path is the same either way — the device reports
the drop and the host sends a full refresh.

## 5. Recovery without a back-channel request

The device never asks the host for anything. It counts dropped tiles and parser
resynchronisations and reports the counters, and any movement in either counter
makes the host invalidate its tile hashes so the next frame is a full refresh.
This keeps the device side simple and means the mechanism works identically on
both transports. It does require that something always drains the event pipe,
which is why both hosts run the reader whether or not anyone asked for touch
input. [PROTOCOL.md](PROTOCOL.md) states the policy.

## 6. Two transports

The boards have Wi-Fi, so the same tile stream runs over TCP with no data cable
— power only. The parser is shared: a socket and a bulk endpoint deliver the
same bytes.

A socket has no control pipe, which is why the protocol carries an in-band
request structure alongside the vendor control requests. The parser dispatches
on the 4-byte magic rather than waiting for a full tile header, because a
request is 8 bytes and a header is 24, and waiting for 24 would deadlock against
a host that sends a request and then waits for the reply.

Wireless throughput is bounded by the TCP window rather than the radio; the
firmware's window configuration and the resulting figures are in
[NOTES.md](NOTES.md).

## 7. Discovery

With more than one board, "which panel?" becomes a real question. Each board
advertises `_glint._tcp` and sets both its mDNS hostname and its instance name
to `glint-<id>`, where the id is the low 16 bits of its factory MAC — the same
value the handshake reports as `dev_id` and the same string the USB serial
carries. One identifier therefore covers all three lookups, and a browse result
becomes a connectable address by appending `.local`.

The hosts find a panel by themselves: USB when a cable is in, otherwise the
first panel that answers a HELLO. A completed TCP connection is not enough to
prove a panel is free, so availability is always established by handshake; see
[NOTES.md](NOTES.md).

## 8. A host-agnostic protocol

Nothing in the wire format is specific to macOS. Geometry, formats and the
maximum payload all come from the handshake, so a host is a frame source plus a
tiler. That is what made a second host cheap: the Linux host renders a
framebuffer instead of a captured virtual display, and shares nothing but the
protocol.

It also lets the Linux host do something macOS cannot. `fb -native` sets the
console framebuffer to the panel's exact size and streams 1:1, so the console
font is rendered at its final size rather than resampled. On macOS the desktop
is 960x640 downscaled 2:1, because a virtual display cannot be created at the
panel's native size.

## 9. Multiple boards from one image

`menuconfig` picks the board and `board.h` holds the profiles: pins, bus type,
clock, mirroring, inversion, touch controller, and whether the board can present
a serial device for a bootloader reboot. Adding the AMOLED board meant adding a
QSPI panel path — four data lines, 32-bit commands, no DC line — beside the SPI
one, and a brightness command in place of a backlight pin. No host change was
needed for either, because the host reads its geometry from the handshake.

## 10. Scope

At 3.5" and about 165 PPI, run at 1x, a Terminal at 12pt is roughly 45 by 25
characters. 18-bit colour is fine for text and flat interfaces and poor for
gradients or photographs. This is a status panel: a docked terminal, a monitor
widget, a timer.

The value in the design is that the host is the larger half of the work, it is
panel-agnostic, and it survives a panel upgrade untouched.

## 11. Upgrade path

The P4 board carries a reserved MIPI-DSI connector pad, 0.5 mm pitch, 15 pins.
Fitting the connector and attaching a DSI panel would change the arithmetic in
§2 entirely: DSI is two lanes at 1.5 Gbps, so the SPI ceiling disappears,
hardware JPEG decode becomes worth using (`fmt` 2 is reserved for it), and
Espressif's `usb_extend_screen` firmware becomes directly applicable as a
reference.

The hosts would not change, provided the handshake keeps reporting geometry and
formats and the hosts keep deriving everything from it. That is the reason both
hosts are resolution-agnostic and neither hardcodes a panel size.
