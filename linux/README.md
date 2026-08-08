# glint — Linux host

A pure-Go host for the glint panel. Same wire protocol as the macOS host
(`protocol/protocol.h` is the source of truth), aimed at a **Raspberry Pi Zero W**
driving the panel as a standalone dashboard, and at amd64 Linux desktops.

**No cgo, no libusb, no external Go modules.** USB goes straight to the kernel
through usbfs ioctls; the framebuffer through `FBIOGET_VSCREENINFO`. `go.mod`
has zero requires, so cross-compiling is one command with no network.

```
linux/
  proto/   wire format, dirty-tile coalescer, RGB565 RLE codec  (platform-neutral, tested)
  render/  colour bars, PNG/JPEG loading, box scaler, framebuffer pixel conversion (tested)
  fb/      Linux framebuffer device (ioctls in fb_linux.go)
  usbfs/   USB transport: sysfs discovery + USBDEVFS ioctls (ioctl_linux.go)
  cmd/glint/  the CLI
```

## Build

Native (whatever you are on — the CLI compiles on macOS too, it just cannot
open a device there):

```sh
cd linux
go build ./cmd/glint
go test ./...
```

Raspberry Pi Zero W — BCM2835, ARM1176, **armv6**, so `GOARM=6` is mandatory
(`GOARM=7` binaries die with SIGILL on that chip):

```sh
env GOOS=linux GOARCH=arm GOARM=6 go build -trimpath -ldflags="-s -w" -o glint-armv6 ./cmd/glint
scp glint-armv6 pi@raspberrypi:~/glint
```

64-bit Linux desktop (or a Pi 4/5 running a 64-bit OS):

```sh
env GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o glint-amd64 ./cmd/glint
env GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o glint-arm64 ./cmd/glint
```

The usbfs ioctl numbers encode the size of a struct containing a pointer, so
they differ between 32-bit and 64-bit userspace. The structs are declared with
real pointer fields and the request numbers are computed from
`unsafe.Sizeof`, so both widths are correct by construction —
`usbfs/ioctl_test.go` pins the resulting numbers against the kernel's.

## udev

Without a rule you need root. Create `/etc/udev/rules.d/70-glint.rules`:

```
SUBSYSTEM=="usb", ATTR{idVendor}=="cafe", ATTR{idProduct}=="4010", MODE="0666"
```

then

