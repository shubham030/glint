# macOS Guide

This is the path that turns the panel into a real extra display on macOS.

## Requirements

- ESP-IDF v5.5 at `~/esp/esp-idf-v5.5`, or `IDF_PATH` set to its location
- Swift toolchain
- `libusb` installed with Homebrew:

```sh
brew install libusb
```

`Package.swift` declares a macOS 13 minimum.

## Guided Setup

```sh
make setup
```

`make setup` identifies the board on a serial port, suggests the matching
firmware profile, offers Wi-Fi configuration, builds, flashes, and starts a
display session.

Re-running it is safe: it keeps an existing configuration rather than
overwriting it.

## Manual Setup

```sh
make            # build firmware + macOS host
make flash      # flash the panel over its UART port
make display    # extended desktop on the panel
```

If more than one serial device is attached, choose the port explicitly:

```sh
make flash PORT=/dev/cu.usbmodemXXXX
```

Board-specific flashing details live in [../HARDWARE.md](../HARDWARE.md).

## How Panel Discovery Works

`make display` finds a panel on its own:

- USB when a cable is connected
- otherwise the first panel answering on the network

Wi-Fi is off by default on the SPI boards, so a freshly flashed board is
USB-only until Wi-Fi is enabled and given credentials. Each board advertises
`_glint._tcp` as `glint-<id>.local`.

USB is preferred when both are available because it is much faster.

## Common Commands

```sh
make panels                              # every reachable panel
make display-wifi PANEL=glint-335b.local # wireless only
glint display --usb                      # USB only
glint display --serial glint-335b        # specific board, either transport
glint display --portrait                 # upright panel
glint display --name "Studio Panel"      # display name shown by macOS
glint display --touch --tp-swap --tp-flip-x
glint doctor
glint mirror --landscape
glint image photo.heic --fill
glint bars --seconds 10
glint touch --calibrate
glint stats
glint backlight 128
glint sleep 1
```

`make panels` runs `glint --list`, which marks a panel already serving another
session as in use.

## Useful Flags

- Colour shaping: `--sat P --con P`, or `--flat`
- Desktop size: `--width W --height H --1x`
- Frame cap: `--fps N`
- Disable tiling: `--full`

## Permissions

`glint display` needs Screen Recording permission.

If you use `--touch`, macOS Accessibility permission is needed too.

`glint doctor` checks:

- panel reachability
- Screen Recording permission
- Accessibility permission
- whether the private virtual-display path still works on your macOS build

## Login Start

```sh
make install-agent
```

This installs a LaunchAgent that starts `glint display` at login and restarts
it when the panel disappears.

Remove it with:

```sh
make uninstall-agent
```

## Limits

- macOS will not create a virtual display at the panel's native size, so glint
  uses a larger desktop and downscales it 2:1.
- `CGVirtualDisplay` is private API and can change under macOS updates.
- HiDPI is ignored for virtual displays.
- Screen Recording keeps the recording indicator active.

The deeper reasoning and platform-specific edge cases are documented in
[../NOTES.md](../NOTES.md) and [../DESIGN.md](../DESIGN.md).
