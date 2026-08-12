# Design notes — ESP32-P4 as a macOS extended display

> The original design document, kept as written (with corrections marked).
> `README.md` is the project entry point; `PROTOCOL.md` supersedes §5.


Build notes for **Waveshare ESP32-P4-WIFI6-Touch-LCD-3.5**.

> **Reality check (2026-08-08):** the board is real (it's the unit the
> carplay/mapcast project runs on) but absent from Waveshare's public wiki, so
> every pin fact in the firmware comes from the proven mapcast code, not
> vendor docs — see [HARDWARE.md](HARDWARE.md). The firmware also builds for
> the catalogue Waveshare ESP32-S3-Touch-LCD-3.5 (same panel, USB FS caveat).

---

## 1. Target hardware

| | |
|---|---|
| SoC | ESP32-P4NRW32, dual-core RISC-V @ 400MHz, 32MB in-package PSRAM |
| Flash | 16MB NOR |
| Panel | 3.5" IPS, 320×480, 262K colour (18-bit), ~165 PPI |
| Panel bus | **SPI**, ST7796 driver |
| Touch | FT6336 over I2C — 2-point |
| USB | USB OTG 2.0 **High Speed** Type-C (separate from the UART Type-C) |
| Wireless | ESP32-C6H8 over SDIO (Wi-Fi 6 / BLE 5) — unused for the wired path |
| Notable | Reserved MIPI-DSI pad, 0.5mm pitch 15-pin — see §8 |

---

## 2. Why there's no off-the-shelf path

macOS supports exactly two ways to add a monitor:

- **DisplayPort Alt Mode** — needs a real DP sink. The P4 has none.
- **DisplayLink** — proprietary silicon plus a signed kext. Not reimplementable.

So the display has to be *virtual* on the Mac side, with its framebuffer
streamed to the P4 over a custom transport. Everything below follows from that.

Espressif ship `esp-iot-solution/examples/usb/device/usb_extend_screen`, which
does exactly this — but the host half is Windows-only, and the device half
assumes a MIPI-DSI panel with hardware JPEG decode. Useful as a protocol
reference; not a drop-in for this board.

---

## 3. The binding constraint: SPI, not USB

| Path | Throughput | Full 320×480 RGB565 frame (307KB) |
|---|---|---|
| USB 2.0 HS bulk | ~25–35 MB/s | ~100 fps |
| SPI @ 80MHz | ~10 MB/s | **~30 fps theoretical** |
| SPI @ 80MHz, real | ~7–8 MB/s | **15–25 fps** |

The panel bus is 3–4× slower than the wire feeding it. Two consequences:

**Dirty-rect tiling is mandatory, not an optimisation.** ST7796 accepts a
column/row address window, so only changed tiles get pushed. A terminal with a
blinking cursor is a few KB per update. Static content will feel instant;
dragging a window will crawl. There is no way around this — budget the design
around mostly-static content.

**Skip JPEG.** 307KB frames over USB HS is ~9 MB/s at 30fps — trivial. Send raw
RGB565. No encode on the Mac, no decode on the P4, lower latency, simpler
firmware. The P4's hardware JPEG codec earns its keep on a 1024×600 DSI panel;
here it's dead weight. (Keep a format field in the protocol so it can come back
later — see §8.)

---

## 4. Architecture

```
┌─ macOS ─────────────────────────────┐
│  CGVirtualDisplay (private API)     │
│            ↓                        │
│  ScreenCaptureKit SCStream          │
│            ↓  BGRA CVPixelBuffer    │
│  dirty-rect → tile grid             │
│            ↓  vImage BGRA→RGB565    │
│  USB bulk OUT (IOKit / libusb)      │
└────────────┬────────────────────────┘
             │  USB 2.0 HS
┌────────────┴─── ESP32-P4 ───────────┐
│  TinyUSB vendor class               │
│    bulk OUT → PSRAM ring buffer     │
│            ↓                        │
│  esp_lcd_panel_draw_bitmap → ST7796 │
│                                     │
│  FT6336 I2C poll → bulk IN → Mac    │
│                    → CGEventPost    │
└─────────────────────────────────────┘
```

Vendor-specific USB interface, claimed from userspace. **No kext, no driver
signing.**

---

## 5. Wire protocol

