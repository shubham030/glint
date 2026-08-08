package render

import (
	"fmt"
	"image"
	"math"
)

// FitMode decides how a source image is placed on the panel.
type FitMode int

// Placement modes.
const (
	Fit  FitMode = iota // letterbox onto black
	Fill                // cover the panel, cropping the overflow
)

// span is the half-open source range one destination pixel averages. An empty
// span (hi <= lo) means the destination pixel is letterbox, not image.
type span struct{ lo, hi int }

func (s span) empty() bool { return s.hi <= s.lo }

// Scaler resamples a fixed source size onto the panel with a box filter,
// degenerating to nearest-neighbour where the image is magnified. The per-axis
// sample ranges are computed once so streaming a framebuffer only pays for the
// sampling itself.
type Scaler struct {
	srcW, srcH     int
	panelW, panelH int
	spaceW, spaceH int
	landscape      bool
	xs, ys         []span
}

// NewScaler plans the mapping from a srcW x srcH image onto a panelW x panelH
// panel. When landscape is set the content is composed for a panelH x panelW
// canvas and rotated into the portrait framebuffer, matching the macOS host's
// --landscape.
func NewScaler(srcW, srcH, panelW, panelH int, mode FitMode, landscape bool) (*Scaler, error) {
	if srcW <= 0 || srcH <= 0 || panelW <= 0 || panelH <= 0 {
		return nil, fmt.Errorf("scaler: %dx%d source onto %dx%d panel", srcW, srcH, panelW, panelH)
	}
	s := &Scaler{
		srcW: srcW, srcH: srcH,
		panelW: panelW, panelH: panelH,
		spaceW: panelW, spaceH: panelH,
		landscape: landscape,
	}
	if landscape {
		s.spaceW, s.spaceH = panelH, panelW
	}
	sx := float64(s.spaceW) / float64(srcW)
	sy := float64(s.spaceH) / float64(srcH)
	scale := math.Min(sx, sy)
	if mode == Fill {
		scale = math.Max(sx, sy)
	}
	s.xs = plan(s.spaceW, srcW, (float64(s.spaceW)-float64(srcW)*scale)/2, scale)
	s.ys = plan(s.spaceH, srcH, (float64(s.spaceH)-float64(srcH)*scale)/2, scale)
	return s, nil
}

// Size reports the source geometry the scaler was planned for.
func (s *Scaler) Size() (w, h int) { return s.srcW, s.srcH }

// plan maps each destination position onto the source pixels it averages.
func plan(n, srcN int, off, scale float64) []span {
	out := make([]span, n)
	for i := range out {
		if c := (float64(i) + 0.5 - off) / scale; c < 0 || c >= float64(srcN) {
			continue // outside the drawn image: letterbox
		}
		lo := int(math.Floor((float64(i) - off) / scale))
		hi := int(math.Ceil((float64(i+1) - off) / scale))
		if hi <= lo {
			hi = lo + 1
		}
		out[i] = span{lo: max(lo, 0), hi: min(hi, srcN)}
	}
	return out
}

// Render resamples src into dst, which holds panelW*panelH RGB565 pixels.
func (s *Scaler) Render(src *image.RGBA, dst []uint16) error {
	if src.Rect.Min != (image.Point{}) {
		return fmt.Errorf("scaler: source origin %v, want 0,0", src.Rect.Min)
	}
	if src.Rect.Dx() != s.srcW || src.Rect.Dy() != s.srcH {
		return fmt.Errorf("scaler: source is %dx%d, planned for %dx%d",
			src.Rect.Dx(), src.Rect.Dy(), s.srcW, s.srcH)
	}
	if n := s.panelW * s.panelH; len(dst) < n {
		return fmt.Errorf("scaler: destination holds %d pixels, need %d", len(dst), n)
	}
	for iy := 0; iy < s.spaceH; iy++ {
		ys := s.ys[iy]
		for ix := 0; ix < s.spaceW; ix++ {
			var v uint16 // black letterbox
			if xs := s.xs[ix]; !xs.empty() && !ys.empty() {
				v = boxSample(src, xs, ys)
			}
			dst[s.index(ix, iy)] = v
		}
	}
	return nil
}

// index maps a position in composition space onto the panel framebuffer.
func (s *Scaler) index(ix, iy int) int {
	if s.landscape {
		return (s.panelH-1-ix)*s.panelW + iy
	}
	return iy*s.panelW + ix
}

// boxSample averages the source rectangle covering one destination pixel.
func boxSample(src *image.RGBA, xs, ys span) uint16 {
	var r, g, b, n uint32
	for y := ys.lo; y < ys.hi; y++ {
		row := src.Pix[y*src.Stride:]
		for x := xs.lo; x < xs.hi; x++ {
			o := x * 4
			r += uint32(row[o])
			g += uint32(row[o+1])
			b += uint32(row[o+2])
			n++
		}
	}
	return RGB565(uint8(r/n), uint8(g/n), uint8(b/n))
}
