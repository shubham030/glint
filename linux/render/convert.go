package render

import (
	"fmt"
	"image"
)

// Channel locates one colour channel inside a packed framebuffer pixel,
// matching Linux's struct fb_bitfield.
type Channel struct {
	Offset uint32
	Length uint32
}

// PixelFormat describes a packed truecolour pixel: how wide it is and where
// each channel sits inside it.
type PixelFormat struct {
	BitsPerPixel int
	R, G, B      Channel
}

func (f PixelFormat) String() string {
	return fmt.Sprintf("%dbpp r%d/%d g%d/%d b%d/%d", f.BitsPerPixel,
		f.R.Length, f.R.Offset, f.G.Length, f.G.Offset, f.B.Length, f.B.Offset)
}

// Validate reports whether the format is one Converter can handle.
func (f PixelFormat) Validate() error {
	switch f.BitsPerPixel {
	case 16, 24, 32:
	default:
		return fmt.Errorf("unsupported %d bits per pixel (want 16, 24 or 32)", f.BitsPerPixel)
	}
	for _, c := range []struct {
		name string
		ch   Channel
	}{{"red", f.R}, {"green", f.G}, {"blue", f.B}} {
		if c.ch.Length == 0 || c.ch.Length > 16 {
			return fmt.Errorf("%s channel is %d bits wide", c.name, c.ch.Length)
		}
		if int(c.ch.Offset+c.ch.Length) > f.BitsPerPixel {
			return fmt.Errorf("%s channel at bit %d..%d overflows a %d-bit pixel",
				c.name, c.ch.Offset, c.ch.Offset+c.ch.Length, f.BitsPerPixel)
		}
	}
	return nil
}

// Converter expands packed framebuffer pixels into 8-bit RGBA.
type Converter struct {
	format     PixelFormat
	pixelBytes int
	r, g, b    []uint8
}

// NewConverter precomputes the per-channel scaling tables.
func NewConverter(f PixelFormat) (*Converter, error) {
	if err := f.Validate(); err != nil {
		return nil, fmt.Errorf("pixel format: %w", err)
	}
	return &Converter{
		format:     f,
		pixelBytes: f.BitsPerPixel / 8,
		r:          channelLUT(f.R),
		g:          channelLUT(f.G),
		b:          channelLUT(f.B),
	}, nil
}

// Format returns the format the converter was built for.
func (c *Converter) Format() PixelFormat { return c.format }

// ToRGBA expands one frame. src is srcStride bytes per row; dst's bounds give
// the frame size.
func (c *Converter) ToRGBA(src []byte, srcStride int, dst *image.RGBA) error {
	w, h := dst.Rect.Dx(), dst.Rect.Dy()
	if srcStride < w*c.pixelBytes {
		return fmt.Errorf("stride %d holds fewer than %d pixels", srcStride, w)
	}
	if need := (h-1)*srcStride + w*c.pixelBytes; len(src) < need {
		return fmt.Errorf("frame is %d bytes, need %d for %dx%d", len(src), need, w, h)
	}
	for y := 0; y < h; y++ {
		row := src[y*srcStride:]
		out := dst.Pix[y*dst.Stride:]
		for x := 0; x < w; x++ {
			v := c.word(row[x*c.pixelBytes:])
			o := x * 4
			out[o] = c.r[(v>>c.format.R.Offset)&mask(c.format.R.Length)]
			out[o+1] = c.g[(v>>c.format.G.Offset)&mask(c.format.G.Length)]
			out[o+2] = c.b[(v>>c.format.B.Offset)&mask(c.format.B.Length)]
			out[o+3] = 0xff
		}
	}
	return nil
}

// word reads one little-endian packed pixel.
func (c *Converter) word(p []byte) uint32 {
	switch c.pixelBytes {
	case 2:
		return uint32(p[0]) | uint32(p[1])<<8
	case 3:
		return uint32(p[0]) | uint32(p[1])<<8 | uint32(p[2])<<16
	default:
		return uint32(p[0]) | uint32(p[1])<<8 | uint32(p[2])<<16 | uint32(p[3])<<24
	}
}

func mask(length uint32) uint32 { return 1<<length - 1 }

// channelLUT maps every raw channel value onto the full 0..255 range, so a
// 5-bit 0x1f becomes 0xff rather than 0xf8.
func channelLUT(c Channel) []uint8 {
	n := 1 << c.Length
	t := make([]uint8, n)
	for i := range t {
		t[i] = uint8(i * 255 / (n - 1))
	}
	return t
}
