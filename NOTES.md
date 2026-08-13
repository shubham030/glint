# Constraints worth knowing

Non-obvious properties of the platforms glint sits on. Each one changes a design
decision somewhere in the code, and none of them is discoverable from the
relevant API documentation.

## macOS refuses small virtual displays

`CGVirtualDisplay` will not give you a mode whose smaller dimension is under
about 500 px. A mode narrower than about 800 px is coerced to something else,
and `CGDisplaySetDisplayMode` back to the exact requested mode fails with
`CGError 1001`. The panel's native 480x320 is therefore unreachable, so
`glint display` runs a 960x640 desktop and the stream scaler downscales it
exactly 2:1. Working sizes are 960x640 and 800x534 in landscape, and 640x960 in
portrait; text is always rendered at twice its final size, which is where the
slight softness comes from.

## WindowServer keys a virtual display on vendor/product/serial

Two displays sharing that triple are one identity as far as WindowServer is
concerned, and it does not reliably release the previous registration before the
next process starts. The second display is then created — `CGDisplayBounds` even
answers for it — but never comes online and never appears in shareable content,
so capture has nothing to attach to. glint takes two measures: the host releases
the display from its `SIGINT`/`SIGTERM` handler rather than leaving it to
process teardown, and `glint display` retries with a varied serial instead of
failing. A retry costs that panel's saved arrangement in System Settings, since
a different serial is a different display to macOS.

## The ESP32-P4 board's OTG port cannot present a serial device

On the ESP32-P4-WIFI6-Touch-LCD-3.5 the OTG Type-C is wired to the UTMI
(high-speed) PHY, while USB-Serial-JTAG needs the internal full-speed PHY. No
serial device can appear on the data port, whatever the firmware asks for.
Honouring a bootloader-reboot request there leaves a board that is neither a
working panel nor flashable until it is power-cycled, so the firmware declines
the request on this board (`BOARD_CAN_SERIAL_BOOT 0`) and logs why. That board
is flashed over its separate UART Type-C instead. The ESP32-S3 boards have one
data port muxed to USB-Serial-JTAG, where `glint bootloader` does work.

## lwIP's default TCP window is the Wi-Fi bottleneck

TCP throughput is bounded by window size divided by round-trip time, and lwIP's
default receive window is 5.7 KB. Against a measured 28-39 ms RTT on a domestic
LAN that caps the link near 0.24 MB/s regardless of what the radio can do. The
firmware configures a 64 KB window with window scaling
(`CONFIG_LWIP_TCP_WND_DEFAULT`, `CONFIG_LWIP_WND_SCALE`), which measures
1.93 MB/s to the same board.

## A completed TCP connection does not mean the panel will serve you

The firmware handles one client at a time, but lwIP's listen backlog completes
the handshake for a queued connection while that client is being served. A
`connect` therefore succeeds against a panel that will never answer, and the
same board can look free and busy in consecutive probes. Only a HELLO round trip
proves availability. That is what `glint --list` uses to mark a panel as in use,
and what automatic panel selection uses to skip one.

## A cgo-free Go binary cannot resolve `.local` through avahi

Building without cgo selects Go's pure resolver, which does not consult
nss-mdns. A `.local` name fails to resolve even on a host running
`avahi-daemon`, because the lookup never reaches it. The Linux host is deliberately
cgo-free so it cross-compiles with no libusb and no network, so it carries its
own query-only mDNS client in `linux/mdns/` to browse `_glint._tcp` and resolve
the names it finds.

## Bulk transfers that are a multiple of the max packet size need a ZLP

USB has no length field on a bulk transfer: the receiver knows a transfer ended
when a packet arrives that is shorter than the endpoint's maximum. A transfer
whose length is an exact multiple of that maximum — 512 bytes on high speed, 64
on full speed — produces no such packet, so the device waits for the remainder
of a transfer that already finished. Both hosts append a zero-length packet in
that case. The Linux host reads the packet size from the endpoint descriptor in
sysfs and falls back to what the link speed implies.

## Only one process may flash a board at a time

Two writers to the same board interleave their writes, and the resulting
corruption is reported by every tool involved as a plausible local fault: a
mid-write abort reads as a flaky UART, and the boot loop afterwards reads as a
crash in whatever changed last. Tells that it is a second writer are an
`esp_image` segment error with an ASCII-looking `vaddr`, or a flash that writes
the bootloader, verifies, then fails with "device reports readiness to read but
returned no data". Confirm by running `esptool image_info` on your own binary: if
the local file validates, the file is fine and the flash is not. Recovery is
`erase_flash` followed by a full flash — never app-only, or the previous
image's partition table survives and will not match the new bootloader.

## Panels with rounded corners cannot be tapped at their true corners

There is no glass at (0,0) on a rounded panel, so calibration taps land some way
inside the extremes — on the 1.75" AMOLED, around 25% and 76% of the way across.
Absolute tap coordinates are therefore not usable as axis endpoints. The mapping
is derived from relationships between taps instead: which axis moves when the
tap moves right settles whether the axes are swapped, and the sign of that
movement settles each flip. `glint touch --calibrate` implements this; reading
corner coordinates by eye and deciding the axes look swapped is the failure it
exists to prevent.