Superseded by [PROTOCOL.md](PROTOCOL.md), which documents what was actually
built: `protocol/protocol.h` is the source of truth. Two corrections to the
original design worth calling out — the tile header is **24 bytes** (the field
list here summed to 24, not 20), and HELLO is returned as the data stage of the
`CMD_HELLO` control read rather than as a bulk IN event, since the host can do
nothing before it knows the geometry.

## 6. macOS side

**Virtual display.** `CGVirtualDisplay` / `CGVirtualDisplayDescriptor` —
private CoreGraphics. It is the only route; BetterDisplay, DeskPad,
FluffyDisplay and OpenDisplay all use it. Fine for personal use. Read
OpenDisplay's source first — same capture/encode shape, just swap H.264+usbmux
for RGB565+USB bulk.

Create at 320×480, scale factor 1.0. Do **not** attempt HiDPI at 165 PPI —
you'd halve an already-tiny desktop.

**Capture.** `SCStream` with an `SCContentFilter` on the virtual display's ID.
Pixel format BGRA, `showsCursor = true`, `minimumFrameInterval` capped at
~30fps (no point exceeding the panel).

Pull dirty rects from the `SCStreamFrameInfoDirtyRects` attachment rather than
diffing yourself. Keep a per-tile hash as a fallback — dirty rects are known to
be unreliable on virtual displays, and SCStream has a longstanding bug where
multiple simultaneous virtual displays get confused with each other.

**Convert.** `vImageConvert_BGRA8888toRGB565` per tile. Fast enough to ignore.

**Transport.** `IOUSBHostInterface` or libusb. Claim the vendor interface,
async bulk writes, keep 2–3 transfers in flight.

**Touch.** Map panel coords → virtual display global coords → `CGEventPost`
with `kCGHIDEventTap`. Synthesise `mouseMoved` + `leftMouseDown/Up`. Needs
Accessibility permission.

---

## 7. Firmware side

ESP-IDF, target `esp32p4`.

```
esp_lcd_new_panel_io_spi()      // 80MHz, DMA, max_transfer_sz ≥ largest tile
esp_lcd_new_panel_st7796()
esp_lcd_panel_draw_bitmap(p, x, y, x+w, y+h, buf)
```

Two tasks, decoupled by a PSRAM ring buffer, so a USB stall never blocks SPI
and vice versa:

- `usb_rx_task` — TinyUSB vendor bulk OUT → parse header → memcpy payload into
  ring
- `lcd_tx_task` — drain ring → `draw_bitmap` → advance
- `touch_task` — FT6336 I2C poll @60Hz → bulk IN

Ring sized ~2MB in PSRAM (≈6 full frames of slack). Drop oldest tiles on
overrun and set a flag so the next frame requests `FULL_REFRESH`.

> **As built:** a 64-deep queue of per-tile PSRAM allocations replaced the fixed
> ring — same decoupling, but it sizes itself to the traffic instead of
> reserving 2MB. Worst case is 512KB (64 × 8KB tiles) against 32MB of PSRAM, a
> full refresh is 320KB, and steady state at 30fps measured ~0.59 MB/s, so the
> queue is never near full. On overrun the newest tile is dropped rather than the
> oldest — dropping the oldest would mean discarding a tile already accounted
> for, and the recovery path is the same either way: the device reports the drop
> and the host sends a full refresh.

Start SPI at 40MHz. Walk it up to 80MHz once the pipeline is stable — the
practical ceiling varies board to board and shows up as tearing or corrupt
tiles, not clean failure.

> **As built:** 80MHz from the start, since mapcast had already proven that rate
> on this exact panel.

---

## 8. Upgrade path — the reason this board is worth it

The board carries a **reserved MIPI-DSI connector pad** (0.5mm, 15-pin).
Solder the connector, attach a DSI panel, and:

- SPI's ~10 MB/s ceiling disappears; DSI is 2-lane × 1.5Gbps
- Hardware JPEG decode (1080p@30) becomes worth using — switch `fmt` to 2
- Espressif's `usb_extend_screen` firmware becomes directly applicable
- You get an actual second monitor instead of a status panel

The Mac app doesn't change at all, provided the handshake in §5.1 is honoured.
**Build resolution-agnostic from milestone 0.**

---

## 9. Milestones

