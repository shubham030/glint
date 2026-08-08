package proto

import (
	"context"
	"errors"
	"testing"
)

// capture is a Conn that keeps every packet the tiler writes.
type capture struct {
	packets [][]byte
	fail    error
}

func (c *capture) BulkWrite(_ context.Context, p []byte) error {
	if c.fail != nil {
		return c.fail
	}
	c.packets = append(c.packets, append([]byte(nil), p...))
	return nil
}

func testHello(fmtMask uint16) Hello {
	return Hello{
		ProtoVer: Version, PanelW: 320, PanelH: 480,
		FmtMask: fmtMask, MaxTileLen: 320 * 64 * 2, TouchPoints: 2,
	}
}

func newFrame(h Hello) []uint16 { return make([]uint16, h.PanelW*h.PanelH) }

// decodePacket returns the header and the payload expanded back to pixels.
func decodePacket(t *testing.T, pkt []byte) (TileHeader, []uint16) {
	t.Helper()
	hdr, err := ParseTileHeader(pkt)
	if err != nil {
		t.Fatalf("header: %v", err)
	}
	body := pkt[TileHeaderSize:]
	if int(hdr.PayloadLen) != len(body) {
		t.Fatalf("payload_len %d but %d bytes follow the header", hdr.PayloadLen, len(body))
	}
	npix := int(hdr.W) * int(hdr.H)
	switch hdr.Fmt {
	case FmtRGB565:
		if len(body) != npix*2 {
			t.Fatalf("raw payload %d bytes for %dx%d", len(body), hdr.W, hdr.H)
		}
		px := make([]uint16, npix)
		for i := range px {
			px[i] = le16(body, i*2)
		}
		return hdr, px
	case FmtRGB565RLE:
		px, err := DecodeRLE(body, npix)
		if err != nil {
			t.Fatalf("rle payload: %v", err)
		}
		return hdr, px
	default:
		t.Fatalf("unexpected fmt %d", hdr.Fmt)
		return hdr, nil
	}
}

func mustSender(t *testing.T, h Hello, o Options) *TileSender {
	t.Helper()
	s, err := NewTileSender(h, o)
	if err != nil {
		t.Fatalf("NewTileSender: %v", err)
	}
	return s
}

func TestFirstFrameIsFullRefresh(t *testing.T) {
	h := testHello(1 << FmtRGB565)
	s := mustSender(t, h, Options{})
	if got := s.Grid(); got != "5x8 tiles of 64x64, raw" {
		t.Errorf("grid = %q", got)
	}

	c := &capture{}
	st, err := s.Send(context.Background(), c, newFrame(h), false)
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	if st.Tiles != 40 {
		t.Errorf("sent %d tiles, want 40 (5x8 grid)", st.Tiles)
	}
	if len(c.packets) != 8 {
		t.Fatalf("sent %d packets, want 8 (one full-width run per row)", len(c.packets))
	}
	for i, pkt := range c.packets {
		hdr, _ := decodePacket(t, pkt)
		if hdr.Flags&FlagFullRefresh == 0 {
			t.Errorf("packet %d: FULL_REFRESH not set on the first frame", i)
		}
		last := hdr.Flags&FlagLastInFrame != 0
		if want := i == len(c.packets)-1; last != want {
			t.Errorf("packet %d: LAST_IN_FRAME = %v, want %v", i, last, want)
		}
		wantH := uint16(64)
		if i == 7 {
			wantH = 32 // 480 is 7.5 tiles tall; the bottom row is short
		}
		if hdr.Seq != 0 || hdr.X != 0 || hdr.W != 320 || hdr.H != wantH {
			t.Errorf("packet %d: %+v", i, hdr)
		}
		if int(hdr.Y) != i*64 {
			t.Errorf("packet %d: y = %d, want %d", i, hdr.Y, i*64)
		}
	}
}

