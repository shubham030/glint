package render

import (
	"image"
	"testing"
)

func TestRGB565Packing(t *testing.T) {
	for _, tc := range []struct {
		r, g, b uint8
		want    uint16
	}{
		{0, 0, 0, 0x0000},
		{255, 255, 255, 0xffff},
		{255, 0, 0, 0xf800},
		{0, 255, 0, 0x07e0},
		{0, 0, 255, 0x001f},
		{8, 4, 8, 0x0821},
	} {
		if got := RGB565(tc.r, tc.g, tc.b); got != tc.want {
			t.Errorf("RGB565(%d,%d,%d) = %#04x, want %#04x", tc.r, tc.g, tc.b, got, tc.want)
		}
	}
}

func TestColorBars(t *testing.T) {
	const w, h = 320, 480
	px := ColorBars(w, h, 0)
	if len(px) != w*h {
		t.Fatalf("got %d pixels, want %d", len(px), w*h)
	}
	// 320/8 = 40-pixel bars, white first, black last.
	if px[0] != RGB565(255, 255, 255) || px[39] != RGB565(255, 255, 255) {
		t.Errorf("first bar is not white")
	}
	if px[40] != RGB565(255, 255, 0) {
		t.Errorf("second bar is not yellow")
	}
	if px[319] != RGB565(0, 0, 0) {
		t.Errorf("last bar is not black")
	}
	for y := 1; y < h; y++ {
		if px[y*w] != px[0] {
			t.Fatalf("row %d differs from row 0", y)
		}
	}
	// A phase shift of one bar width rotates the pattern.
	shifted := ColorBars(w, h, 40)
	if shifted[0] != px[40] {
		t.Errorf("phase 40 did not shift the bars")
	}
	// Negative phase must not panic or index out of range.
	if got := ColorBars(w, 1, -100); len(got) != w {
		t.Errorf("negative phase produced %d pixels", len(got))
	}
}

func TestConverterFormats(t *testing.T) {
	for _, tc := range []struct {
		name   string
		format PixelFormat
		pixel  []byte
	}{
		{"xrgb8888", PixelFormat{32, Channel{16, 8}, Channel{8, 8}, Channel{0, 8}},
			[]byte{0x00, 0x80, 0xff, 0x00}}, // b=0 g=128 r=255
		{"rgb888", PixelFormat{24, Channel{16, 8}, Channel{8, 8}, Channel{0, 8}},
			[]byte{0x00, 0x80, 0xff}},
		{"rgb565", PixelFormat{16, Channel{11, 5}, Channel{5, 6}, Channel{0, 5}},
			[]byte{0x00, 0xf8}}, // 0xf800: r=31 g=0 b=0
	} {
		c, err := NewConverter(tc.format)
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		dst := image.NewRGBA(image.Rect(0, 0, 1, 1))
		if err := c.ToRGBA(tc.pixel, len(tc.pixel), dst); err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		got := dst.Pix[:4]
		if got[0] != 0xff || got[3] != 0xff {
			t.Errorf("%s: got %v, want full red with opaque alpha", tc.name, got)
		}
		if tc.name != "rgb565" && got[1] != 0x80 {
			t.Errorf("%s: green = %#x, want 0x80", tc.name, got[1])
		}
	}
}

// A 5-bit channel at full scale must reach 255, not 248.
func TestConverterScalesNarrowChannels(t *testing.T) {
	c, err := NewConverter(PixelFormat{16, Channel{11, 5}, Channel{5, 6}, Channel{0, 5}})
	if err != nil {
		t.Fatal(err)
	}
	dst := image.NewRGBA(image.Rect(0, 0, 1, 1))
	if err := c.ToRGBA([]byte{0xff, 0xff}, 2, dst); err != nil {
		t.Fatal(err)
	}
	if got := dst.Pix[:3]; got[0] != 255 || got[1] != 255 || got[2] != 255 {
		t.Errorf("white 565 pixel expanded to %v, want 255,255,255", got)
	}
}

func TestConverterHonoursStride(t *testing.T) {
	// Two 2-pixel rows in a buffer whose stride carries 4 pixels of padding.
	f := PixelFormat{32, Channel{16, 8}, Channel{8, 8}, Channel{0, 8}}
	c, err := NewConverter(f)
	if err != nil {
		t.Fatal(err)
	}
	const stride = 16
	src := make([]byte, stride*2)
	src[2] = 0xff          // row 0, pixel 0: red
	src[stride+4+1] = 0xff // row 1, pixel 1: green
	dst := image.NewRGBA(image.Rect(0, 0, 2, 2))
	if err := c.ToRGBA(src, stride, dst); err != nil {
		t.Fatal(err)
	}
	if dst.Pix[0] != 0xff {
		t.Errorf("row 0 pixel 0 red = %#x", dst.Pix[0])
	}
	if dst.Pix[dst.Stride+4+1] != 0xff {
		t.Errorf("row 1 pixel 1 green = %#x", dst.Pix[dst.Stride+4+1])
	}
}

func TestConverterRejectsBadFormats(t *testing.T) {
	for name, f := range map[string]PixelFormat{
		"8bpp paletted":  {8, Channel{0, 8}, Channel{0, 8}, Channel{0, 8}},
		"zero channel":   {32, Channel{16, 0}, Channel{8, 8}, Channel{0, 8}},
		"channel spills": {16, Channel{11, 8}, Channel{5, 6}, Channel{0, 5}},
	} {
		if _, err := NewConverter(f); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	c, err := NewConverter(PixelFormat{32, Channel{16, 8}, Channel{8, 8}, Channel{0, 8}})
	if err != nil {
		t.Fatal(err)
	}
	dst := image.NewRGBA(image.Rect(0, 0, 4, 4))
	if err := c.ToRGBA(make([]byte, 8), 16, dst); err == nil {
		t.Error("short frame accepted")
	}
	if err := c.ToRGBA(make([]byte, 256), 8, dst); err == nil {
		t.Error("stride narrower than the frame accepted")
	}
}
