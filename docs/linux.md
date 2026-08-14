# Linux Guide

This is the path for Raspberry Pi and other Linux hosts that drive the panel
without any virtual-display machinery.

The Linux host is pure Go: no cgo, no libusb, no external Go modules. USB goes
through usbfs ioctls, the framebuffer through `FBIOGET_VSCREENINFO`, and mDNS
through the query-only client in `linux/mdns/`.

## Quick Start

```sh
make pi
scp linux/glint-pi-arm64 <user>@<pi>:~/glint
scp packaging/70-glint.rules <user>@<pi>:~/
ssh <pi> sudo install -m 644 ~/70-glint.rules /etc/udev/rules.d/70-glint.rules
ssh <pi> sudo udevadm control --reload-rules
ssh <pi> sudo udevadm trigger
ssh <pi> ./glint fbinfo
ssh <pi> ./glint fb -native -landscape
```

`glint-pi-arm64` is for 64-bit Raspberry Pi OS. `glint-pi-armv6` covers a Pi
Zero W and 32-bit Pi OS.

## Build

From the repository root:

```sh
make pi
```

That produces:

- `linux/glint-pi-arm64`
- `linux/glint-pi-armv6`

Building by hand:

```sh
cd linux
go build ./cmd/glint
go test ./...
env GOOS=linux GOARCH=amd64 go build -o glint-amd64 ./cmd/glint
```

## USB Permissions

Without a udev rule the USB path needs root because `/dev/bus/usb/*` is owned
by `root:root`.

Install the rule once:

```sh
scp packaging/70-glint.rules <user>@<host>:~/
sudo install -m 644 ~/70-glint.rules /etc/udev/rules.d/70-glint.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

The rule grants `GROUP="plugdev", MODE="0660"`.

## Common Commands

```sh
glint panels                                 # panels on the network
glint hello                                  # handshake: geometry, fmt_mask, link
glint bars -seconds 10 -fps 10 [-full]
glint image -fill -landscape photo.jpg
glint fb -native -landscape                  # console at the panel's exact size
glint fb -dev /dev/fb0 -fps 30 [-full]
glint fbinfo
glint stats
glint touch
glint backlight 128
glint sleep 1

glint fb -net auto -native                   # any streaming mode over Wi-Fi
glint hello -net glint-335b.local -port 7788
```

Every mode starts with `CMD_HELLO` and adapts to the panel geometry the device
reports.

## Raspberry Pi Console Path

`glint fb` reads `/dev/fb0` directly, converts whatever framebuffer format the
kernel reports to RGB565, scales it to the panel, and sends tiled updates.

`glint fb -native` goes further and resizes the framebuffer to the panel so the
console renders at its final size with no resampling. This is the thing macOS
cannot do.

On slower Pi boards, use a smaller framebuffer mode in
`/boot/firmware/config.txt` (`/boot/config.txt` before Bookworm), for example:

```text
framebuffer_width=640
framebuffer_height=480
```

## Measured Performance

Raspberry Pi 3 driving the ESP32-P4 panel, colour bars with RLE:

| | tiled | whole frames (`-full`) |
|---|---|---|
| USB | 49.3 fps, 0.77 MB/s | 45.6 fps, 0.71 MB/s |
| Wi-Fi | 35.1 fps, 0.55 MB/s | 32.5 fps, 0.51 MB/s |

Both are well under the 1.93 MB/s this panel sustains to a Mac over the same
Wi-Fi, so the Pi's own render and encode is the limit here, not either link.

A static console sends almost nothing: 144 tiles across 548 frames at 1:1.

## Notes

- `.local` resolution is handled by `linux/mdns/`, not avahi, so the binary
  stays cgo-free.
- The Linux USB path is usbfs-based and Linux-only.
- There is no reconnection logic; if the panel goes away, the process exits and
  is expected to be restarted by a supervisor.

For the deeper Linux host details, testing notes, and implementation choices,
see [../linux/README.md](../linux/README.md). Protocol details live in
[../PROTOCOL.md](../PROTOCOL.md), and platform constraints live in
[../NOTES.md](../NOTES.md).
