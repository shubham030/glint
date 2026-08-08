package proto

import "testing"

// The three implementations of this protocol (Swift host, C firmware, this) must
// agree byte for byte. These fixtures come from the real Swift encoder in
// host/Sources/GlintCore/RLE.swift and are decoded by the real C decoder in
// firmware/test/rle_test.c, so pinning them here makes any format drift a test
// failure instead of a smeared panel.
var swiftFixture = []byte{
	0x64, 0x00, 0x00, 0x00, 0x03, 0x80, 0x11, 0x11, 0x22, 0x22, 0x33, 0x33,
	0x07, 0x00, 0x00, 0xF8, 0x02, 0x80, 0xE0, 0x07, 0xE0, 0x07, 0x90, 0x0F,
	0x1F, 0x00,
}

// The pixels swiftFixture encodes: 100 black, 3 literals, 7 red, 2 green, then
// the rest of a 64x64 tile in blue.
func fixturePixels() []uint16 {
	px := make([]uint16, 0, 4096)
	for i := 0; i < 100; i++ {
		px = append(px, 0x0000)
	}
	px = append(px, 0x1111, 0x2222, 0x3333)
	for i := 0; i < 7; i++ {
		px = append(px, 0xF800)
	}
	px = append(px, 0x07E0, 0x07E0)
	for len(px) < 4096 {
		px = append(px, 0x001F)
	}
	return px
}

func TestDecodeSwiftFixture(t *testing.T) {
	got, err := DecodeRLE(swiftFixture, 4096)
	if err != nil {
		t.Fatalf("decoding the Swift encoder's output failed: %v", err)
	}
	want := fixturePixels()
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("pixel %d: got %#04x, want %#04x", i, got[i], want[i])
		}
	}
}

func TestEncodeMatchesSwiftFixtureByteForByte(t *testing.T) {
	got := AppendRLE(nil, fixturePixels())
	if len(got) != len(swiftFixture) {
		t.Fatalf("encoded %d bytes, Swift encoder produced %d: %#v",
			len(got), len(swiftFixture), got)
	}
	for i := range swiftFixture {
		if got[i] != swiftFixture[i] {
			t.Fatalf("byte %d: got %#02x, want %#02x (full: %#v)",
				i, got[i], swiftFixture[i], got)
		}
	}
}
