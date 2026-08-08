// Package proto implements the glint wire protocol: the little-endian packet
// layouts from protocol/protocol.h, the dirty-tile coalescer that produces
// them, and the RGB565 run-length codec (fmt 1).
//
// Nothing here touches the operating system, so it builds and tests anywhere.
package proto

import (
	"errors"
	"fmt"
)

// USB identity and endpoints.
const (
	VendorID  uint16 = 0xCAFE
	ProductID uint16 = 0x4010

	EndpointBulkOut uint8 = 0x01
	EndpointBulkIn  uint8 = 0x81
)

// Packet magics, protocol version and fixed struct sizes.
const (
	MagicHello uint32 = 0x4C483450 // 'P4HL'
	MagicTile  uint32 = 0x44543450 // 'P4TD'
	MagicEvt   uint32 = 0x56453450 // 'P4EV'

	Version uint16 = 1

	HelloSize      = 24
	TileHeaderSize = 24
	EventSize      = 12
)

// Vendor control requests (bmRequestType: vendor | interface).
const (
	CmdHello     uint8 = 0x01
	CmdBacklight uint8 = 0x02
	CmdReset     uint8 = 0x03
	CmdSleep     uint8 = 0x04
)

// Payload formats. A device advertises support as (1 << fmt) in Hello.FmtMask.
const (
	FmtRGB565    uint16 = 0
	FmtRGB565RLE uint16 = 1
	FmtJPEG      uint16 = 2
)

// TileHeader.Flags bits.
const (
	FlagLastInFrame uint16 = 1 << 0
	FlagFullRefresh uint16 = 1 << 1
)

// Parse failures. Callers distinguish these with errors.Is.
var (
	ErrShort     = errors.New("buffer too short")
	ErrBadMagic  = errors.New("wrong magic")
	ErrVersion   = errors.New("unsupported protocol version")
	ErrMalformed = errors.New("malformed packet")
)

// Hello is the device description returned by the CmdHello control read.
type Hello struct {
	ProtoVer    uint16
	PanelW      int
	PanelH      int
	FmtMask     uint16
	MaxTileLen  int
	TouchPoints int
	FwVer       uint32
}

// Supports reports whether the device accepts a payload format.
func (h Hello) Supports(format uint16) bool {
	return h.FmtMask&(1<<format) != 0
}

func (h Hello) String() string {
	return fmt.Sprintf("panel %dx%d, fmt_mask=%#x, max_tile=%d, touch=%dpt, fw=%08x",
		h.PanelW, h.PanelH, h.FmtMask, h.MaxTileLen, h.TouchPoints, h.FwVer)
}

// ParseHello decodes the 24-byte hello struct.
func ParseHello(b []byte) (Hello, error) {
	if len(b) < HelloSize {
		return Hello{}, fmt.Errorf("hello: have %d bytes, want %d: %w", len(b), HelloSize, ErrShort)
	}
	if m := le32(b, 0); m != MagicHello {
		return Hello{}, fmt.Errorf("hello: magic %#08x, want %#08x: %w", m, MagicHello, ErrBadMagic)
	}
	h := Hello{
		ProtoVer:    le16(b, 4),
		PanelW:      int(le16(b, 6)),
		PanelH:      int(le16(b, 8)),
		FmtMask:     le16(b, 10),
		MaxTileLen:  int(le32(b, 12)),
		TouchPoints: int(le16(b, 16)),
		FwVer:       le32(b, 20),
	}
	if h.ProtoVer != Version {
		return Hello{}, fmt.Errorf("hello: device speaks v%d, host speaks v%d: %w", h.ProtoVer, Version, ErrVersion)
	}
	if h.PanelW <= 0 || h.PanelH <= 0 {
		return Hello{}, fmt.Errorf("hello: panel %dx%d: %w", h.PanelW, h.PanelH, ErrMalformed)
	}
	return h, nil
}

// AppendHello serialises a Hello. Only the tests and fakes need this; the
// device is the sole producer on the wire.
func AppendHello(dst []byte, h Hello) []byte {
	dst = append32(dst, MagicHello)
	dst = append16(dst, h.ProtoVer)
	dst = append16(dst, uint16(h.PanelW))
	dst = append16(dst, uint16(h.PanelH))
	dst = append16(dst, h.FmtMask)
	dst = append32(dst, uint32(h.MaxTileLen))
	dst = append16(dst, uint16(h.TouchPoints))
	dst = append16(dst, 0) // rsvd
	return append32(dst, h.FwVer)
}

