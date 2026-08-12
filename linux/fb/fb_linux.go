//go:build linux

package fb

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"

	"github.com/shubham030/glint/linux/render"
)

// Framebuffer ioctls; unlike usbfs these are plain numbers, not _IOC-encoded.
const (
	fbioGetVScreenInfo = 0x4600
	fbioPutVScreenInfo = 0x4601
	fbioGetFScreenInfo = 0x4602
)

// Visuals the converter understands. Paletted modes would need the colour map.
const (
	visualTrueColor   = 2
	visualDirectColor = 4
)

// struct fb_bitfield.
type bitfield struct {
	offset   uint32
	length   uint32
	msbRight uint32
}

// struct fb_var_screeninfo — every field is a u32, so the layout is the same
// on armv6 and amd64.
type varScreenInfo struct {
	xres, yres                uint32
	xresVirtual, yresVirtual  uint32
	xoffset, yoffset          uint32
	bitsPerPixel, grayscale   uint32
	red, green, blue, transp  bitfield
	nonstd, activate          uint32
	height, width, accelFlags uint32
	pixclock                  uint32
	leftMargin, rightMargin   uint32
	upperMargin, lowerMargin  uint32
	hsyncLen, vsyncLen        uint32
	sync, vmode, rotate       uint32
	colorspace                uint32
	reserved                  [4]uint32
}

// struct fb_fix_screeninfo. smem_start and mmio_start are unsigned long, hence
// uintptr rather than a fixed width.
type fixScreenInfo struct {
	id                            [16]byte
	smemStart                     uintptr
	smemLen                       uint32
	fbType, typeAux, visual       uint32
	xpanstep, ypanstep, ywrapstep uint16
	lineLength                    uint32
	mmioStart                     uintptr
	mmioLen, accel                uint32
	capabilities                  uint16
	reserved                      [2]uint16
}

// Device is an open framebuffer being read frame by frame.
type Device struct {
	f    *os.File
	info Info
	buf  []byte
}

// Open reads the framebuffer's mode and prepares a frame buffer for it.
func Open(path string) (*Device, error) {
	f, err := os.OpenFile(path, os.O_RDONLY, 0)
	if err != nil {
		return nil, fmt.Errorf("open framebuffer: %w", err)
	}
	d := &Device{f: f}
	info, _, err := d.mode()
	if err != nil {
		f.Close()
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if err := info.Validate(); err != nil {
		f.Close()
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	d.info = info
	d.buf = make([]byte, info.Height*info.Stride)
	return d, nil
}

// Info reports the mode captured at Open.
func (d *Device) Info() Info { return d.info }

// Close releases the device.
func (d *Device) Close() error {
	if d.f == nil {
		return nil
	}
	err := d.f.Close()
	d.f = nil
	return err
}

// Frame reads the visible area into an internal buffer and returns it. The
// slice stays valid until the next call. The variable info is re-read every
// frame so panning (yoffset) is followed and a mode change is reported rather
// than silently producing garbage.
func (d *Device) Frame() ([]byte, error) {
	info, offset, err := d.mode()
	if err != nil {
		return nil, err
	}
	if info != d.info {
		return nil, fmt.Errorf("framebuffer mode changed: %s -> %s", d.info, info)
	}
	if err := readFull(d.f, d.buf, int64(offset)); err != nil {
		return nil, fmt.Errorf("read framebuffer: %w", err)
	}
	return d.buf, nil
}

// mode queries the current geometry and the byte offset of the visible frame.
func (d *Device) mode() (Info, int, error) {
	var v varScreenInfo
	if err := ioctl(d.f, fbioGetVScreenInfo, unsafe.Pointer(&v)); err != nil {
		return Info{}, 0, fmt.Errorf("FBIOGET_VSCREENINFO: %w", err)
	}
	var fx fixScreenInfo
	if err := ioctl(d.f, fbioGetFScreenInfo, unsafe.Pointer(&fx)); err != nil {
		return Info{}, 0, fmt.Errorf("FBIOGET_FSCREENINFO: %w", err)
	}
	if fx.visual != visualTrueColor && fx.visual != visualDirectColor {
		return Info{}, 0, fmt.Errorf("framebuffer visual %d is not truecolour", fx.visual)
	}
	info := Info{
		Width:  int(v.xres),
		Height: int(v.yres),
		Stride: int(fx.lineLength),
		Format: render.PixelFormat{
			BitsPerPixel: int(v.bitsPerPixel),
			R:            render.Channel{Offset: v.red.offset, Length: v.red.length},
			G:            render.Channel{Offset: v.green.offset, Length: v.green.length},
			B:            render.Channel{Offset: v.blue.offset, Length: v.blue.length},
		},
	}
	offset := int(v.yoffset)*info.Stride + int(v.xoffset)*int(v.bitsPerPixel)/8
	return info, offset, nil
}

func ioctl(f *os.File, request uintptr, arg unsafe.Pointer) error {
	for {
		_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), request, uintptr(arg))
		switch errno {
		case 0:
			return nil
		case syscall.EINTR:
			continue
		default:
			return errno
		}
	}
}

// readFull pulls exactly len(buf) bytes starting at off. Framebuffer reads can
// come back short at the end of a page.
func readFull(f *os.File, buf []byte, off int64) error {
	for done := 0; done < len(buf); {
		n, err := f.ReadAt(buf[done:], off+int64(done))
		done += n
		if err != nil {
			if done == len(buf) {
				return nil // a short final read that still filled the buffer
			}
			return err
		}
		if n == 0 {
			return fmt.Errorf("read stalled at %d/%d bytes", done, len(buf))
		}
	}
	return nil
}

// Resize asks for a visible area of w x h and returns a function restoring the
// previous geometry. The panel is small and fixed, so matching the framebuffer
// to it means the console renders at its final size — no downscale, no blurred
// glyphs. `fbset -g` does the same thing; doing it here keeps the 1:1 mode from
// depending on a boot-time command that a reboot would lose.
//
// The virtual resolution is left to the driver: KMS fbdev emulation on a Pi
// keeps its own backing size and stride, which the reader already handles.
func (d *Device) Resize(w, h int) (func() error, error) {
	var before varScreenInfo
	if err := ioctl(d.f, fbioGetVScreenInfo, unsafe.Pointer(&before)); err != nil {
		return nil, fmt.Errorf("FBIOGET_VSCREENINFO: %w", err)
	}
	if int(before.xres) == w && int(before.yres) == h {
		return func() error { return nil }, nil
	}

	want := before
	want.xres, want.yres = uint32(w), uint32(h)
	want.activate = 0 // FB_ACTIVATE_NOW
	if err := ioctl(d.f, fbioPutVScreenInfo, unsafe.Pointer(&want)); err != nil {
		return nil, fmt.Errorf("FBIOPUT_VSCREENINFO %dx%d: %w", w, h, err)
	}

	info, _, err := d.mode()
	if err != nil {
		return nil, err
	}
	if err := info.Validate(); err != nil {
		return nil, err
	}
	d.info = info
	d.buf = make([]byte, info.Height*info.Stride)

	restore := func() error {
		prev := before
		prev.activate = 0
		return ioctl(d.f, fbioPutVScreenInfo, unsafe.Pointer(&prev))
	}
	return restore, nil
}
