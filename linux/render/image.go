package render

import (
	"bufio"
	"fmt"
	"image"
	"image/draw"
	"os"

	// Decoders for the formats the CLI documents. EXIF orientation is not
	// applied — the standard library does not parse it.
	_ "image/jpeg"
	_ "image/png"
)

// LoadImage decodes a PNG or JPEG file into an origin-anchored RGBA image.
func LoadImage(path string) (*image.RGBA, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open image: %w", err)
	}
	defer f.Close()

	img, _, err := image.Decode(bufio.NewReader(f))
	if err != nil {
		return nil, fmt.Errorf("decode %s: %w", path, err)
	}
	return ToRGBA(img), nil
}

// ToRGBA converts any image into an *image.RGBA anchored at the origin,
// reusing the input when it already has that shape.
func ToRGBA(img image.Image) *image.RGBA {
	if r, ok := img.(*image.RGBA); ok && r.Rect.Min == (image.Point{}) {
		return r
	}
	b := img.Bounds()
	dst := image.NewRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	draw.Draw(dst, dst.Bounds(), img, b.Min, draw.Src)
	return dst
}

// RenderImage scales one image onto a fresh panel-sized RGB565 frame.
func RenderImage(img *image.RGBA, panelW, panelH int, mode FitMode, landscape bool) ([]uint16, error) {
	s, err := NewScaler(img.Rect.Dx(), img.Rect.Dy(), panelW, panelH, mode, landscape)
	if err != nil {
		return nil, err
	}
	px := make([]uint16, panelW*panelH)
	if err := s.Render(img, px); err != nil {
		return nil, err
	}
	return px, nil
}
