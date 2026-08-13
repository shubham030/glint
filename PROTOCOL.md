# glint wire protocol v1

`protocol/protocol.h` is the source of truth; this file explains it. Three
implementations must agree with it byte for byte: the firmware
(`firmware/main/`), the Swift host (`host/Sources/GlintCore/`) and the Go host
(`linux/proto/`).

Little-endian throughout. Headers are 4-byte aligned and fixed-size. There is no
version negotiation beyond `proto_ver`: a device whose version does not match
should fail the handshake rather than half-work.

## Transports

Two transports carry an identical byte stream. A host that can frame tiles can
use either.

### USB

A single vendor-specific USB interface, claimed from userspace. Nothing in the
operating system binds to it first; [DESIGN.md](DESIGN.md) explains why the
interface is pure vendor class rather than composite.

| | |
|---|---|
| VID:PID | `0xCAFE:0x4010` |
| Bulk OUT (host → device) | endpoint `0x01`, tiles |
| Bulk IN (device → host) | endpoint `0x81`, events |
| Control | vendor requests on the interface |
| Serial string | `glint-<id>`, matching `dev_id` from the handshake |

`0xCAFE` is TinyUSB's example vendor ID. It is not registered to this project
and is fine for personal use only.

A bulk transfer whose length is an exact multiple of the endpoint's maximum
packet size (512 on high speed, 64 on full speed) must be followed by a
zero-length packet. Both hosts do this; see [NOTES.md](NOTES.md) for why.

### TCP, over Wi-Fi

The same stream on a socket: port 7788, one client at a time. A socket has no
control pipe, so control travels in band as the 8-byte `glint_req_t` below, and
the HELLO reply comes back on the same stream rather than in a data stage.

Discovery is mDNS. The device advertises `_glint._tcp` on port 7788 and sets its
mDNS hostname and its instance name to the same `glint-<id>` string, where
`<id>` is the low 16 bits of the factory MAC — the same value the handshake
reports as `dev_id`. A browse result therefore becomes a connectable address by
appending `.local`, with no resolve step. The macOS host relies on that
coupling, so changing one name in firmware means changing both.

A successful `connect` does not prove the panel is free. Only a HELLO round trip
does; see [NOTES.md](NOTES.md).

## Handshake

The host issues `CMD_HELLO` as a vendor control read and the device answers with
a 24-byte `glint_hello_t` in the data stage. Over TCP the same request travels
in band and the reply comes back on the stream.

```c
struct glint_hello {       // 24 bytes, device → host
    uint32_t magic;        // 'P4HL'
    uint16_t proto_ver;    // 1
    uint16_t panel_w;
    uint16_t panel_h;
    uint16_t fmt_mask;     // bit0 RGB565, bit1 RGB565_RLE, bit2 JPEG
    uint32_t max_tile_len; // largest single payload the device will accept
    uint16_t touch_points; // points the controller reported at boot; 0 if none
    uint16_t dev_id;       // low 16 bits of the factory MAC; 0 before v1.1
    uint32_t fw_ver;
};
```

Everything downstream derives from this reply. The host creates its display at
the reported geometry, sizes its tile grid so that no packet exceeds
`max_tile_len`, and uses only a payload format the device advertises in
`fmt_mask`. Negotiating the format is what lets new formats ship in firmware
without breaking older hosts, and the reverse: a host that knows RLE keeps
sending raw pixels to firmware that predates it.

`dev_id` was a reserved field, so firmware predating it reports 0 and hosts must
tolerate that.

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

The host divides the panel into a grid of 64-pixel columns, hashes each cell,
and sends only what changed. Horizontally adjacent dirty cells coalesce into one
wider packet to cut header overhead. Cell height is 64 pixels, or less if
`max_tile_len` will not hold a full-width run at that height. Both grid
dimensions therefore follow from the handshake: a 320x480 panel reporting a
40960-byte `max_tile_len` yields 5 columns by 8 rows, the bottom row 32 pixels
tall.

`FULL_REFRESH` is set on the first frame of a session, after `CMD_RESET`, and
whenever the host learns the device dropped tiles. `LAST_IN_FRAME` marks the
final packet of a frame. The sequence number advances only on frames that
actually sent something.

The device validates a header before trusting it: the magic, `w` and `h`
non-zero, the rect inside the panel, the decoded size within `max_tile_len`, and
the payload length consistent with the declared format. A header that fails any
of these is discarded and the parser resynchronises by sliding forward one byte.

The parser holds its position inside a tile across reads, since a bulk transfer
can split anywhere. That position does not survive the host going away: it is
rewound on USB mount transitions and on `CMD_RESET`. Without the rewind, a cable
swap mid-payload leaves the device waiting for bytes that never come, and the
next session's first header is consumed as the tail of a dead payload.

### fmt 0 — RGB565LE

Raw pixels, row-major, `w * h * 2` bytes. `payload_len` must equal exactly that.

### fmt 1 — RGB565_RLE

A stream of runs. Each begins with a 2-byte little-endian count word:

- **bit15 clear — RUN.** The low 15 bits are a pixel count of 1 to 32767; the
  next two bytes are one RGB565 value repeated that many times. Four bytes on
  the wire regardless of run length.
