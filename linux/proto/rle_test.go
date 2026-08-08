package proto

import (
	"errors"
	"math/rand"
	"testing"
)

func TestRLERoundTrip(t *testing.T) {
	cases := map[string][]uint16{
		"single":           {0x1234},
		"pair":             {0x1234, 0x1234},
		"exactly-three":    {7, 7, 7},
		"two-then-run":     {1, 2, 3, 3, 3, 3, 9},
		"all-identical":    flat(0xf81f, 5000),
		"alternating":      alternating(4096),
		"run-cap-boundary": flat(0x07e0, rleMaxCount),
		"over-run-cap":     flat(0x07e0, rleMaxCount+10),
		"literal-cap":      randomPixels(rleMaxCount + 5),
		"trailing-literal": append(flat(3, 100), 1, 2),
		"empty":            {},
	}
	for name, px := range cases {
		enc := AppendRLE(nil, px)
		if len(enc) > MaxRLELen(len(px)) {
			t.Errorf("%s: %d bytes exceeds MaxRLELen %d", name, len(enc), MaxRLELen(len(px)))
		}
		got, err := DecodeRLE(enc, len(px))
		if err != nil {
			t.Errorf("%s: decode: %v", name, err)
			continue
		}
		if !equalPixels(got, px) {
			t.Errorf("%s: round trip mismatch (%d pixels)", name, len(px))
		}
	}
}

func TestRLECompressesFlatTiles(t *testing.T) {
	px := flat(0x001f, 64*64)
	enc := AppendRLE(nil, px)
	// 4096 pixels = one 32767-capped run: two count words worth of bytes.
	if len(enc) != 4 {
		t.Errorf("flat 64x64 tile encoded to %d bytes, want 4", len(enc))
	}
}

func TestRLENeverBloatsMuch(t *testing.T) {
	// Photographic content is the worst case: 2 bytes of overhead per 32767
	// pixels. The tiler only sends RLE when it is actually smaller, but the
	// encoder must stay bounded regardless.
	px := randomPixels(70000)
	enc := AppendRLE(nil, px)
	if over := len(enc) - len(px)*2; over > 8 {
		t.Errorf("random pixels grew by %d bytes, want <= 8", over)
	}
}

// Pins the exact bytes the firmware decoder in firmware/main/rle.c expects.
func TestRLEWireLayout(t *testing.T) {
	px := []uint16{0x1234, 0x5678, 0xabcd, 0xabcd, 0xabcd, 0xabcd}
	want := []byte{
		0x02, 0x80, // literal, 2 pixels
		0x34, 0x12,
		0x78, 0x56,
		0x04, 0x00, // run, 4 pixels
		0xcd, 0xab,
	}
	if got := AppendRLE(nil, px); string(got) != string(want) {
		t.Errorf("\n got %x\nwant %x", got, want)
	}
}

func TestDecodeRLERejects(t *testing.T) {
	for name, tc := range map[string]struct {
		src  []byte
		npix int
	}{
		"zero count":       {[]byte{0x00, 0x00, 0x11, 0x22}, 1},
		"run missing px":   {[]byte{0x04, 0x00}, 4},
		"literal too few":  {[]byte{0x03, 0x80, 0x11, 0x22}, 3},
		"overruns pixels":  {[]byte{0x08, 0x00, 0x11, 0x22}, 4},
		"decodes too few":  {[]byte{0x02, 0x00, 0x11, 0x22}, 4},
		"decodes too many": {[]byte{0x04, 0x00, 0x11, 0x22}, 2},
	} {
		if _, err := DecodeRLE(tc.src, tc.npix); err == nil {
			t.Errorf("%s: expected an error", name)
		} else if !errors.Is(err, ErrMalformed) && !errors.Is(err, ErrShort) {
			t.Errorf("%s: got %v, want ErrMalformed or ErrShort", name, err)
		}
	}
}

func flat(v uint16, n int) []uint16 {
	px := make([]uint16, n)
	for i := range px {
		px[i] = v
	}
	return px
}

func alternating(n int) []uint16 {
	px := make([]uint16, n)
	for i := range px {
		px[i] = uint16(i % 2)
	}
	return px
}

func randomPixels(n int) []uint16 {
	r := rand.New(rand.NewSource(1))
	px := make([]uint16, n)
	for i := range px {
		px[i] = uint16(r.Intn(1 << 16))
	}
	return px
}

func equalPixels(a, b []uint16) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
