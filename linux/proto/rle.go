package proto

import "fmt"

// RGB565_RLE (fmt 1). A stream of runs, each introduced by a little-endian
// 16-bit count word:
//
//	bit15 clear — RUN: low 15 bits are a pixel count, followed by one
//	              little-endian RGB565 pixel repeated that many times.
//	bit15 set   — LITERAL: low 15 bits are a pixel count, followed by exactly
//	              that many little-endian RGB565 pixels.
//
// The decoded pixel count must equal the tile's w*h. Matches
// firmware/main/rle.c byte for byte.
const (
	rleLiteralFlag uint16 = 0x8000
	rleCountMask   uint16 = 0x7FFF
	rleMaxCount           = int(rleCountMask)

	// Runs shorter than this cost more as a RUN word (4 bytes for <=2 pixels)
	// than as literal pixels, so they stay in the literal accumulator.
	rleMinRun = 3
)

// MaxRLELen is the largest stream AppendRLE can produce for n pixels: every
// pixel literal, plus one count word per 32767-pixel chunk.
func MaxRLELen(n int) int {
	if n <= 0 {
		return 0
	}
	return n*2 + 2*((n+rleMaxCount-1)/rleMaxCount)
}

// AppendRLE encodes px and appends the stream to dst.
func AppendRLE(dst []byte, px []uint16) []byte {
	for i := 0; i < len(px); {
		if run := runLen(px, i); run >= rleMinRun {
			dst = append16(dst, uint16(run))
			dst = append16(dst, px[i])
			i += run
			continue
		}
		n := literalLen(px, i)
		dst = append16(dst, uint16(n)|rleLiteralFlag)
		for _, v := range px[i : i+n] {
			dst = append16(dst, v)
		}
		i += n
	}
	return dst
}

// runLen counts identical pixels starting at i, capped at the count field.
func runLen(px []uint16, i int) int {
	v := px[i]
	n := 1
	for i+n < len(px) && n < rleMaxCount && px[i+n] == v {
		n++
	}
	return n
}

// literalLen counts pixels from i that belong in one literal: it stops before
// the next encodable run, at the count cap, or at the end of the tile.
func literalLen(px []uint16, i int) int {
	n := 0
	for i+n < len(px) && n < rleMaxCount {
		if runLen(px, i+n) >= rleMinRun {
			break
		}
		n++
	}
	return n
}

// DecodeRLE expands a stream that must decode to exactly npix pixels. It
// exists to verify AppendRLE against the firmware's decoder contract; the host
// never decodes on the hot path.
func DecodeRLE(src []byte, npix int) ([]uint16, error) {
	out := make([]uint16, 0, npix)
	for i := 0; i+1 < len(src); {
		word := le16(src, i)
		i += 2
		n := int(word & rleCountMask)
		if n == 0 {
			return nil, fmt.Errorf("rle: zero count at byte %d: %w", i-2, ErrMalformed)
		}
		if len(out)+n > npix {
			return nil, fmt.Errorf("rle: %d pixels overruns %d: %w", len(out)+n, npix, ErrMalformed)
		}
		if word&rleLiteralFlag != 0 {
			if i+2*n > len(src) {
				return nil, fmt.Errorf("rle: literal of %d needs %d bytes, %d left: %w", n, 2*n, len(src)-i, ErrShort)
			}
			for k := 0; k < n; k++ {
				out = append(out, le16(src, i+2*k))
			}
			i += 2 * n
			continue
		}
		if i+2 > len(src) {
			return nil, fmt.Errorf("rle: run of %d missing its pixel: %w", n, ErrShort)
		}
		v := le16(src, i)
		i += 2
		for k := 0; k < n; k++ {
			out = append(out, v)
		}
	}
	if len(out) != npix {
		return nil, fmt.Errorf("rle: decoded %d pixels, want %d: %w", len(out), npix, ErrMalformed)
	}
	return out, nil
}
