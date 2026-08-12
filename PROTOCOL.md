# glint wire protocol v1

`protocol/protocol.h` is the source of truth; this file explains it. Two
implementations must agree with it byte for byte: the Swift host
(`host/Sources/GlintCore/`) and the firmware (`firmware/main/`). A third, the
Go host (`linux/`), mirrors the same rules.

Little-endian throughout. Headers are 4-byte aligned and fixed-size — there is
no version negotiation beyond `proto_ver`, because a mismatched device should
fail the handshake rather than half-work.

## Transport

Two transports carry the identical byte stream; a host that can frame tiles can
use either.

### USB

A single **vendor-specific USB interface**, claimed from userspace. No kext, no
driver signing, nothing for the OS to bind to first (§10 of the README explains
why a pure vendor interface matters).

| | |
|---|---|
| VID:PID | `0xCAFE:0x4010` |
| Bulk OUT (host → device) | endpoint `0x01`, tiles |
| Bulk IN (device → host) | endpoint `0x81`, events |
| Control | vendor requests on the interface |

**ZLP rule.** A bulk transfer whose length is an exact multiple of the endpoint's
max packet size (512 on high speed, 64 on full speed) must be followed by a
zero-length packet, or the device waits forever for the rest of a transfer that
already ended. Both hosts do this in their bulk-write path; it is the classic
bring-up bug.

### TCP, over Wi-Fi

The same stream on a socket: **port 7788, one client at a time**. A socket has no
control pipe, so control travels in band as the 8-byte `glint_req_t` below, and
the HELLO reply comes back on the same stream rather than in a data stage.

Discovery is mDNS. The device advertises `_glint._tcp` on 7788 and sets its mDNS
**hostname and instance name to the same** `glint-<id>` string, where `<id>` is
the low 16 bits of the factory MAC — the same value the handshake reports as
`dev_id`. A browse result therefore becomes a connectable address by appending
`.local`, with no resolve step; the macOS host relies on that coupling, so
changing one name in firmware means changing both.

**A completed TCP connection does not mean the panel will serve you.** lwIP's
listen backlog finishes the handshake for a queued connection while the firmware
is still serving its one client, so `connect` succeeds against a panel that will
never answer — the same board reports free and busy in consecutive probes. Only a
HELLO round trip proves availability, which is what `glint --list` uses to mark a
panel *in use*, and what auto-selection uses to skip it.

## Handshake

The host issues `CMD_HELLO` as a vendor control **read** and the device answers
with the 24-byte `glint_hello_t` in the data stage. (The original design had
this arriving as a bulk IN event; a synchronous control read is the natural
shape, since the host can do nothing at all before it knows the geometry.)

```c
struct glint_hello {       // 24 bytes, device → host
    uint32_t magic;        // 'P4HL'
    uint16_t proto_ver;    // 1
    uint16_t panel_w;      // 320
    uint16_t panel_h;      // 480
    uint16_t fmt_mask;     // bit0 RGB565, bit1 RGB565_RLE, bit2 JPEG
    uint32_t max_tile_len; // largest single payload the device will accept
    uint16_t touch_points; // 2 with a working controller, 0 with none
    uint16_t dev_id;       // low 16 bits of the factory MAC; 0 before v1.1
    uint32_t fw_ver;
};
```

Everything downstream is derived from this reply: the host creates its virtual
display at the reported geometry, caps tile height at `max_tile_len`, and only
uses a payload format the device advertises. That last rule is what lets new
formats ship in firmware without breaking older hosts, and vice versa — a host
that knows RLE keeps sending raw pixels to firmware that predates it.

## Tiles (host → device, bulk OUT)

```c
struct glint_tile_hdr {    // 24 bytes, followed by payload_len bytes
    uint32_t magic;        // 'P4TD'
    uint16_t seq;          // frame sequence, wraps
    uint16_t flags;        // bit0 LAST_IN_FRAME, bit1 FULL_REFRESH
    uint16_t x, y;         // top-left, panel coords
    uint16_t w, h;         // tile dimensions
    uint16_t fmt;          // 0 RGB565LE, 1 RGB565_RLE, 2 JPEG
    uint16_t rsvd;
    uint32_t payload_len;  // wire bytes, i.e. compressed length for fmt 1
};
```