func TestUnchangedFrameSendsNothing(t *testing.T) {
	h := testHello(1 << FmtRGB565)
	s := mustSender(t, h, Options{})
	px := newFrame(h)
	c := &capture{}
	if _, err := s.Send(context.Background(), c, px, false); err != nil {
		t.Fatalf("first Send: %v", err)
	}
	c.packets = nil

	st, err := s.Send(context.Background(), c, px, false)
	if err != nil {
		t.Fatalf("second Send: %v", err)
	}
	if st.Packets != 0 || st.Bytes != 0 || len(c.packets) != 0 {
		t.Errorf("identical frame produced %+v", st)
	}

	// ...and the sequence number must not advance on an empty frame.
	px[0] = 0x1234
	if _, err := s.Send(context.Background(), c, px, false); err != nil {
		t.Fatalf("third Send: %v", err)
	}
	hdr, _ := decodePacket(t, c.packets[0])
	if hdr.Seq != 1 {
		t.Errorf("seq = %d after one non-empty frame, want 1", hdr.Seq)
	}
	if hdr.Flags&FlagFullRefresh != 0 {
		t.Error("FULL_REFRESH set on an incremental frame")
	}
}

func TestOnlyDirtyTilesAreSent(t *testing.T) {
	h := testHello(1 << FmtRGB565)
	s := mustSender(t, h, Options{})
	px := newFrame(h)
	c := &capture{}
	if _, err := s.Send(context.Background(), c, px, false); err != nil {
		t.Fatalf("prime: %v", err)
	}
	c.packets = nil

	// One pixel inside tile column 2, row 3.
	px[(3*64+10)*320+(2*64+10)] = 0xbeef
	st, err := s.Send(context.Background(), c, px, false)
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	if st.Tiles != 1 || st.Packets != 1 {
		t.Fatalf("got %+v, want 1 tile in 1 packet", st)
	}
	hdr, got := decodePacket(t, c.packets[0])
	if hdr.X != 128 || hdr.Y != 192 || hdr.W != 64 || hdr.H != 64 {
		t.Errorf("tile rect = %d,%d %dx%d, want 128,192 64x64", hdr.X, hdr.Y, hdr.W, hdr.H)
	}
	if hdr.Flags&FlagLastInFrame == 0 {
		t.Error("the only packet of a frame must carry LAST_IN_FRAME")
	}
	want := extract(px, 320, 128, 192, 64, 64)
	if !equalPixels(got, want) {
		t.Error("payload does not match the frame's tile contents")
	}
}

func TestAdjacentTilesCoalesce(t *testing.T) {
	h := testHello(1 << FmtRGB565)
	s := mustSender(t, h, Options{})
	px := newFrame(h)
	c := &capture{}
	if _, err := s.Send(context.Background(), c, px, false); err != nil {
		t.Fatalf("prime: %v", err)
	}
	c.packets = nil

	row := 1 * 64
	px[row*320+1*64] = 1 // columns 1 and 2 are adjacent -> one packet
	px[row*320+2*64] = 1
	px[row*320+4*64] = 1 // column 4 is separated by a clean column 3
	st, err := s.Send(context.Background(), c, px, false)
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	if st.Tiles != 3 || st.Packets != 2 {
		t.Fatalf("got %+v, want 3 tiles in 2 packets", st)
	}
	hdr, got := decodePacket(t, c.packets[0])
	if hdr.X != 64 || hdr.W != 128 {
		t.Errorf("coalesced run = x%d w%d, want x64 w128", hdr.X, hdr.W)
	}
	if !equalPixels(got, extract(px, 320, 64, 64, 128, 64)) {
		t.Error("coalesced payload does not match the frame")
	}
	hdr, _ = decodePacket(t, c.packets[1])
	if hdr.X != 256 || hdr.W != 64 {
		t.Errorf("second run = x%d w%d, want x256 w64", hdr.X, hdr.W)
	}
	if hdr.Flags&FlagLastInFrame == 0 {
		t.Error("last packet of the frame lacks LAST_IN_FRAME")
	}
}

