package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"

	"github.com/shubham030/glint/linux/mdns"
	"github.com/shubham030/glint/linux/proto"
	"github.com/shubham030/glint/linux/usbfs"
)

// defaultNetPort is the firmware's listener (GLINT_NET_PORT in net.c).
const defaultNetPort = 7788

// link is what every mode needs from a transport. The method set is the one
// *usbfs.Device already has, so USB satisfies it as-is and the streaming code
// did not have to change shape to gain a second transport.
//
// Idleness is reported as usbfs.ErrTimeout by both transports. The name is a
// USB one, but one sentinel means the event loops need no per-transport case.
type link interface {
	BulkWrite(ctx context.Context, p []byte) error
	BulkRead(ctx context.Context, p []byte) (int, error)
	ControlRead(request uint8, value uint16, buf []byte) (int, error)
	ControlWrite(request uint8, value uint16) error
	MaxPacketSize() int
	Describe() string
	Close() error
}

// usbLink adds a description to the USB device without pushing display
// concerns down into the usbfs package.
type usbLink struct{ *usbfs.Device }

func (u usbLink) Describe() string {
	return fmt.Sprintf("usb=%s-speed, ep_max_packet=%d (%s)",
		u.Speed(), u.MaxPacketSize(), u.Path())
}

// netLink carries the same byte stream over TCP. A socket has no control pipe,
// so control travels in band as an 8-byte request (glint_req_t) and the HELLO
// reply comes back on the same stream — see PROTOCOL.md.
type netLink struct {
	conn net.Conn
	r    *bufio.Reader
	addr string
}

// netReadTimeout bounds a poll for events. It is a poll, not a wait: the
// caller loops, so this only decides how often an idle link wakes up.
const netReadTimeout = 200 * time.Millisecond

func dialNet(host string, port int, timeout time.Duration) (*netLink, error) {
	addr := net.JoinHostPort(host, fmt.Sprint(port))

	// Go's pure resolver (this binary is built without cgo, so it is always the
	// pure one) does not speak mDNS, so a .local name would simply fail to
	// resolve. Resolving it ourselves is what makes `-net glint-335b.local`
	// work on a Pi the same way it does on macOS.
	if strings.HasSuffix(host, ".local") {
		ip, err := mdns.Resolve(host, 2*time.Second)
		if err != nil {
			return nil, fmt.Errorf("resolve %s: %w", host, err)
		}
		addr = net.JoinHostPort(ip.String(), fmt.Sprint(port))
	}

	conn, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return nil, err
	}
	if tcp, ok := conn.(*net.TCPConn); ok {
		// Tiles are latency-sensitive and already batched per frame, so Nagle
		// would only add delay.
		tcp.SetNoDelay(true)
	}
	return &netLink{conn: conn, r: bufio.NewReaderSize(conn, 4096), addr: addr}, nil
}

func (n *netLink) Describe() string { return "wifi " + n.addr }

func (n *netLink) MaxPacketSize() int { return 512 }

func (n *netLink) Close() error { return n.conn.Close() }

func (n *netLink) BulkWrite(ctx context.Context, p []byte) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := n.conn.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return err
	}
	_, err := n.conn.Write(p)
	return err
}

// BulkRead returns whole events only. TCP may split a read anywhere, while the
// USB path always delivers whole transfers, so the callers' "parse buf in
// EventSize chunks" loop would otherwise mis-frame a split event.
func (n *netLink) BulkRead(ctx context.Context, p []byte) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	if len(p) < proto.EventSize {
		return 0, fmt.Errorf("event buffer is %d bytes, need %d", len(p), proto.EventSize)
	}
	if err := n.conn.SetReadDeadline(time.Now().Add(netReadTimeout)); err != nil {
		return 0, err
	}
	if _, err := io.ReadFull(n.r, p[:proto.EventSize]); err != nil {
		var netErr net.Error
		if errors.As(err, &netErr) && netErr.Timeout() {
			return 0, usbfs.ErrTimeout
		}
		return 0, err
	}
	// Drain whatever else already arrived, so a burst is not spread over as
	// many wake-ups as it has events.
	got := proto.EventSize
	for got+proto.EventSize <= len(p) && n.r.Buffered() >= proto.EventSize {
		if _, err := io.ReadFull(n.r, p[got:got+proto.EventSize]); err != nil {
			return got, err
		}
		got += proto.EventSize
	}
	return got, nil
}

func (n *netLink) ControlWrite(request uint8, value uint16) error {
	return n.BulkWrite(context.Background(), proto.AppendRequest(nil, request, value))
}

// ControlRead serves CmdHello; nothing else has a reply.
func (n *netLink) ControlRead(request uint8, value uint16, buf []byte) (int, error) {
	if request != proto.CmdHello {
		return 0, fmt.Errorf("in-band request %#02x has no reply", request)
	}
	if len(buf) < proto.HelloSize {
		return 0, fmt.Errorf("hello buffer is %d bytes, need %d", len(buf), proto.HelloSize)
	}
	if err := n.ControlWrite(request, value); err != nil {
		return 0, err
	}
	if err := n.conn.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		return 0, err
	}
	// The device may already be emitting events, so the reply is not
	// necessarily the first thing on the stream: skip whole events until the
	// HELLO turns up.
	for {
		head, err := n.r.Peek(4)
		if err != nil {
			return 0, err
		}
		switch binary.LittleEndian.Uint32(head) {
		case proto.MagicHello:
			if _, err := io.ReadFull(n.r, buf[:proto.HelloSize]); err != nil {
				return 0, err
			}
			return proto.HelloSize, nil
		case proto.MagicEvt:
			if _, err := n.r.Discard(proto.EventSize); err != nil {
				return 0, err
			}
		default:
			return 0, fmt.Errorf("unexpected magic %#08x while waiting for HELLO",
				binary.LittleEndian.Uint32(head))
		}
	}
}

// openLink connects over whichever transport was asked for: -net names a panel
// (or "auto" to take the first one advertising itself), otherwise USB.
func openLink(netHost string, port int) (link, error) {
	if netHost == "" {
		dev, err := usbfs.Open(proto.VendorID, proto.ProductID)
		if err != nil {
			return nil, err
		}
		return usbLink{dev}, nil
	}

	if netHost == "auto" {
		names, err := mdns.Browse(mdns.GlintService, 2*time.Second)
		if err != nil {
			return nil, fmt.Errorf("discovery: %w", err)
		}
		if len(names) == 0 {
			return nil, errors.New("no panel is advertising itself on this network")
		}
		var errs []string
		for _, name := range names {
			l, err := dialNet(name+".local", port, 3*time.Second)
			if err == nil {
				return l, nil
			}
			errs = append(errs, fmt.Sprintf("%s (%v)", name, err))
		}
		return nil, fmt.Errorf("found %s but could not connect: %s",
			strings.Join(names, ", "), strings.Join(errs, "; "))
	}

	return dialNet(netHost, port, 3*time.Second)
}
