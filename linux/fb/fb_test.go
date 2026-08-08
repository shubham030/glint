package fb

import (
	"testing"

	"github.com/shubham030/glint/linux/render"
)

func TestInfoValidate(t *testing.T) {
	rgb565 := render.PixelFormat{
		BitsPerPixel: 16,
		R:            render.Channel{Offset: 11, Length: 5},
		G:            render.Channel{Offset: 5, Length: 6},
		B:            render.Channel{Offset: 0, Length: 5},
	}
	good := Info{Width: 640, Height: 480, Stride: 1280, Format: rgb565}
	if err := good.Validate(); err != nil {
		t.Errorf("a stock 16bpp console mode was rejected: %v", err)
	}
	// Padded stride is normal on the Pi and must be accepted.
	padded := good
	padded.Stride = 1536
	if err := padded.Validate(); err != nil {
		t.Errorf("padded stride rejected: %v", err)
	}

	for name, info := range map[string]Info{
		"no geometry":  {Width: 0, Height: 480, Stride: 1280, Format: rgb565},
		"short stride": {Width: 640, Height: 480, Stride: 640, Format: rgb565},
		"paletted": {Width: 640, Height: 480, Stride: 640, Format: render.PixelFormat{
			BitsPerPixel: 8,
			R:            render.Channel{Offset: 0, Length: 8},
			G:            render.Channel{Offset: 0, Length: 8},
			B:            render.Channel{Offset: 0, Length: 8},
		}},
	} {
		if err := info.Validate(); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}