| | | Proves | Status |
|---|---|---|---|
| M0 | Colour bars pushed over USB from a Mac CLI tool | Transport + framing | ✅ 7.9 MB/s after batching writes (was 4.5) |
| M1 | Static PNG → full-frame → panel | Format conversion, SPI throughput | ✅ fit/fill/landscape, EXIF-aware |
| M2 | ScreenCaptureKit on the **main** display → panel | Capture + convert pipeline | ✅ 11.3 fps @ 12 cap |
| M3 | Swap in CGVirtualDisplay | The private-API half | ✅ extended desktop, 960×640 (see HARDWARE.md for macOS mode limits) |
| M4 | Dirty-rect tiling | Usable frame rate | ✅ 300 KB → 18 KB/frame; 25.7 fps |
| M5 | FT6336 → CGEventPost | Input loop | ✅ calibrated: `--tp-swap --tp-flip-x` |
| M6 | DSI panel swap | §8 | — |

M0–M2 need no private APIs and are where most of the risk lives. Don't touch
`CGVirtualDisplay` until M2 works.

### Usage

```
make panels             # every panel reachable, USB and network
make display            # extended desktop: USB if cabled, else Wi-Fi
make display-portrait   # panel standing upright (640×960)
make display-wifi       # wireless only (PANEL=<host> to name one)
make mirror             # mirror the main display instead
make bars               # M0 transport test
./host/.build/release/glint image <path> [--fill] [--landscape]
./host/.build/release/glint display --touch --tp-swap --tp-flip-x
./host/.build/release/glint backlight <0-255>
```

The virtual display lives exactly as long as the `glint display` process.
Colour shaping: `--sat P` / `--con P` (percent, defaults 130/110), `--flat`
for none. Desktop size: `--width W --height H --1x` (see HARDWARE.md for
which modes macOS accepts).

---

## 10. Known risks

- **`CGVirtualDisplay` is private.** It breaks on OS updates with no warning
  and no recourse. This is the deal for every virtual-display product on macOS.
- **SCStream + virtual displays** has documented bugs. Reconnecting all virtual
  displays is the known workaround.
- **Screen recording permission** required; the purple indicator will be
  permanently on.
- **ST7796 SPI ceiling** is board-dependent. Don't assume 80MHz works.
- **USB enumeration** — expose a *pure* vendor-specific interface. If the
  device also advertises CDC, macOS may claim it and the vendor interface
  becomes harder to grab.

---

## 11. Honest expectations

165 PPI at 3.5", run at 1x, gives a 320×480-point desktop — a Terminal at 12pt
is roughly 45×25 characters. 18-bit colour looks fine for text and flat UI,
poor for gradients or photos.

This is a **status panel, not a monitor**: docked terminal tailing logs,
Activity Monitor, a timer, now-playing. Nobody drags a window onto a 3.5"
screen twice.

What makes it worth building is that the Mac-side app is ~90% of the work,
panel-agnostic, and survives the DSI upgrade in §8.

---

## 12. What was built that this document did not anticipate

The design assumed one board, one transport, one host. None of that held, and
the reasons are worth keeping.

**A second transport.** The panel has Wi-Fi, so it can take the same tile
stream over TCP with no data cable at all — power only. A socket has no control
pipe, which is why the protocol grew an in-band request (`glint_req_t`). The
first attempt was eight times too slow for a reason that had nothing to do with
the radio: lwIP's default 5.7 KB receive window against this round-trip time
capped it at 0.24 MB/s. A 64 KB window with scaling took it to 1.93 MB/s.

**Discovery.** With more than one board, "which panel?" became a real question.
Each board advertises `_glint._tcp` and sets its mDNS hostname *and* instance
name to `glint-<id>`, where the id is the low 16 bits of its factory MAC — the
same value the handshake reports as `dev_id`. The hosts find a panel by
themselves: USB when a cable is in, otherwise the first panel that answers.

**A third host, and the resolution problem.** A Raspberry Pi drives the same
panel with a pure-Go host — no cgo, no dependencies, usbfs ioctls straight to
the kernel. Being cgo-free means Go's pure resolver, which does not consult
avahi, so `.local` needed a small mDNS client of our own. The Pi can do
something macOS cannot: `fb -native` sets the console framebuffer to the
panel's exact size and streams **1:1**. `CGVirtualDisplay` refuses any mode
whose smaller dimension is under ~500 px, so the Mac renders 960×640 and
downscales exactly 2:1 — clean supersampling, but not native.

**Three boards from one image.** `menuconfig` picks the board; `board.h` holds
the profiles. The 1.75" AMOLED needed a QSPI path (CO5300, 32-bit commands, no
DC line) beside the SPI one.

**§11 still stands.** Everything above changed how pixels arrive, not what the
panel is for. It is still a status panel.
