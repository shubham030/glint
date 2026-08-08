package proto

import (
	"context"
	"fmt"
)

// DefaultTileSize is the grid pitch shared with the macOS host (README §5.2).
const DefaultTileSize = 64

// Conn is the transport a TileSender writes packets to.
type Conn interface {
	BulkWrite(ctx context.Context, p []byte) error
}

// Stats reports what one Send put on the wire.
type Stats struct {
	Bytes   int
	Tiles   int
	Packets int
}

// Options tunes the tiler. The zero value gives a 64-pixel grid and uses RLE
// whenever the device advertises fmt 1.
type Options struct {
	TileSize   int
	DisableRLE bool
}

type run struct{ x, y, w, h int }

// TileSender splits a frame into a tile grid, hashes every tile and sends only
// the ones whose contents changed, coalescing horizontally adjacent dirty
// tiles into one packet. It mirrors host/Sources/GlintCore/Tiles.swift so both
// hosts drive the firmware identically.
//
// A TileSender is stateful and not safe for concurrent use.
type TileSender struct {
	panelW, panelH int
	tileW, tileH   int
	cols, rows     int
	rle            bool

	hashes  []uint64
	runs    []run
	payload []uint16
	packet  []byte
	rleBuf  []byte

	seq    uint16
	primed bool
}

// NewTileSender sizes the grid from the device's own geometry.
func NewTileSender(h Hello, o Options) (*TileSender, error) {
	size := o.TileSize
	if size <= 0 {
		size = DefaultTileSize
	}
	if h.PanelW <= 0 || h.PanelH <= 0 {
		return nil, fmt.Errorf("tiler: panel %dx%d: %w", h.PanelW, h.PanelH, ErrMalformed)
	}
	// A coalesced run spans at most the full panel width, so the payload cap
	// dictates how many rows one packet can carry.
	rows := h.MaxTileLen / (h.PanelW * 2)
	if rows < 1 {
		return nil, fmt.Errorf("tiler: max_tile_len %d holds less than one %d-pixel row", h.MaxTileLen, h.PanelW)
	}
	s := &TileSender{
		panelW: h.PanelW, panelH: h.PanelH,
		tileW: size, tileH: min(size, rows),
		rle: !o.DisableRLE && h.Supports(FmtRGB565RLE),
	}
	s.cols = (s.panelW + s.tileW - 1) / s.tileW
	s.rows = (s.panelH + s.tileH - 1) / s.tileH
	s.hashes = make([]uint64, s.cols*s.rows)
	maxPixels := s.panelW * s.tileH
	s.payload = make([]uint16, maxPixels)
	s.packet = make([]byte, 0, TileHeaderSize+maxPixels*2)
	if s.rle {
		s.rleBuf = make([]byte, 0, MaxRLELen(maxPixels))
	}
	return s, nil
}

// Grid describes the tiling for the startup banner.
func (s *TileSender) Grid() string {
	codec := "raw"
	if s.rle {
		codec = "rle"
	}
	return fmt.Sprintf("%dx%d tiles of %dx%d, %s", s.cols, s.rows, s.tileW, s.tileH, codec)
}

// Invalidate forces the next Send to be a full refresh.
func (s *TileSender) Invalidate() { s.primed = false }

// Send transmits the tiles of px that differ from the previous frame. px is
// panelW*panelH RGB565 pixels in row-major order.
func (s *TileSender) Send(ctx context.Context, c Conn, px []uint16, forceFull bool) (Stats, error) {
	var st Stats
	if n := s.panelW * s.panelH; len(px) < n {
		return st, fmt.Errorf("frame: have %d pixels, want %d: %w", len(px), n, ErrShort)
	}
	full := forceFull || !s.primed
	s.runs = s.runs[:0]
	st.Tiles = s.markDirty(px, full)
	st.Packets = len(s.runs)

	for i := range s.runs {
		if err := ctx.Err(); err != nil {
			return st, err
		}
		flags := uint16(0)
		if full {
			flags |= FlagFullRefresh
		}
		if i == len(s.runs)-1 {
			flags |= FlagLastInFrame
		}
		n, err := s.sendRun(ctx, c, s.runs[i], px, flags)
		st.Bytes += n
		if err != nil {
			return st, err
		}
	}

	if len(s.runs) > 0 {
		s.seq++
	}
	s.primed = true
	return st, nil
}

