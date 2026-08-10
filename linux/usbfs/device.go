// Package usbfs talks to the panel through the Linux kernel's usbfs character
// devices (/dev/bus/usb/BBB/DDD), driven by raw ioctls.
//
// There is no libusb and no cgo: the module cross-compiles to armv6 for a
// Raspberry Pi Zero W with nothing but the Go toolchain. The platform code
// lives in the _linux files; everything else builds anywhere so the pure
// packages stay testable on a developer's machine.
package usbfs

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/shubham030/glint/linux/proto"
)

// Transfer failures worth distinguishing.
var (
	ErrNotFound    = errors.New("no glint device on the USB bus")
	ErrUnsupported = errors.New("usbfs transport requires Linux")
	ErrTimeout     = errors.New("transfer timed out")
)

// bmRequestType for the vendor control requests (vendor | interface).
const (
	reqTypeIn  uint8 = 0xC1
	reqTypeOut uint8 = 0x41
)

// Transfer timeouts, matching the macOS host.
const (
	ControlTimeout = 1000 * time.Millisecond
	WriteTimeout   = 2000 * time.Millisecond
	ReadTimeout    = 500 * time.Millisecond
)

// The kernel copies a usbfs bulk transfer through a single kmalloc'd bounce
// buffer, so long writes are split. 16 KiB is a multiple of every bulk max
// packet size, so no chunk boundary can end in a short packet mid-stream.
const maxBulkChunk = 16384

// deviceInfo is what the sysfs walk found out about the device.
type deviceInfo struct {
	path      string // /dev/bus/usb/BBB/DDD
	speed     string // sysfs "speed", in Mbit/s
	maxPacket int
}

// Device is a claimed glint interface.
//
// Everything a transfer needs is either immutable after Open or built on the
// caller's stack, so a reader on the bulk IN endpoint may run concurrently
// with a writer on bulk OUT — which is how the streaming modes watch for STATS
// events. Close must not race with a transfer in flight.
type Device struct {
	f         *os.File
	path      string
	speed     string
	maxPacket int
	iface     uint32
	claimed   bool
}

// Open finds the first device with the given ids and claims interface 0.
func Open(vid, pid uint16) (*Device, error) {
	// Discovery is plain filesystem reads and so is shared (and testable) on
	// every platform; the transfers underneath are Linux-only, so say that up
	// front rather than failing later with a confusing path error.
	if !transportSupported {
		return nil, ErrUnsupported
	}
	info, err := find(vid, pid)
	if err != nil {
		return nil, err
	}
	f, err := os.OpenFile(info.path, os.O_RDWR, 0)
	if err != nil {
		return nil, fmt.Errorf("open %s (no udev rule? see linux/README.md): %w", info.path, err)
	}
	d := &Device{f: f, path: info.path, speed: info.speed, maxPacket: info.maxPacket}
	if err := claimInterface(f, d.iface); err != nil {
		f.Close()
		return nil, fmt.Errorf("claim interface %d on %s: %w", d.iface, info.path, err)
	}
	d.claimed = true
	return d, nil
}

// Close releases the interface and the file descriptor.
func (d *Device) Close() error {
	if d.f == nil {
		return nil
	}
	var err error
	if d.claimed {
		err = releaseInterface(d.f, d.iface)
		d.claimed = false
	}
	if cerr := d.f.Close(); err == nil {
		err = cerr
	}
	d.f = nil
	return err
}

// Path is the usbfs node backing this device.
func (d *Device) Path() string { return d.path }

// MaxPacketSize is the bulk endpoint's wMaxPacketSize, which decides when a
// transfer needs a terminating zero-length packet.
func (d *Device) MaxPacketSize() int { return d.maxPacket }

// Speed names the negotiated USB speed ("high", "full", ...).
func (d *Device) Speed() string { return speedName(d.speed) }

// ControlRead performs a vendor IN control transfer and returns the bytes read.
func (d *Device) ControlRead(request uint8, value uint16, buf []byte) (int, error) {
	n, err := controlXfer(d.f, reqTypeIn, request, value, uint16(d.iface), buf, ControlTimeout)
	if err != nil {
		return 0, fmt.Errorf("control read %#02x: %w", request, err)
	}
	return n, nil
}

// ControlWrite performs a vendor OUT control transfer with no data stage.
func (d *Device) ControlWrite(request uint8, value uint16) error {
	if _, err := controlXfer(d.f, reqTypeOut, request, value, uint16(d.iface), nil, ControlTimeout); err != nil {
		return fmt.Errorf("control write %#02x: %w", request, err)
	}
	return nil
}

// BulkWrite sends p on the bulk OUT endpoint, splitting it into kernel-sized
// chunks and terminating it with a zero-length packet when the total is an
// exact multiple of the endpoint's max packet size.
//
// The ioctl blocks, so ctx is honoured between chunks — cancellation takes at
// most one WriteTimeout to land.
func (d *Device) BulkWrite(ctx context.Context, p []byte) error {
	for off := 0; off < len(p); {
		if err := ctx.Err(); err != nil {
			return err
		}
		end := min(off+maxBulkChunk, len(p))
		n, err := bulkXfer(d.f, proto.EndpointBulkOut, p[off:end], WriteTimeout)
		if err != nil {
			return fmt.Errorf("bulk write at %d/%d: %w", off, len(p), err)
		}
		if n <= 0 {
			return fmt.Errorf("bulk write stalled at %d/%d bytes", off, len(p))
		}
		off += n
	}
	if len(p) > 0 && d.maxPacket > 0 && len(p)%d.maxPacket == 0 {
		if _, err := bulkXfer(d.f, proto.EndpointBulkOut, nil, WriteTimeout); err != nil {
			return fmt.Errorf("bulk zero-length terminator: %w", err)
		}
	}
	return nil
}

// BulkRead reads one transfer from the bulk IN endpoint. An idle device
// returns ErrTimeout, which callers polling for events should ignore.
func (d *Device) BulkRead(ctx context.Context, p []byte) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	n, err := bulkXfer(d.f, proto.EndpointBulkIn, p, ReadTimeout)
	if err != nil {
		return 0, fmt.Errorf("bulk read: %w", err)
	}
	return n, nil
}

// speedName turns the sysfs speed attribute into the usual USB name.
func speedName(speed string) string {
	mbit, err := strconv.ParseFloat(speed, 64)
	if err != nil {
		return "unknown"
	}
	switch {
	case mbit >= 5000:
		return "super"
	case mbit >= 480:
		return "high"
	case mbit >= 12:
		return "full"
	default:
		return "low"
	}
}

// packetForSpeed is the bulk max packet size implied by a link speed, used
// when the endpoint descriptor cannot be read from sysfs.
func packetForSpeed(speed string) int {
	mbit, err := strconv.ParseFloat(speed, 64)
	if err != nil {
		return 64
	}
	switch {
	case mbit >= 5000:
		return 1024
	case mbit >= 480:
		return 512
	default:
		return 64
	}
}