// TileHeader is the 24-byte header prefixing every bulk OUT payload.
type TileHeader struct {
	Seq        uint16
	Flags      uint16
	X, Y       uint16
	W, H       uint16
	Fmt        uint16
	PayloadLen uint32
}

// AppendTo serialises the header onto dst.
func (t TileHeader) AppendTo(dst []byte) []byte {
	dst = append32(dst, MagicTile)
	dst = append16(dst, t.Seq)
	dst = append16(dst, t.Flags)
	dst = append16(dst, t.X)
	dst = append16(dst, t.Y)
	dst = append16(dst, t.W)
	dst = append16(dst, t.H)
	dst = append16(dst, t.Fmt)
	dst = append16(dst, 0) // rsvd
	return append32(dst, t.PayloadLen)
}

// ParseTileHeader decodes a tile header. The host never receives one; this
// exists so tests can assert what was written.
func ParseTileHeader(b []byte) (TileHeader, error) {
	if len(b) < TileHeaderSize {
		return TileHeader{}, fmt.Errorf("tile: have %d bytes, want %d: %w", len(b), TileHeaderSize, ErrShort)
	}
	if m := le32(b, 0); m != MagicTile {
		return TileHeader{}, fmt.Errorf("tile: magic %#08x, want %#08x: %w", m, MagicTile, ErrBadMagic)
	}
	return TileHeader{
		Seq:        le16(b, 4),
		Flags:      le16(b, 6),
		X:          le16(b, 8),
		Y:          le16(b, 10),
		W:          le16(b, 12),
		H:          le16(b, 14),
		Fmt:        le16(b, 16),
		PayloadLen: le32(b, 20),
	}, nil
}

// EventType is the discriminant of a bulk IN event.
type EventType uint8

// Event types carried in Event.Type.
const (
	EvtDown  EventType = 1
	EvtMove  EventType = 2
	EvtUp    EventType = 3
	EvtHello EventType = 4
	EvtStats EventType = 5
)

func (t EventType) String() string {
	switch t {
	case EvtDown:
		return "down"
	case EvtMove:
		return "move"
	case EvtUp:
		return "up"
	case EvtHello:
		return "hello"
	case EvtStats:
		return "stats"
	default:
		return fmt.Sprintf("type(%d)", uint8(t))
	}
}

// Event is the 12-byte device-to-host packet on the bulk IN endpoint.
type Event struct {
	Type EventType
	ID   uint8
	X, Y uint16
}

// ParseEvent decodes one event from the head of b.
func ParseEvent(b []byte) (Event, error) {
	if len(b) < EventSize {
		return Event{}, fmt.Errorf("event: have %d bytes, want %d: %w", len(b), EventSize, ErrShort)
	}
	if m := le32(b, 0); m != MagicEvt {
		return Event{}, fmt.Errorf("event: magic %#08x, want %#08x: %w", m, MagicEvt, ErrBadMagic)
	}
	return Event{Type: EventType(b[4]), ID: b[5], X: le16(b, 6), Y: le16(b, 8)}, nil
}

// AppendEvent serialises an event; used by tests and fakes.
func AppendEvent(dst []byte, e Event) []byte {
	dst = append32(dst, MagicEvt)
	dst = append(dst, byte(e.Type), e.ID)
	dst = append16(dst, e.X)
	dst = append16(dst, e.Y)
	return append16(dst, 0) // rsvd
}

func le16(b []byte, o int) uint16 { return uint16(b[o]) | uint16(b[o+1])<<8 }

func le32(b []byte, o int) uint32 {
	return uint32(b[o]) | uint32(b[o+1])<<8 | uint32(b[o+2])<<16 | uint32(b[o+3])<<24
}

func append16(dst []byte, v uint16) []byte {
	return append(dst, byte(v), byte(v>>8))
}

func append32(dst []byte, v uint32) []byte {
	return append(dst, byte(v), byte(v>>8), byte(v>>16), byte(v>>24))
}