- **bit15 set — LITERAL.** The low 15 bits are a pixel count; exactly that many
  RGB565 values follow verbatim.

Decoded pixels must total `w * h`. A stream that decodes to any other length is
corrupt and the tile is dropped. A single trailing byte after the last complete
run is ignored, since it cannot begin a count word; two or more trailing bytes
are malformed, because the extra word's count would overrun the tile. Counts
longer than `0x7FFF` are split across consecutive words.

A run of 3 or more pixels costs 4 bytes as a RUN and 6 or more inside a LITERAL,
which is where the encoder's threshold comes from. The host uses RLE only when
the encoded tile is smaller than raw, so photographic content stays
uncompressed. Flat interface regions collapse hard: a one-colour 64x64 tile goes
from 8192 bytes to 4.

### fmt 2 — JPEG

Reserved, and advertised by no current firmware. It becomes worthwhile with a
panel fast enough that decode cost is below the bytes saved; see
[DESIGN.md](DESIGN.md).

## Events (device → host)

Bulk IN on USB, the same bytes on the socket. Every event is sent to every live
transport, because the device cannot know which one the host is listening on.

```c
struct glint_evt {         // 12 bytes
    uint32_t magic;        // 'P4EV'
    uint8_t  type;         // 1 DOWN, 2 MOVE, 3 UP, 4 HELLO, 5 STATS
    uint8_t  id;           // touch point id, 0..1
    uint16_t x, y;         // panel coords; for STATS see below
    uint16_t rsvd;
};
```

**Touch.** `touch_points` in the handshake reports what the controller answered
at boot, so 0 means no driver or no response and a host can say so rather than
waiting for taps that cannot come. The controller is polled at 60 Hz and events
are emitted only on change, with a 2-pixel movement threshold so a resting
finger does not stream MOVEs. Coordinates are panel-native: the device does not
know the display's rotation, so the host owns the mapping.

**STATS** (`type 5`) reuses the coordinate fields: `x` carries dropped tiles
plus sequence gaps, `y` carries resynchronisations. Both are cumulative and
saturate at `0xFFFF`. The device emits one report per second, and only when a
counter changed, so an idle link is silent. When the host sees either counter
move it invalidates its tile hashes, which makes the next frame a full refresh.
That is the whole recovery mechanism; the device never has to ask for anything.

Host policy, implemented identically by both hosts:

- Either counter counts. A resync means the device discarded bytes hunting for a
  tile magic or rejected a malformed header, which like a drop means a tile
  never reached the panel.
- Movement in either direction counts. A counter going backwards means the
  device restarted its bookkeeping, which is equally divergent.
- A first report with non-zero counters means losses happened before the host
  started watching, so it refreshes then too.
- Something must always drain this pipe. The device's TX FIFO is small, and once
  it fills, later events — including these — are discarded. A host that reads
  the pipe only when it wants touch input leaves recovery silently dead.
- Once the counters saturate, further losses stop producing movement and no more
  refreshes are requested. Reaching that takes 65535 lost tiles, and a device
  reboot clears the counters, so it is documented rather than worked around.

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

`CMD_BOOTLOADER` exists because a board with no UART bridge on its data port
otherwise needs the BOOT-and-RESET button sequence to reflash. It sets a
one-shot `RTC_NOINIT` flag and restarts. It is deliberately not the RTC
force-download strap, which survives every reset and clears only on true power
loss, stranding the board in the loader until it is physically unplugged. A
board whose data port cannot present a serial device refuses the request; see
[NOTES.md](NOTES.md).

### Over a socket

TCP has no control pipe, so the same commands travel in band as an 8-byte
request. The device answers `CMD_HELLO` with a `glint_hello_t` on the same
stream.

```c
struct glint_req {         // 8 bytes, host → device
    uint32_t magic;        // 'P4RQ'
    uint8_t  cmd;          // the CMD_* codes above
    uint8_t  rsvd;
    uint16_t value;        // what wValue would carry
};
```

The parser decides on the 4-byte magic alone, before it has a whole tile header.
A request is 8 bytes and a tile header is 24, so waiting for 24 bytes would
deadlock against a host that sends a request and then waits for the reply.

## Touch mapping

Panel coordinates reach the host unrotated. Turning them into cursor positions
depends on how the touch glass is wired relative to the panel's scan direction,
which on some boards includes a mirrored X in the panel init. The host applies up
to three transforms — `--tp-swap`, `--tp-flip-x`, `--tp-flip-y` — and
`glint touch --calibrate` derives the right combination from three taps. The
flags are stable per board; measured values are in [HARDWARE.md](HARDWARE.md).

## Properties this design depends on

- **Geometry comes from the device, never a constant.** This is what makes the
  hosts resolution-agnostic and a different panel a firmware-only change.
- **Formats are negotiated, not assumed.** `fmt_mask` means old firmware and new
  hosts interoperate in both directions.
- **The device may drop things.** Overload is handled by dropping tiles and
  telling the host, not by blocking the pipe; a stalled bulk endpoint would back
  up into the host's capture loop.
- **Corrupt input is discarded, not rendered.** Header fields are checked against
  the panel geometry and payload lengths against the declared format, for both
  raw and compressed payloads, before any pixels are written.