```sh
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Replug the panel afterwards. (`MODE="0666"` is world-writable; for a shared
machine prefer `GROUP="plugdev", MODE="0660"` and add yourself to `plugdev`.)

## Run

```sh
glint hello                                  # handshake; prints geometry, fmt_mask, USB speed
glint bars -seconds 10 -fps 10               # animated colour bars: the transport test
glint image -fill -landscape photo.jpg       # PNG/JPEG, scaled to the panel
glint fb -dev /dev/fb0 -fps 30 -landscape    # mirror the Linux console framebuffer
glint stats                                  # dropped-tile / resync counters from the device
glint touch                                  # touch events in panel coordinates (calibration)
glint backlight 128
glint sleep 1                                # 1 = panel off, 0 = on
```

Every mode starts with the `CMD_HELLO` control read and adapts to the geometry
the device reports — nothing is hardcoded to 320x480.

Flags come **before** the positional argument (`glint image -fill photo.png`),
as the standard `flag` package requires. Streaming modes run until Ctrl-C
unless `-seconds` is given.

### The Pi console path

`glint fb` needs no X server: it reads `/dev/fb0` directly, converts whatever
bpp the driver reports to RGB565, scales it to the panel and tiles it out. On a
Pi Zero W, put it in a systemd unit and you have a headless dashboard. Force a
small console mode in `/boot/config.txt` (e.g. `framebuffer_width=640`,
`framebuffer_height=480`) — the scaler cost is proportional to the source area,
and the Zero's ARM11 is not fast.

## Design notes

**Tiling** mirrors `host/Sources/GlintCore/Tiles.swift` exactly: a 64-pixel
grid, FNV-1a over each tile's RGB565 pixels, only changed tiles sent,
horizontally adjacent dirty tiles coalesced into one wider packet, tile height
capped by the device's `max_tile_len`, `FULL_REFRESH` on the first frame or
after `Invalidate()`, `LAST_IN_FRAME` on the last packet of a frame. The
sequence number only advances on frames that actually sent something.

**RLE (fmt 1)** is encoded per packet and used only when it is both advertised
in `fmt_mask` *and* smaller than the raw payload — a photo tile encodes larger
than raw, and firmware that only advertises `RGB565` must never be handed
fmt 1. `proto/rle_test.go` pins the byte layout against `firmware/main/rle.c`.

**ZLP.** Bulk writes whose total length is an exact multiple of the endpoint's
max packet size are followed by a zero-length packet. The packet size comes
from the endpoint descriptor in sysfs
(`.../<dev>:1.0/ep_01/wMaxPacketSize`), falling back to what the link speed
implies (512 high speed, 64 full speed). Long writes are split into 16 KiB
chunks because usbfs bounces each transfer through one kernel allocation;
16 KiB is a multiple of every bulk packet size, so no chunk boundary can create
a spurious short packet mid-stream.

**Scaling** is a box filter (area average) with precomputed per-axis sample
ranges, degenerating to nearest-neighbour where the image is magnified. Good
for the downscale case that matters; there is no bilinear/Lanczos path. Colour
is passed through untouched — the macOS host's `--sat`/`--con` shaping is not
implemented here.

**Cancellation.** Streaming loops take a `context.Context` wired to SIGINT and
SIGTERM. The usbfs ioctls block, so cancellation lands between transfers —
worst case one 2-second write timeout.

## Untested on hardware

No panel was attached at any point while this was written. Everything below is
**unverified against a real device** — it compiles, it is unit-tested against
the protocol headers and the firmware's own decoder, and that is all:

- **Every USB transfer.** No control read, control write, bulk write or bulk
  read has ever run against the device. The ioctl numbers and struct layouts
  are unit-tested against the kernel's documented values, not against a kernel.
- **`CLAIMINTERFACE`**, including whether anything else on the system tries to
  claim the vendor interface first (there should not be — it is a pure vendor
  class). No `USBDEVFS_DISCONNECT_CLAIM` / driver-unbind fallback is
  implemented; if claim returns `EBUSY` you will need to unbind by hand.
- **The ZLP rule.** The logic is there and the packet size is read from sysfs,
  but whether the panel actually needs the terminator (and whether the kernel
  emits it for a zero-length `USBDEVFS_BULK`) has not been observed.
- **The 16 KiB chunking.** No kernel has been asked for a 40 KB single bulk
  transfer to confirm the limit needs working around at all.
- **Throughput and frame rate.** The `-fps` defaults are copied from the macOS
  host. Whether a Pi Zero W can convert, scale, hash and push 30 fps is
  unknown; expect to lower it.
- **`glint fb`.** Nothing has been read from a real `/dev/fb0`: not the ioctl
  struct layouts, not the truecolour-visual check, not the `read()`-based frame
  grab (some drivers only support `mmap`), not panning via `yoffset`.
- **RLE end to end.** The encoder is verified against the format described in
  `firmware/main/rle.c` by round-tripping through a Go decoder written from the
  same rules. It has never been decoded *by the firmware*.
- **Touch and STATS decoding.** The 12-byte layout is pinned by tests, but no
  real event has been parsed. The STATS field meanings (`x` = dropped tiles +
  sequence gaps, `y` = resyncs) are read off the current firmware source.
- **Landscape orientation.** The rotation matches the macOS host's transform as
  derived from its CoreGraphics code, but which way to physically mount the
  panel has not been confirmed by looking at one.
- **Device discovery** across hubs, multiple matching devices, and re-plug
  (there is no hotplug/reconnect logic: if the device goes away, the process
  exits with an error).