func TestPartialEdgeTiles(t *testing.T) {
	// 100x50 panel: the grid does not divide evenly in either axis.
	h := Hello{ProtoVer: Version, PanelW: 100, PanelH: 50, MaxTileLen: 100 * 64 * 2}
	s := mustSender(t, h, Options{})
	c := &capture{}
	if _, err := s.Send(context.Background(), c, newFrame(h), false); err != nil {
		t.Fatalf("Send: %v", err)
	}
	if len(c.packets) != 1 {
		t.Fatalf("got %d packets, want 1", len(c.packets))
	}
	hdr, px := decodePacket(t, c.packets[0])
	if hdr.W != 100 || hdr.H != 50 {
		t.Errorf("edge tile = %dx%d, want 100x50", hdr.W, hdr.H)
	}
	if len(px) != 100*50 {
		t.Errorf("payload holds %d pixels, want %d", len(px), 100*50)
	}
}

func TestTileHeightCappedByMaxTileLen(t *testing.T) {
	// max_tile_len only fits 8 rows of 320 pixels.
	h := testHello(1 << FmtRGB565)
	h.MaxTileLen = 320 * 8 * 2
	s := mustSender(t, h, Options{})
	if got := s.Grid(); got != "5x60 tiles of 64x8, raw" {
		t.Errorf("grid = %q, want 64x8 tiles", got)
	}
	c := &capture{}
	if _, err := s.Send(context.Background(), c, newFrame(h), false); err != nil {
		t.Fatalf("Send: %v", err)
	}
	for i, pkt := range c.packets {
		hdr, _ := decodePacket(t, pkt)
		if int(hdr.PayloadLen) > h.MaxTileLen {
			t.Fatalf("packet %d payload %d exceeds max_tile_len %d", i, hdr.PayloadLen, h.MaxTileLen)
		}
	}

	h.MaxTileLen = 100 // less than one row
	if _, err := NewTileSender(h, Options{}); err == nil {
		t.Error("max_tile_len smaller than a row must be rejected")
	}
}

func TestRLEOnlyWhenAdvertisedAndSmaller(t *testing.T) {
	flatFrame := func(h Hello) []uint16 {
		px := newFrame(h)
		for i := range px {
			px[i] = 0x07e0
		}
		return px
	}

	h := testHello(1 << FmtRGB565) // firmware without RLE
	s := mustSender(t, h, Options{})
	c := &capture{}
	if _, err := s.Send(context.Background(), c, flatFrame(h), false); err != nil {
		t.Fatalf("Send: %v", err)
	}
	for i, pkt := range c.packets {
		if hdr, _ := decodePacket(t, pkt); hdr.Fmt != FmtRGB565 {
			t.Fatalf("packet %d used fmt %d against a device advertising %#x", i, hdr.Fmt, h.FmtMask)
		}
	}

	h = testHello(1<<FmtRGB565 | 1<<FmtRGB565RLE)
	s = mustSender(t, h, Options{})
	if got := s.Grid(); got != "5x8 tiles of 64x64, rle" {
		t.Errorf("grid = %q, want rle", got)
	}
	c = &capture{}
	st, err := s.Send(context.Background(), c, flatFrame(h), false)
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	for i, pkt := range c.packets {
		hdr, px := decodePacket(t, pkt)
		if hdr.Fmt != FmtRGB565RLE {
			t.Errorf("packet %d: fmt %d, want RLE for a flat frame", i, hdr.Fmt)
		}
		if px[0] != 0x07e0 || len(px) != int(hdr.W)*int(hdr.H) {
			t.Errorf("packet %d decoded wrong", i)
		}
	}
	if st.Bytes >= 320*480*2 {
		t.Errorf("RLE frame took %d bytes, more than raw", st.Bytes)
	}

	// Incompressible content must fall back to raw.
	noise := newFrame(h)
	copy(noise, randomPixels(len(noise)))
	c = &capture{}
	if _, err := s.Send(context.Background(), c, noise, true); err != nil {
		t.Fatalf("Send: %v", err)
	}
	for i, pkt := range c.packets {
		if hdr, _ := decodePacket(t, pkt); hdr.Fmt != FmtRGB565 {
			t.Errorf("packet %d used RLE for incompressible pixels", i)
		}
	}

	// ...and DisableRLE wins over the device's advertisement.
	s = mustSender(t, h, Options{DisableRLE: true})
	c = &capture{}
	if _, err := s.Send(context.Background(), c, flatFrame(h), false); err != nil {
		t.Fatalf("Send: %v", err)
	}
	if hdr, _ := decodePacket(t, c.packets[0]); hdr.Fmt != FmtRGB565 {
		t.Errorf("DisableRLE ignored: fmt %d", hdr.Fmt)
	}
}

