package proto

import (
	"errors"
	"testing"
)

func TestParseHelloRoundTrip(t *testing.T) {
	want := Hello{
		ProtoVer: Version, PanelW: 320, PanelH: 480,
		FmtMask: 1 << FmtRGB565, MaxTileLen: 320 * 64 * 2,
		TouchPoints: 2, FwVer: 0x00000100,
	}
	b := AppendHello(nil, want)
	if len(b) != HelloSize {
		t.Fatalf("hello is %d bytes, protocol.h says %d", len(b), HelloSize)
	}
	got, err := ParseHello(b)
	if err != nil {
		t.Fatalf("ParseHello: %v", err)
	}
	if got != want {
		t.Errorf("round trip: got %+v, want %+v", got, want)
	}
}

// The byte layout is the contract with the firmware, so pin it explicitly
// rather than only round-tripping through our own writer.
func TestHelloWireLayout(t *testing.T) {
	b := AppendHello(nil, Hello{
		ProtoVer: 1, PanelW: 320, PanelH: 480, FmtMask: 3,
		MaxTileLen: 40960, TouchPoints: 2, FwVer: 0x00000100,
	})
	want := []byte{
		0x50, 0x34, 0x48, 0x4c, // magic 'P4HL' LE
		0x01, 0x00, // proto_ver
		0x40, 0x01, // panel_w 320
		0xe0, 0x01, // panel_h 480
		0x03, 0x00, // fmt_mask
		0x00, 0xa0, 0x00, 0x00, // max_tile_len 40960
		0x02, 0x00, // touch_points
		0x00, 0x00, // rsvd
		0x00, 0x01, 0x00, 0x00, // fw_ver
	}
	if string(b) != string(want) {
		t.Errorf("hello bytes\n got %x\nwant %x", b, want)
	}
}

func TestParseHelloRejects(t *testing.T) {
	good := AppendHello(nil, Hello{ProtoVer: Version, PanelW: 320, PanelH: 480})

	bad := append([]byte(nil), good...)
	bad[0] ^= 0xff
	if _, err := ParseHello(bad); !errors.Is(err, ErrBadMagic) {
		t.Errorf("corrupt magic: got %v, want ErrBadMagic", err)
	}

	bad = append([]byte(nil), good...)
	bad[4] = 9
	if _, err := ParseHello(bad); !errors.Is(err, ErrVersion) {
		t.Errorf("proto v9: got %v, want ErrVersion", err)
	}

	if _, err := ParseHello(good[:12]); !errors.Is(err, ErrShort) {
		t.Errorf("truncated: got %v, want ErrShort", err)
	}

	zero := AppendHello(nil, Hello{ProtoVer: Version})
	if _, err := ParseHello(zero); !errors.Is(err, ErrMalformed) {
		t.Errorf("0x0 panel: got %v, want ErrMalformed", err)
	}
}

func TestTileHeaderWireLayout(t *testing.T) {
	h := TileHeader{
		Seq: 0x1234, Flags: FlagLastInFrame | FlagFullRefresh,
		X: 64, Y: 128, W: 192, H: 64, Fmt: FmtRGB565RLE, PayloadLen: 24576,
	}
	b := h.AppendTo(nil)
	if len(b) != TileHeaderSize {
		t.Fatalf("tile header is %d bytes, protocol.h says %d", len(b), TileHeaderSize)
	}
	want := []byte{
		0x50, 0x34, 0x54, 0x44, // magic 'P4TD' LE
		0x34, 0x12, // seq
		0x03, 0x00, // flags
		0x40, 0x00, // x
		0x80, 0x00, // y
		0xc0, 0x00, // w
		0x40, 0x00, // h
		0x01, 0x00, // fmt
		0x00, 0x00, // rsvd
		0x00, 0x60, 0x00, 0x00, // payload_len
	}
	if string(b) != string(want) {
		t.Fatalf("tile bytes\n got %x\nwant %x", b, want)
	}
	got, err := ParseTileHeader(b)
	if err != nil {
		t.Fatalf("ParseTileHeader: %v", err)
	}
	if got != h {
		t.Errorf("round trip: got %+v, want %+v", got, h)
	}
}

func TestParseEvent(t *testing.T) {
	want := Event{Type: EvtMove, ID: 1, X: 300, Y: 470}
	b := AppendEvent(nil, want)
	if len(b) != EventSize {
		t.Fatalf("event is %d bytes, protocol.h says %d", len(b), EventSize)
	}
	got, err := ParseEvent(b)
	if err != nil {
		t.Fatalf("ParseEvent: %v", err)
	}
	if got != want {
		t.Errorf("got %+v, want %+v", got, want)
	}
	if _, err := ParseEvent(b[:8]); !errors.Is(err, ErrShort) {
		t.Errorf("truncated: got %v, want ErrShort", err)
	}
	b[1] ^= 0xff
	if _, err := ParseEvent(b); !errors.Is(err, ErrBadMagic) {
		t.Errorf("corrupt magic: got %v, want ErrBadMagic", err)
	}
}

func TestHelloSupports(t *testing.T) {
	// The shipping firmware advertises RGB565 only; the host must not assume
	// RLE just because it can encode it.
	old := Hello{FmtMask: 1 << FmtRGB565}
	if !old.Supports(FmtRGB565) || old.Supports(FmtRGB565RLE) {
		t.Errorf("fmt_mask=%#x misread", old.FmtMask)
	}
	newer := Hello{FmtMask: 1<<FmtRGB565 | 1<<FmtRGB565RLE}
	if !newer.Supports(FmtRGB565RLE) || newer.Supports(FmtJPEG) {
		t.Errorf("fmt_mask=%#x misread", newer.FmtMask)
	}
}
