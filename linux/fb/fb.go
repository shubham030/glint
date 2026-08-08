// Package fb reads a Linux framebuffer device so the panel can mirror a
// console with no X server running — the Raspberry Pi deployment path.
//
// The ioctl code is Linux-only; the geometry types are not, so the rest of the
// program compiles and tests anywhere.
package fb

import (
	"errors"
	"fmt"

	"github.com/shubham030/glint/linux/render"
)

// ErrUnsupported is returned when the framebuffer is opened on a non-Linux
// host, where FBIOGET_VSCREENINFO does not exist.
var ErrUnsupported = errors.New("framebuffer access requires Linux")

// DefaultDevice is the console framebuffer on a stock Raspberry Pi OS image.
const DefaultDevice = "/dev/fb0"

// Info describes the framebuffer's current mode.
type Info struct {
	Width  int
	Height int
	Stride int // bytes per row, which can exceed Width*bpp/8
	Format render.PixelFormat
}

func (i Info) String() string {
	return fmt.Sprintf("%dx%d, %s, stride %d", i.Width, i.Height, i.Format, i.Stride)
}

// Validate rejects modes the converter cannot read.
func (i Info) Validate() error {
	if i.Width <= 0 || i.Height <= 0 {
		return fmt.Errorf("framebuffer reports %dx%d", i.Width, i.Height)
	}
	if err := i.Format.Validate(); err != nil {
		return err
	}
	if need := i.Width * i.Format.BitsPerPixel / 8; i.Stride < need {
		return fmt.Errorf("stride %d is shorter than a %d-pixel row (%d bytes)", i.Stride, i.Width, need)
	}
	return nil
}