The host divides the panel into a **64×64 grid** (5×8 on this panel, bottom row
32 tall), hashes each tile, and sends only what changed. Horizontally adjacent
dirty tiles coalesce into one wider packet to cut header overhead. Tile height
is capped so a full-width run still fits `max_tile_len`.

`FULL_REFRESH` is set on the first frame of a session, after `CMD_RESET`, and
whenever the host learns the device dropped tiles. `LAST_IN_FRAME` marks the
final packet of a frame.

The device validates every header before trusting it: magic, `w`/`h` non-zero,
the rect inside the panel, the decoded size within `max_tile_len`, and the
payload length consistent with the format. A header that fails is discarded and
the parser resynchronises by sliding one byte — a corrupt stream must not paint
garbage.

The parser holds position inside a tile across reads, since a bulk transfer can
split anywhere. That position does **not** survive the host going away: it is
rewound on USB mount transitions and on `CMD_RESET`, because otherwise a cable
swap mid-payload leaves the device waiting for bytes that never come, and the
next session's first header gets eaten as the tail of a dead payload.

### fmt 0 — RGB565LE

Raw pixels, row-major, `w * h * 2` bytes. `payload_len` must equal exactly that.

### fmt 1 — RGB565_RLE

A stream of runs. Each begins with a 2-byte little-endian count word:

- **bit15 clear → RUN.** Low 15 bits are a pixel count (1…32767); the next two
  bytes are one RGB565 value repeated that many times. Four bytes on the wire
  regardless of run length.
- **bit15 set → LITERAL.** Low 15 bits are a pixel count; exactly that many
  RGB565 values follow verbatim.

Decoded pixels must total `w * h`; a stream that decodes to any other length is
corrupt and the tile is dropped. A single trailing byte after the last complete
run is ignored (it cannot begin a count word); two or more trailing bytes are a
malformed stream, because the extra word's count would overrun the tile. Runs of 3 or more pixels are worth a RUN word
(4 bytes) rather than staying in a LITERAL (2 bytes/pixel), which is where the
encoder's threshold comes from. Counts longer than `0x7FFF` are split across
consecutive words.

The host only uses RLE when the encoded tile is genuinely smaller than raw, so
photographic content silently stays uncompressed. Flat UI collapses hard — a
one-colour 64×64 tile goes from 8192 bytes to 4.

This matters most on the **full-speed** board variant (ESP32-S3), where USB
gives ~1 MB/s and is the bottleneck; on the high-speed P4 the panel's SPI bus is
the limit and RLE is mostly a latency win.

### fmt 2 — JPEG

Reserved. Worth having when a DSI panel with hardware JPEG decode makes it pay
(README §8); pointless at 320×480, where decode cost exceeds the bytes saved.

## Events (device → host)

Bulk IN on USB, the same bytes on the socket. **Every event is sent to every
live transport**, because the device cannot know where the host is: a producer
that talks to one transport only makes its events invisible to the other, which
looks exactly like broken hardware from the far end.

```c
struct glint_evt {         // 12 bytes
    uint32_t magic;        // 'P4EV'
    uint8_t  type;         // 1 DOWN, 2 MOVE, 3 UP, 4 HELLO, 5 STATS
    uint8_t  id;           // touch point id, 0..1
    uint16_t x, y;         // panel coords; for STATS see below
    uint16_t rsvd;
};
```

**Touch.** `touch_points` in the handshake reports what the controller actually
did at boot — 0 means no driver or no answer, so a host can say so instead of
waiting for taps that cannot come. The FT6336 is polled at 60 Hz and events are emitted only on change,
with a 2-pixel movement threshold so a resting finger does not stream MOVEs.
Coordinates are **panel-native** — the device deliberately does not know the
display's rotation, so the host owns the mapping (see "Touch mapping" below).

