IDF_EXPORT := source $(HOME)/esp/esp-idf-v5.5/export.sh >/dev/null 2>&1
PORT ?= $(shell ls /dev/cu.usbmodem* 2>/dev/null | head -1)
GLINT := ./host/.build/release/glint

.PHONY: all fw fw-s3 host test test-host test-fw test-go flash monitor \
        display display-portrait display-wifi panels mirror bars hello stats \
        calibrate pi install-agent uninstall-agent clean

all: fw host

fw:
	cd firmware && $(IDF_EXPORT) && idf.py build

# The other supported board (Waveshare ESP32-S3-Touch-LCD-3.5), built in its own
# directory so the P4 config stays put.
fw-s3:
	cd firmware && $(IDF_EXPORT) && \
	  idf.py -B build_s3 -D SDKCONFIG=sdkconfig.s3 set-target esp32s3 build

host:
	cd host && swift build -c release

# Everything verifiable without a board attached.
test: test-host test-fw test-go

test-host:
	cd host && swift test

test-fw:
	./firmware/test/run.sh

test-go:
	cd linux && go test ./... 2>/dev/null || echo "(linux host not built yet)"

flash:
	cd firmware && $(IDF_EXPORT) && idf.py -p $(PORT) -b 460800 flash

monitor:
	cd firmware && $(IDF_EXPORT) && idf.py -p $(PORT) monitor

# Finds the panel itself: USB when a cable is in, otherwise the first panel
# answering on the network. The virtual display lives exactly as long as this
# process, and it waits, so starting it before the panel exists is fine.
display: host
	$(GLINT) display

# Panel standing upright: 640x960 desktop, exact 2:1 onto 320x480
display-portrait: host
	$(GLINT) display --portrait

# Wireless only, ignoring USB — the panel needs power and nothing else. Empty
# PANEL auto-picks; PANEL=glint-335b.local names one board.
PANEL ?=
display-wifi: host
	$(GLINT) display --net $(PANEL)

# Every panel reachable right now, on either transport.
panels: host
	@$(GLINT) --list

mirror: host
	$(GLINT) mirror --landscape

bars: host
	$(GLINT) bars --seconds 10 --fps 10

hello: host
	$(GLINT) hello

stats: host
	$(GLINT) stats

calibrate: host
	$(GLINT) touch --calibrate

# Cross-compile the Go host for both shapes of Pi. 64-bit Raspberry Pi OS (a
# Pi 3 and up) needs arm64; armv6 covers a Pi Zero W and 32-bit Pi OS anywhere.
# `uname -m` on the target says which: aarch64 or armv6l/armv7l.
pi:
	cd linux && GOOS=linux GOARCH=arm64 go build -o glint-pi-arm64 ./cmd/glint
	cd linux && GOOS=linux GOARCH=arm GOARM=6 go build -o glint-pi-armv6 ./cmd/glint
	@echo "built linux/glint-pi-arm64 and linux/glint-pi-armv6"
	@echo "scp linux/glint-pi-arm64 <user>@<pi>:~/glint   # then ./glint fbinfo"
	@echo "usbfs needs a udev rule once: packaging/70-glint.rules"

install-agent: host
	cp packaging/com.shubham.glint.plist $(HOME)/Library/LaunchAgents/
	launchctl load $(HOME)/Library/LaunchAgents/com.shubham.glint.plist
	@echo "glint will now start at login; logs in /tmp/glint.log"

uninstall-agent:
	launchctl unload $(HOME)/Library/LaunchAgents/com.shubham.glint.plist || true
	rm -f $(HOME)/Library/LaunchAgents/com.shubham.glint.plist

clean:
	cd firmware && rm -rf build
	cd host && swift package clean
