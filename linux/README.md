# glint — Linux host

A pure-Go host for a glint panel, aimed at a Raspberry Pi driving the panel as a
standalone dashboard, and at amd64 Linux desktops. It speaks the same wire
protocol as the macOS host; `protocol/protocol.h` is the source of truth and
[PROTOCOL.md](../PROTOCOL.md) explains it.

No cgo, no libusb, no external Go modules. USB goes straight to the kernel
through usbfs ioctls, the framebuffer through `FBIOGET_VSCREENINFO`, and mDNS
through a query-only client in `mdns/`. `go.mod` has zero requires, so
cross-compiling is one command with no network.

Measured on a Pi 3 driving the ESP32-P4 panel, colour bars with RLE:

| | tiled | whole frames (`-full`) |
|---|---|---|
| USB | 49.3 fps, 0.77 MB/s | 45.6 fps, 0.71 MB/s |
| Wi-Fi | 35.1 fps, 0.55 MB/s | 32.5 fps, 0.51 MB/s |

Both figures are well under the 1.93 MB/s the same panel sustains to a Mac over
the same Wi-Fi, so the Pi's own render and encode is the limit here, not either
link.

```
linux/
  mdns/       query-only mDNS: browse _glint._tcp, resolve .local
  proto/      wire format, dirty-tile coalescer, RGB565 RLE codec
  render/     colour bars, PNG/JPEG loading, box scaler, pixel conversion
  fb/         Linux framebuffer device (ioctls in fb_linux.go)
  usbfs/      USB transport: sysfs discovery + USBDEVFS ioctls
  cmd/glint/  the CLI
```

## Build

`go.mod` requires Go 1.21 or newer. The repository Makefile cross-compiles both
Pi shapes from the project root:

```sh
make pi   # produces linux/glint-pi-arm64 and linux/glint-pi-armv6
```

`glint-pi-arm64` is for 64-bit Raspberry Pi OS, which means a Pi 3 or newer.
`glint-pi-armv6` covers a Pi Zero W and 32-bit Pi OS anywhere. `uname -m` on the
target says which you need: `aarch64` or `armv6l`/`armv7l`. `GOARM=6` is not
optional for the Zero W — the BCM2835's ARM1176 dies with SIGILL on a `GOARM=7`
binary.

Building by hand, or for an amd64 desktop:

```sh
cd linux
go build ./cmd/glint                                      # native
go test ./...
env GOOS=linux GOARCH=amd64 go build -o glint-amd64 ./cmd/glint
```

The CLI compiles on macOS too; it just cannot open a device there, since the
`_linux.go` files are replaced by stubs.

The usbfs ioctl request numbers encode the size of a struct containing a
pointer, so they differ between 32-bit and 64-bit userspace. The structs are
declared with real pointer fields and the request numbers computed from
`unsafe.Sizeof`, and `usbfs/ioctl_test.go` pins the resulting numbers against
the kernel's documented values.

## udev

Without a rule you need root: `/dev/bus/usb/*` is `root:root 0664`, so the host
reports `permission denied` on the device node. The rule ships in the repository:

```sh
scp packaging/70-glint.rules <user>@<host>:~/
sudo install -m 644 ~/70-glint.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

It grants `GROUP="plugdev", MODE="0660"`. Raspberry Pi OS already puts the
default user in `plugdev`, and world-writable is more than this needs.
`udevadm trigger` re-applies the rule to an already-attached panel, so there is
no need to replug.

## Run

```sh
glint panels                                 # panels on the network (no panel needed)
glint hello                                  # handshake: geometry, fmt_mask, link
glint bars -seconds 10 -fps 10 [-full]       # colour bars: the transport test
glint image -fill -landscape photo.jpg       # PNG or JPEG, scaled to the panel
glint fb -native -landscape                  # the console, at the panel's exact size
glint fb -dev /dev/fb0 -fps 30 [-full]       # or scaled from whatever mode is set
glint fbinfo                                 # framebuffer geometry (no panel needed)
glint stats                                  # dropped-tile and resync counters
glint touch                                  # touch events in panel coordinates
glint backlight 128
glint sleep 1                                # 1 = panel off, 0 = on