// markDirty rehashes every tile, records the coalesced dirty runs and returns
// the number of tiles they cover.
func (s *TileSender) markDirty(px []uint16, full bool) int {
	tiles := 0
	for r := 0; r < s.rows; r++ {
		y := r * s.tileH
		h := min(s.tileH, s.panelH-y)
		runStart := -1
		// One past the last column so a trailing run gets flushed.
		for c := 0; c <= s.cols; c++ {
			dirty := false
			if c < s.cols {
				x := c * s.tileW
				hv := s.hash(px, x, y, min(s.tileW, s.panelW-x), h)
				idx := r*s.cols + c
				dirty = full || s.hashes[idx] != hv
				if dirty {
					s.hashes[idx] = hv
				}
			}
			switch {
			case dirty && runStart < 0:
				runStart = c
			case !dirty && runStart >= 0:
				x := runStart * s.tileW
				s.runs = append(s.runs, run{x, y, min(s.panelW-x, (c-runStart)*s.tileW), h})
				tiles += c - runStart
				runStart = -1
			}
		}
	}
	return tiles
}

// sendRun writes one coalesced run and returns the bytes handed to the
// transport.
func (s *TileSender) sendRun(ctx context.Context, c Conn, r run, px []uint16, flags uint16) (int, error) {
	pix := s.pixels(r, px)
	format, body := FmtRGB565, []byte(nil)
	if s.rle {
		// Only worth it when it actually shrinks the payload — a photo tile
		// encodes larger than raw.
		if enc := AppendRLE(s.rleBuf[:0], pix); len(enc) < len(pix)*2 {
			s.rleBuf, format, body = enc, FmtRGB565RLE, enc
		}
	}
	payloadLen := len(pix) * 2
	if body != nil {
		payloadLen = len(body)
	}

	buf := TileHeader{
		Seq: s.seq, Flags: flags,
		X: uint16(r.x), Y: uint16(r.y), W: uint16(r.w), H: uint16(r.h),
		Fmt: format, PayloadLen: uint32(payloadLen),
	}.AppendTo(s.packet[:0])
	if body != nil {
		buf = append(buf, body...)
	} else {
		buf = appendPixels(buf, pix)
	}
	s.packet = buf

	if err := c.BulkWrite(ctx, buf); err != nil {
		return 0, fmt.Errorf("send tile %d,%d %dx%d: %w", r.x, r.y, r.w, r.h, err)
	}
	return len(buf), nil
}

// pixels returns the run's pixels, copying only when the run is narrower than
// the panel (a full-width run is already contiguous).
func (s *TileSender) pixels(r run, px []uint16) []uint16 {
	if r.x == 0 && r.w == s.panelW {
		start := r.y * s.panelW
		return px[start : start+r.w*r.h]
	}
	dst := s.payload[:r.w*r.h]
	for row := 0; row < r.h; row++ {
		src := (r.y+row)*s.panelW + r.x
		copy(dst[row*r.w:(row+1)*r.w], px[src:src+r.w])
	}
	return dst
}

// hash is FNV-1a over the tile's RGB565 pixels.
func (s *TileSender) hash(px []uint16, x, y, w, h int) uint64 {
	hv := uint64(0xcbf29ce484222325)
	for row := y; row < y+h; row++ {
		base := row*s.panelW + x
		for _, v := range px[base : base+w] {
			hv = (hv ^ uint64(v)) * 0x100000001b3
		}
	}
	return hv
}

// appendPixels writes px little-endian, reusing dst's capacity.
func appendPixels(dst []byte, px []uint16) []byte {
	n := len(dst)
	need := n + 2*len(px)
	if cap(dst) < need {
		grown := make([]byte, need)
		copy(grown, dst)
		dst = grown
	} else {
		dst = dst[:need]
	}
	b := dst[n:]
	for i, v := range px {
		b[2*i] = byte(v)
		b[2*i+1] = byte(v >> 8)
	}
	return dst
}
