# ESP32-P4 as a macOS Extended Display

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

Little-endian throughout. Headers 4-byte aligned.

The C structs in [`protocol/protocol.h`](protocol/protocol.h) are the source of
truth; deviations from this section are documented there.

### 5.1 Handshake

On attach, host sends `CMD_HELLO` (see §5.4); device replies with a `HELLO`
event carrying panel geometry. The host then creates the virtual display at
*that* geometry.

Do this properly from day one — it's what makes the Mac app
resolution-agnostic and lets the DSI upgrade in §8 be a firmware-only change.

```c
struct p4_hello {          // 24 bytes, device → host
    uint32_t magic;        // 'P4HL' 0x4C483450
    uint16_t proto_ver;    // 1
    uint16_t panel_w;      // 320
    uint16_t panel_h;      // 480
    uint16_t fmt_mask;     // bit0 RGB565, bit1 RGB565_RLE, bit2 JPEG
    uint32_t max_tile_len; // largest single payload device will accept
    uint16_t touch_points; // 2 on FT6336
    uint16_t rsvd;
    uint32_t fw_ver;
};
```

### 5.2 Tile packet (host → device, bulk OUT)

```c
struct p4_tile_hdr {       // 24 bytes, followed by payload_len bytes
    uint32_t magic;        // 'P4TD' 0x44543450
    uint16_t seq;          // frame sequence, wraps
    uint16_t flags;        // bit0 LAST_IN_FRAME, bit1 FULL_REFRESH
    uint16_t x, y;         // top-left, panel coords
    uint16_t w, h;         // tile dimensions
    uint16_t fmt;          // 0=RGB565LE 1=RGB565_RLE 2=JPEG
    uint16_t rsvd;
    uint32_t payload_len;
};
```

- Tile grid: **64×64**. 320×480 → 5 cols × 8 rows (bottom row 32px tall). One
  tile = 8KB RGB565, comfortably under any staging buffer.
- Coalesce horizontally adjacent dirty tiles into one packet (wider `w`) to cut
  header overhead.
- `FULL_REFRESH` on connect, resume from sleep, and after any `seq` gap the
  device detects.
- USB HS bulk max packet is 512B. Pad the header+payload to a 512B boundary
  where it's cheap; avoid exact-multiple transfers without a ZLP.

### 5.3 Event packet (device → host, bulk IN)

```c
struct p4_evt {            // 12 bytes
    uint32_t magic;        // 'P4EV' 0x56453450
    uint8_t  type;         // 1=DOWN 2=MOVE 3=UP 4=HELLO 5=STATS
    uint8_t  id;           // touch point id, 0..1
    uint16_t x, y;         // panel coords
    uint16_t rsvd;
};
```

Poll FT6336 at 60Hz; emit on change only. `STATS` carries dropped-tile count
and mean draw latency — worth having during bring-up.

### 5.4 Control

Vendor control transfers, `bRequest`:

| | |
|---|---|
| `0x01 CMD_HELLO` | request device info |
| `0x02 CMD_BACKLIGHT` | wValue = 0..255 |
| `0x03 CMD_RESET` | drop state, force full refresh |
| `0x04 CMD_SLEEP` | panel off, keep USB alive |

---

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

Start SPI at 40MHz. Walk it up to 80MHz once the pipeline is stable — the
practical ceiling varies board to board and shows up as tearing or corrupt
tiles, not clean failure.

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

| | | Proves |
|---|---|---|
| M0 | Colour bars pushed over USB from a Mac CLI tool | Transport + framing |
| M1 | Static PNG → full-frame → panel | Format conversion, SPI throughput |
| M2 | ScreenCaptureKit on the **main** display → panel | Capture + convert pipeline |
| M3 | Swap in CGVirtualDisplay | The private-API half |
| M4 | Dirty-rect tiling | Usable frame rate |
| M5 | FT6336 → CGEventPost | Input loop |
| M6 | DSI panel swap | §8 |

M0–M2 need no private APIs and are where most of the risk lives. Don't touch
`CGVirtualDisplay` until M2 works.

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
