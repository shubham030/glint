package render

import (
	"image"
	"testing"
)

// gradient builds a w*h RGBA image whose pixels survive an RGB565 round trip,
// so a 1:1 render can be compared exactly.
func gradient(w, h int) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			o := y*img.Stride + x*4
			img.Pix[o] = uint8(8 * x)
			img.Pix[o+1] = uint8(4 * y)
			img.Pix[o+2] = 0
			img.Pix[o+3] = 0xff
		}
	}
	return img
}

func solid(w, h int, r, g, b uint8) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for i := 0; i < len(img.Pix); i += 4 {
		img.Pix[i], img.Pix[i+1], img.Pix[i+2], img.Pix[i+3] = r, g, b, 0xff
	}
	return img
}

func render(t *testing.T, img *image.RGBA, panelW, panelH int, mode FitMode, landscape bool) []uint16 {
	t.Helper()
	px, err := RenderImage(img, panelW, panelH, mode, landscape)
	if err != nil {
		t.Fatalf("RenderImage: %v", err)
	}
	if len(px) != panelW*panelH {
		t.Fatalf("got %d pixels, want %d", len(px), panelW*panelH)
	}
	return px
}

func TestScalerIdentity(t *testing.T) {
	const w, h = 8, 12
	img := gradient(w, h)
	px := render(t, img, w, h, Fit, false)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			want := RGB565(uint8(8*x), uint8(4*y), 0)
			if got := px[y*w+x]; got != want {
				t.Fatalf("1:1 render at %d,%d = %#04x, want %#04x", x, y, got, want)
			}
		}
	}
}

func TestScalerBoxAverageOnDownscale(t *testing.T) {
	// 4x4 source of four 2x2 quadrants; halving must average each quadrant.
	img := image.NewRGBA(image.Rect(0, 0, 4, 4))
	vals := [4][4]uint8{
		{0, 64, 128, 192},
		{64, 128, 192, 0},
		{128, 192, 0, 64},
		{192, 0, 64, 128},
	}
	for y := 0; y < 4; y++ {
		for x := 0; x < 4; x++ {
			o := y*img.Stride + x*4
			img.Pix[o], img.Pix[o+1], img.Pix[o+2], img.Pix[o+3] = vals[y][x], vals[y][x], vals[y][x], 0xff
		}
	}
	px := render(t, img, 2, 2, Fit, false)
	for i, want := range [4]uint8{(0 + 64 + 64 + 128) / 4, (128 + 192 + 192 + 0) / 4,
		(128 + 192 + 192 + 0) / 4, (0 + 64 + 64 + 128) / 4} {
		if got := px[i]; got != RGB565(want, want, want) {
			t.Errorf("pixel %d = %#04x, want %#04x (box average %d)", i, got, RGB565(want, want, want), want)
		}
	}
}

func TestScalerFitLetterboxes(t *testing.T) {
	// A 2:1 image on a square panel leaves black bands top and bottom.
	px := render(t, solid(40, 20, 255, 255, 255), 20, 20, Fit, false)
	for x := 0; x < 20; x++ {
		if px[x] != 0 {
			t.Fatalf("top row pixel %d = %#04x, want black", x, px[x])
		}
		if px[19*20+x] != 0 {
			t.Fatalf("bottom row pixel %d = %#04x, want black", x, px[19*20+x])
		}
		if got := px[10*20+x]; got != 0xffff {
			t.Fatalf("middle row pixel %d = %#04x, want white", x, got)
		}
	}
}

func TestScalerFillCrops(t *testing.T) {
	px := render(t, solid(40, 20, 255, 255, 255), 20, 20, Fill, false)
	for i, v := range px {
		if v != 0xffff {
			t.Fatalf("fill left pixel %d black at %d", v, i)
		}
	}
}

// Landscape composes on a panelH x panelW canvas and rotates it into the
// portrait framebuffer; the mapping matches the macOS host's --landscape.
func TestScalerLandscapeMapping(t *testing.T) {
	const panelW, panelH = 4, 6
	img := gradient(panelH, panelW) // exactly the landscape composition space
	px := render(t, img, panelW, panelH, Fit, true)
	for iy := 0; iy < panelW; iy++ {
		for ix := 0; ix < panelH; ix++ {
			want := RGB565(uint8(8*ix), uint8(4*iy), 0)
			if got := px[(panelH-1-ix)*panelW+iy]; got != want {
				t.Fatalf("landscape source %d,%d landed wrong: %#04x != %#04x", ix, iy, got, want)
			}
		}
	}
}

func TestScalerUpscaleFillsPanel(t *testing.T) {
	px := render(t, solid(2, 3, 0, 255, 0), 20, 30, Fit, false)
	for i, v := range px {
		if v != RGB565(0, 255, 0) {
			t.Fatalf("upscaled pixel %d = %#04x", i, v)
		}
	}
}

func TestScalerRejectsMismatchedSource(t *testing.T) {
	s, err := NewScaler(10, 10, 8, 8, Fit, false)
	if err != nil {
		t.Fatal(err)
	}
	dst := make([]uint16, 64)
	if err := s.Render(gradient(9, 10), dst); err == nil {
		t.Error("source of the wrong size accepted")
	}
	if err := s.Render(gradient(10, 10), dst[:10]); err == nil {
		t.Error("undersized destination accepted")
	}
	off := image.NewRGBA(image.Rect(2, 2, 12, 12))
	if err := s.Render(off, dst); err == nil {
		t.Error("source with a non-zero origin accepted")
	}
	if _, err := NewScaler(0, 10, 8, 8, Fit, false); err == nil {
		t.Error("zero-width source accepted")
	}
}