func TestInvalidateForcesFullRefresh(t *testing.T) {
	h := testHello(1 << FmtRGB565)
	s := mustSender(t, h, Options{})
	px := newFrame(h)
	c := &capture{}
	if _, err := s.Send(context.Background(), c, px, false); err != nil {
		t.Fatalf("prime: %v", err)
	}
	c.packets = nil
	s.Invalidate()
	st, err := s.Send(context.Background(), c, px, false)
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	if st.Tiles != 40 {
		t.Fatalf("after Invalidate: %d tiles, want the whole grid", st.Tiles)
	}
	if hdr, _ := decodePacket(t, c.packets[0]); hdr.Flags&FlagFullRefresh == 0 {
		t.Error("FULL_REFRESH not set after Invalidate")
	}
}

func TestSendPropagatesTransportErrors(t *testing.T) {
	h := testHello(1 << FmtRGB565)
	s := mustSender(t, h, Options{})
	boom := errors.New("bulk stall")
	if _, err := s.Send(context.Background(), &capture{fail: boom}, newFrame(h), false); !errors.Is(err, boom) {
		t.Errorf("got %v, want the transport error wrapped", err)
	}

	if _, err := s.Send(context.Background(), &capture{}, make([]uint16, 10), false); !errors.Is(err, ErrShort) {
		t.Errorf("short frame: got %v, want ErrShort", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := s.Send(ctx, &capture{}, newFrame(h), false); !errors.Is(err, context.Canceled) {
		t.Errorf("cancelled context: got %v, want context.Canceled", err)
	}
}

// flaky accepts a few packets and then stalls, like a device that goes away
// mid-frame.
type flaky struct {
	capture
	accept int
}

func (f *flaky) BulkWrite(ctx context.Context, p []byte) error {
	if len(f.packets) >= f.accept {
		return errors.New("device stalled")
	}
	return f.capture.BulkWrite(ctx, p)
}

// A frame that dies half way has already updated the hashes for tiles the
// panel never saw, so the next frame must be a full refresh.
func TestPartialFrameForcesFullRefresh(t *testing.T) {
	h := testHello(1 << FmtRGB565)
	s := mustSender(t, h, Options{})
	px := newFrame(h)
	c := &capture{}
	if _, err := s.Send(context.Background(), c, px, false); err != nil {
		t.Fatalf("prime: %v", err)
	}

	// Dirty two separated tiles so the frame is more than one packet.
	px[1*64*320+1*64] = 1
	px[1*64*320+4*64] = 1
	f := &flaky{accept: 1}
	st, err := s.Send(context.Background(), f, px, false)
	if err == nil {
		t.Fatal("expected the stall to surface")
	}
	if st.Packets != 1 {
		t.Errorf("reported %d packets sent, want 1 (the one that got through)", st.Packets)
	}

	c.packets = nil
	next, err := s.Send(context.Background(), c, px, false)
	if err != nil {
		t.Fatalf("recovery frame: %v", err)
	}
	if next.Tiles != 40 {
		t.Errorf("recovery frame sent %d tiles, want the whole grid", next.Tiles)
	}
	if hdr, _ := decodePacket(t, c.packets[0]); hdr.Flags&FlagFullRefresh == 0 {
		t.Error("recovery frame is not a FULL_REFRESH")
	}
}

// extract pulls a w*h rect out of a panelW-wide frame.
func extract(px []uint16, panelW, x, y, w, h int) []uint16 {
	out := make([]uint16, 0, w*h)
	for row := y; row < y+h; row++ {
		out = append(out, px[row*panelW+x:row*panelW+x+w]...)
	}
	return out
}
