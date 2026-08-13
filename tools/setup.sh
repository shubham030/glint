#!/bin/sh
# Interactive first run: identify the board, build the firmware for it, flash
# it, and start a display.
#
# Everything here can be done by hand — each step prints the command it runs, so
# this is a guide rather than a black box. Re-running is safe: it reconfigures
# and reflashes, and nothing is destroyed but the firmware you are replacing.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

BOLD=''; DIM=''; RESET=''
if [ -t 1 ]; then BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RESET=$(printf '\033[0m'); fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
run()  { printf '%s    $ %s%s\n' "$DIM" "$*" "$RESET"; sh -c "$*"; }
die()  { printf 'setup: %s\n' "$*" >&2; exit 1; }

ask() { # ask <prompt> <default>; answer in REPLY
    printf '%s [%s]: ' "$1" "$2"
    read -r REPLY || REPLY=''
    [ -n "$REPLY" ] || REPLY="$2"
}

ask_secret() { # ask without echoing; answer in REPLY
    printf '%s: ' "$1"
    stty -echo 2>/dev/null || true
    read -r REPLY || REPLY=''
    stty echo 2>/dev/null || true
    printf '\n'
}

confirm() { # confirm <prompt>; true when yes
    ask "$1 (y/n)" "y"
    case "$REPLY" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------ prerequisites --

step "Checking prerequisites"

IDF_DIR="${IDF_PATH:-$HOME/esp/esp-idf-v5.5}"
[ -f "$IDF_DIR/export.sh" ] || die "ESP-IDF not found at $IDF_DIR.
    Install ESP-IDF v5.5, or set IDF_PATH to where it lives:
    https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32p4/get-started/"
say "  ESP-IDF        $IDF_DIR"

command -v swift >/dev/null 2>&1 && say "  Swift          $(swift --version 2>/dev/null | head -1)" \
    || say "  Swift          not found — the macOS host will be skipped"

if [ "$(uname -s)" = "Darwin" ]; then
    if command -v brew >/dev/null 2>&1 && brew list libusb >/dev/null 2>&1; then
        say "  libusb         installed"
    else
        say "  libusb         missing — the macOS host needs it: brew install libusb"
    fi
fi

# ------------------------------------------------------------------- board ---

step "Looking for a board"

# shellcheck disable=SC2086
PORTS=$(ls /dev/cu.usbmodem* /dev/cu.usbserial* /dev/cu.wchusbserial* \
           /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true)
[ -n "$PORTS" ] || die "no serial port found.
    Connect the board's UART/serial port and try again. Note that some boards
    have two USB ports: the one that enumerates as a serial device is the one
    that flashes."

say "Serial ports:"
i=0
for p in $PORTS; do i=$((i + 1)); say "  $i) $p"; done
if [ "$i" = 1 ]; then
    PORT=$PORTS
    say "Using $PORT"
else
    ask "Which port is the board" "1"
    PORT=$(echo "$PORTS" | sed -n "${REPLY}p")
    [ -n "$PORT" ] || die "no such port"
fi

step "Identifying the chip on $PORT"
say "${DIM}    (esptool resets the board to read its chip id)${RESET}"
CHIP=$(. "$IDF_DIR/export.sh" >/dev/null 2>&1 && \
       python -m esptool --port "$PORT" chip_id 2>/dev/null \
       | sed -n 's/^Chip is \(ESP32[^ ]*\).*/\1/p' | head -1) || true

if [ -n "$CHIP" ]; then
    say "  $CHIP"
else
    say "  could not identify the chip — the port may be busy, or this may be"
    say "  the board's data port rather than its serial port."
    confirm "Continue anyway" || exit 1
fi

# Suggest the profile that matches the chip; a profile is one header in
# firmware/main/boards/.
case "$CHIP" in
    ESP32-P4)  DEFAULT_BOARD=1 ;;
    ESP32-S3)  DEFAULT_BOARD=2 ;;
    *)         DEFAULT_BOARD=3 ;;
esac

step "Choosing a board profile"
say "  1) ESP32-P4-WIFI6-Touch-LCD-3.5      ST7796 SPI, 320x480, FT6336 touch"
say "  2) Waveshare ESP32-S3-Touch-AMOLED-1.75  CO5300 QSPI, 466x466, CST9217 touch"
say "  3) Custom board                      firmware/main/boards/custom.h"
ask "Which board" "$DEFAULT_BOARD"