**STATS** (`type 5`) reuses the coordinate fields: `x` carries dropped tiles
plus sequence gaps, `y` carries resynchronisations. The device emits one per
second *only when a counter changed*, so an idle link is silent. When the host
sees either counter move it invalidates its tile hashes, which makes the next
frame a full refresh — that is the whole recovery mechanism, and it is why the
device does not need to ask for anything.

Host policy, which both hosts implement identically:

- **Either** counter counts. A resync means the device discarded bytes hunting
  for a tile magic or rejected a malformed header; like a drop, it means a tile
  never reached the panel.
- Movement in **any direction** counts. A counter going backwards means the
  device restarted its bookkeeping, which is equally divergent.
- A **first** report with non-zero counters means losses happened before the
  host started watching, so it refreshes then too.
- Something must **always** drain this pipe. The device's TX FIFO is small, and
  once it fills, later events — including these — are discarded. A host that
  only reads the pipe when it wants touch input leaves recovery silently dead.
- Known dead spot: the counters saturate at `0xFFFF`, after which further
  losses stop producing movement and no more refreshes are requested. Reaching
  it takes 65535 lost tiles, and a device reboot clears the counters long
  before that, so it is documented rather than worked around.

**HELLO** (`type 4`) is reserved for a device-initiated re-announce.

## Control requests

Vendor requests on the interface. `bmRequestType` is `0xC1` for the read and
`0x41` for the writes.

| `bRequest` | | |
|---|---|---|
| `0x01` | `CMD_HELLO` | IN, returns `glint_hello_t` |
| `0x02` | `CMD_BACKLIGHT` | `wValue` = 0…255 |
| `0x03` | `CMD_RESET` | drop queued tiles; host follows with a full refresh |
| `0x04` | `CMD_SLEEP` | `wValue` 1 = panel off, 0 = on; USB stays up |
| `0x05` | `CMD_BOOTLOADER` | reboot into the ROM download loader |

Unknown requests are stalled rather than silently accepted.

`CMD_BOOTLOADER` exists because these boards have no UART bridge on the data
port: without it, reflashing means holding BOOT while tapping RESET. It sets a
one-shot `RTC_NOINIT` flag and restarts — deliberately *not* the RTC
force-download strap, which survives every reset and only clears on true power
loss, stranding the board in the loader until it is physically unplugged.

### Over a socket

TCP has no control pipe, so the same commands travel in band as an 8-byte
request. The device answers `CMD_HELLO` with a `glint_hello_t` on the same
stream:

```c
struct glint_req {         // 8 bytes, host → device
    uint32_t magic;        // 'P4RQ'
    uint8_t  cmd;          // the CMD_* codes above
    uint8_t  rsvd;
    uint16_t value;        // what wValue would carry
};
```

The parser decides on the 4-byte magic alone, before it has a whole tile
header: a request is 8 bytes and a tile header is 24, so waiting for 24 would
deadlock against a host that sends a request and then waits for its reply.

## Touch mapping

Panel coordinates reach the host unrotated, and turning them into cursor
positions depends on how the touch glass is wired relative to the panel's scan
direction — which on this board includes a mirrored X in the panel init. Three
stacked transforms are far easier to measure than to reason about, so the host
provides `glint touch --calibrate`: tap three named corners and it prints the
`--tp-swap` / `--tp-flip-x` / `--tp-flip-y` combination to use. The flags are
stable per board.

## Design notes worth keeping

- **Geometry comes from the device, never a constant.** This is what makes the
  host resolution-agnostic and a future DSI panel a firmware-only change.
- **Formats are negotiated, not assumed.** `fmt_mask` means old firmware and new
  hosts interoperate in both directions.
- **The device is allowed to drop things.** Overload is handled by dropping
  tiles and telling the host, not by blocking the USB pipe — a stalled bulk
  endpoint would back up into the host's capture loop.
- **Corrupt input is discarded, not rendered.** Every length is checked against
  the geometry, both for raw and compressed payloads.