glint fb -net auto -native                   # any of the above, over Wi-Fi
glint hello -net glint-335b.local -port 7788 # or naming the board
```

`glint panels` is this host's equivalent of the macOS host's `glint --list`.

Every mode starts with the `CMD_HELLO` handshake and adapts to the geometry the
device reports; nothing is hardcoded to one panel size. `-net <host|auto>` and
`-port N` work on every mode. `-full` disables tiling on `bars` and `fb`.

Flags come before the positional argument (`glint image -fill photo.png`), as
the standard `flag` package requires. Streaming modes run until Ctrl-C unless
`-seconds` is given.

`.local` names are resolved by `mdns/`, a small query-only client, because a
cgo-free binary cannot reach avahi. See [NOTES.md](../NOTES.md).

## Matching the panel exactly

`fb -native` resizes the framebuffer to the panel — rotated when `-landscape` —
before streaming, and restores the previous mode on exit. The console then
renders at its final size with no scaling and no resampled glyphs. A 1024x768
console squeezed into 320x480 is unreadable however good the scaler is; at 1:1
the standard console font is legible.

This is the thing macOS cannot do. `CGVirtualDisplay` refuses modes whose
smaller dimension is under about 500 px, so the Mac renders 960x640 and
downscales 2:1. On Linux the framebuffer geometry is settable directly.

## The Pi console path

`glint fb` needs no X server: it reads `/dev/fb0` directly, converts whatever
bpp the driver reports to RGB565, scales it to the panel and tiles it out. Put
it in a systemd unit and the Pi is a headless dashboard.

On a slower Pi, force a small console mode in `/boot/config.txt` (for example
`framebuffer_width=640`, `framebuffer_height=480`). The scaler's cost is
proportional to the source area, and the Zero's ARM11 is not fast.

## Implementation notes

**Tiling** mirrors `host/Sources/GlintCore/Tiles.swift`: a 64-pixel grid, FNV-1a
over each tile's RGB565 pixels, only changed tiles sent, horizontally adjacent
dirty tiles coalesced into one wider packet, tile height capped by the device's
`max_tile_len`, `FULL_REFRESH` on the first frame and after `Invalidate()`,
`LAST_IN_FRAME` on the last packet of a frame. The sequence number advances only
on frames that actually sent something.

**RLE (fmt 1)** is encoded per packet and used only when it is both advertised
in `fmt_mask` and smaller than the raw payload. A photographic tile encodes
larger than raw, and firmware that advertises only `RGB565` must never be handed
fmt 1. `proto/rle_test.go` pins the byte layout against `firmware/main/rle.c`,
and `proto/fixture_test.go` pins the encoder's output against the Swift
encoder's.

**Resync.** `glint fb` drains bulk IN from a goroutine for as long as it
streams, and forces a `FULL_REFRESH` when the device's STATS counters move. The
pipe is drained whether or not anyone asked for events: the device's TX FIFO is
small, and once it fills the firmware discards every later event, including the
STATS reports the mechanism depends on. The tiler is not concurrency-safe, so
the reader only raises an atomic flag and the frame loop does the invalidating
between frames.

**ZLP.** Bulk writes whose total length is an exact multiple of the endpoint's
maximum packet size are followed by a zero-length packet; see
[NOTES.md](../NOTES.md). The packet size comes from the endpoint descriptor in
sysfs (`.../<dev>:1.0/ep_01/wMaxPacketSize`), falling back to what the link
speed implies. Long writes are split into 16 KiB chunks, because usbfs bounces
each transfer through a single kernel allocation. 16 KiB is a multiple of every
bulk packet size, so no chunk boundary can create a spurious short packet
mid-stream.

**Scaling** is a box filter (area average) with precomputed per-axis sample
ranges, degenerating to nearest-neighbour where the image is magnified. That
suits the downscale case that matters; there is no bilinear or Lanczos path.
Colour passes through untouched — the macOS host's `--sat`/`--con` shaping is
not implemented here.

**Cancellation.** Streaming loops take a `context.Context` wired to SIGINT and
SIGTERM. The usbfs ioctls block, so cancellation lands between transfers, worst
case one 2-second write timeout.

**Reconnection.** There is none. If the device goes away the process exits with
an error, on the assumption that a supervisor restarts it.

## Testing

**Unit tests, any machine.** `go test ./...` covers the wire format, the tile
coalescer, the RLE codec, the scaler, the framebuffer pixel conversion, the CLI
argument parsing, and — since discovery is plain filesystem reads — device
discovery against a synthetic sysfs tree (`usbfs/sysfs_test.go`): hubs,
non-matching devices, missing and malformed attributes, the endpoint descriptor
and the speed fallback.

**Real Linux in a container**, which matters because on macOS the `_linux.go`
files never execute:

```sh
docker run --rm -v "$PWD":/src -w /src golang:1.23 go test ./...
docker run --rm --platform linux/arm/v7 -v "$PWD":/src -w /src \
    arm32v7/golang:1.23 go test ./...
```

The second is the valuable one: running on 32-bit ARM checks the ioctl layout
the Pi will actually use rather than one modelled from a 64-bit host. A
container cannot substitute for hardware, though — there is no USB passthrough
on macOS and no `/lib/modules`, so no usbfs or fbdev ioctl runs against a real
kernel there.

**A Pi with the panel attached** is the real test. Start with `glint hello`: it
exercises discovery, the interface claim and a control transfer, which is most
of the transport in one command.