case "$REPLY" in
    1) BUILD_DIR=build;        SDKCONFIG=sdkconfig;        TARGET=esp32p4 ;;
    2) BUILD_DIR=build_amoled; SDKCONFIG=sdkconfig.amoled; TARGET=esp32s3 ;;
    3)
        if [ ! -f firmware/main/boards/custom.h ]; then
            say "Creating firmware/main/boards/custom.h from the template."
            run "cp firmware/main/boards/template.h firmware/main/boards/custom.h"
            say "Fill in its pin map, then run this again. It compiles unedited,"
            say "so a first build will succeed with placeholder pins."
            exit 0
        fi
        BUILD_DIR=build_custom; SDKCONFIG=sdkconfig.custom
        ask "Which chip is it (esp32p4/esp32s3)" "${CHIP:-esp32s3}"
        TARGET=$(echo "$REPLY" | tr 'A-Z-' 'a-z')
        ;;
    *) die "no such choice" ;;
esac

# -------------------------------------------------------------------- Wi-Fi --

step "Wi-Fi"
say "Off by default: the panel works over USB alone. Enabling it lets the panel"
say "be driven with no data cable, and lets a host find it by name."
DEFAULTS="sdkconfig.defaults"
if confirm "Enable Wi-Fi"; then
    ask "Network name (SSID), or blank to run the panel as its own access point" ""
    SSID=$REPLY
    PASSWORD=''
    if [ -n "$SSID" ]; then
        ask_secret "Password for $SSID"
        PASSWORD=$REPLY
    fi
    # Written to a gitignored defaults file, and compiled into the firmware.
    # Treat a board flashed this way as holding the credential.
    cat > firmware/sdkconfig.wifi.defaults <<EOF
CONFIG_GLINT_ENABLE_WIFI=y
CONFIG_GLINT_WIFI_SSID="$SSID"
CONFIG_GLINT_WIFI_PASSWORD="$PASSWORD"
EOF
    DEFAULTS="sdkconfig.defaults;sdkconfig.wifi.defaults"
    WIFI_CHANGED=1
    say "Saved to firmware/sdkconfig.wifi.defaults (gitignored)."
    [ -n "$SSID" ] || say "The panel will run its own access point, glint-XXXX."
fi

# ------------------------------------------------------------ build + flash --

step "Building firmware for $TARGET"
IDF=". $IDF_DIR/export.sh >/dev/null 2>&1"

# set-target rewrites the configuration from defaults and renames the existing
# one aside, so it runs only when there is nothing to lose. An existing config
# is edited in place instead: re-running setup must not silently discard
# settings — Wi-Fi credentials among them — that are already working.
if [ -f "firmware/$SDKCONFIG" ]; then
    say "Keeping the existing firmware/$SDKCONFIG."
    if [ -n "${WIFI_CHANGED:-}" ]; then
        say "Applying the Wi-Fi answers to it."
        python3 - "firmware/$SDKCONFIG" "$SSID" "$PASSWORD" <<'PYEOF'
import re, sys
path, ssid, password = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
wanted = {
    "CONFIG_GLINT_ENABLE_WIFI": "y",
    "CONFIG_GLINT_WIFI_SSID": '"%s"' % ssid,
    "CONFIG_GLINT_WIFI_PASSWORD": '"%s"' % password,
}
for key, value in wanted.items():
    line = "%s=%s" % (key, value)
    if re.search(r"^%s=" % key, text, re.M):
        text = re.sub(r"^%s=.*$" % key, line, text, flags=re.M)
    elif re.search(r"^# %s is not set" % key, text, re.M):
        text = re.sub(r"^# %s is not set$" % key, line, text, flags=re.M)
    else:
        text += line + "\n"
open(path, "w").write(text)
PYEOF
    fi
    run "cd firmware && $IDF && idf.py -B $BUILD_DIR -D SDKCONFIG=$SDKCONFIG build"
else
    run "cd firmware && $IDF && idf.py -B $BUILD_DIR -D SDKCONFIG=$SDKCONFIG \
  -D SDKCONFIG_DEFAULTS='$DEFAULTS' set-target $TARGET build"
fi

step "Flashing $PORT"
run "cd firmware && $IDF && idf.py -B $BUILD_DIR -D SDKCONFIG=$SDKCONFIG \
  -p $PORT -b 460800 flash"

# --------------------------------------------------------------------- host --

if command -v swift >/dev/null 2>&1 && [ "$(uname -s)" = "Darwin" ]; then
    step "Building the macOS host"
    run "cd host && swift build -c release"

    step "Looking for the panel"
    say "${DIM}    (the board reboots after flashing; give it a few seconds)${RESET}"
    sleep 5
    run "./host/.build/release/glint --list" || true

    say ""
    say "Start the display with:"
    say "  ${BOLD}make display${RESET}          USB if a cable is in, otherwise Wi-Fi"
    say "  make display-wifi     wireless only"
    say "  glint doctor          checks permissions and the private API"
    say ""
    if confirm "Start it now"; then
        run "./host/.build/release/glint display"
    fi
else
    step "Next steps"
    say "  make pi               cross-compile the Linux host"
    say "  ./glint fbinfo        framebuffer geometry, no panel needed"
    say "  ./glint fb -native    mirror the console to the panel"
fi
