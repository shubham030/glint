// Package mdns is a minimal multicast-DNS client: enough to turn
// "glint-335b.local" into an address and to list panels advertising
// _glint._tcp. It exists because this host is built without cgo, so Go's pure
// resolver is in use and that resolver does not consult nss-mdns/avahi — a
// .local name simply fails to resolve.
//
// Deliberately not a full responder: no caching, no service registration, no
// continuous browsing. One query, collect answers for a moment, done.
package mdns

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"
)

// GlintService is the service type the firmware advertises (see net.c).
const GlintService = "_glint._tcp"

var (
	// ErrNoAnswer means nothing replied in time — the usual cause is that the
	// board is not on this network, not that anything is broken.
	ErrNoAnswer = errors.New("no mDNS answer")

	group = &net.UDPAddr{IP: net.IPv4(224, 0, 0, 251), Port: 5353}
)

// DNS record types and the classes we care about.
const (
	typeA   uint16 = 1
	typePTR uint16 = 12
	classIN uint16 = 1
)

// Resolve returns the IPv4 address of a .local hostname.
func Resolve(host string, timeout time.Duration) (net.IP, error) {
	name := strings.TrimSuffix(host, ".")
	replies, err := ask(name, typeA, timeout, func(rrs []record) bool {
		for _, rr := range rrs {
			if rr.rrType == typeA && strings.EqualFold(rr.name, name) {
				return true
			}
		}
		return false
	})
	if err != nil {
		return nil, err
	}
	for _, rr := range replies {
		if rr.rrType == typeA && strings.EqualFold(rr.name, name) && len(rr.data) == 4 {
			return net.IPv4(rr.data[0], rr.data[1], rr.data[2], rr.data[3]), nil
		}
	}
	return nil, fmt.Errorf("%s: %w", host, ErrNoAnswer)
}

// Browse lists the instance names advertising a service, e.g. "glint-335b" for
// _glint._tcp. The firmware names its instance and its host identically, so
// `<instance>.local` resolves — see PROTOCOL.md.
func Browse(service string, timeout time.Duration) ([]string, error) {
	qname := strings.TrimSuffix(service, ".") + ".local"
	// No early-exit predicate: collect for the whole window, since a second
	// panel answers independently of the first.
	replies, err := ask(qname, typePTR, timeout, nil)
	if err != nil && !errors.Is(err, ErrNoAnswer) {
		return nil, err
	}

	var names []string
	seen := map[string]bool{}
	for _, rr := range replies {
		if rr.rrType != typePTR || !strings.EqualFold(rr.name, qname) {
			continue
		}
		target, _, ok := decodeName(rr.msg, rr.dataOff)
		if !ok {
			continue
		}
		instance := strings.TrimSuffix(target, "."+qname)
		if instance == "" || instance == target || seen[instance] {
			continue
		}
		seen[instance] = true
		names = append(names, instance)
	}
	return names, nil
}

// record is one resource record from a response.
type record struct {
	name    string
	rrType  uint16
	data    []byte
	msg     []byte // whole message, for following compression pointers
	dataOff int
}

// ask sends one query and gathers answers until `timeout`, or until `enough`
// says the answer arrived. Answers are matched loosely: mDNS responders may
// reply from an address other than the group and may bundle extra records.
func ask(name string, qtype uint16, timeout time.Duration, enough func([]record) bool) ([]record, error) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{})
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	if _, err := conn.WriteToUDP(query(name, qtype), group); err != nil {
		return nil, err
	}

	deadline := time.Now().Add(timeout)
	if err := conn.SetReadDeadline(deadline); err != nil {
		return nil, err
	}

	var all []record
	buf := make([]byte, 9000) // an mDNS response can exceed a 1500-byte MTU
	for time.Now().Before(deadline) {
		n, _, rerr := conn.ReadFromUDP(buf)
		if rerr != nil {
			break // deadline, which is the normal way out
		}
		msg := make([]byte, n)
		copy(msg, buf[:n])
		rrs, perr := parse(msg)
		if perr != nil {
			continue // a malformed or unrelated packet is not our problem
		}
		all = append(all, rrs...)
		if enough != nil && enough(all) {
			return all, nil
		}
	}
	if len(all) == 0 {
		return nil, ErrNoAnswer
	}
	return all, nil
}

// query builds a one-question mDNS query. ID 0 and no flags: a plain multicast
// question, which is what every responder expects.
func query(name string, qtype uint16) []byte {
	msg := make([]byte, 12)
	binary.BigEndian.PutUint16(msg[4:], 1) // QDCOUNT
	msg = encodeName(msg, name)
	msg = binary.BigEndian.AppendUint16(msg, qtype)
	return binary.BigEndian.AppendUint16(msg, classIN)
}

func encodeName(dst []byte, name string) []byte {
	for _, label := range strings.Split(strings.TrimSuffix(name, "."), ".") {
		if label == "" {
			continue
		}
		if len(label) > 63 {
			label = label[:63]
		}
		dst = append(dst, byte(len(label)))
		dst = append(dst, label...)
	}
	return append(dst, 0)
}

// parse walks a response and returns its answer records (plus any additional
// records, which is where an A record for a browsed name usually rides along).
func parse(msg []byte) ([]record, error) {
	if len(msg) < 12 {
		return nil, errors.New("short message")
	}
	qd := int(binary.BigEndian.Uint16(msg[4:]))
	counts := int(binary.BigEndian.Uint16(msg[6:])) + // AN
		int(binary.BigEndian.Uint16(msg[8:])) + // NS
		int(binary.BigEndian.Uint16(msg[10:])) // AR

	off := 12
	for i := 0; i < qd; i++ {
		_, next, ok := decodeName(msg, off)
		if !ok || next+4 > len(msg) {
			return nil, errors.New("bad question")
		}
		off = next + 4
	}

	var out []record
	for i := 0; i < counts; i++ {
		name, next, ok := decodeName(msg, off)
		if !ok || next+10 > len(msg) {
			break
		}
		rrType := binary.BigEndian.Uint16(msg[next:])
		length := int(binary.BigEndian.Uint16(msg[next+8:]))
		dataOff := next + 10
		if dataOff+length > len(msg) {
			break
		}
		out = append(out, record{
			name:    name,
			rrType:  rrType,
			data:    msg[dataOff : dataOff+length],
			msg:     msg,
			dataOff: dataOff,
		})
		off = dataOff + length
	}
	return out, nil
}

// decodeName reads a possibly-compressed name, returning it and the offset just
// past it. Compression pointers are followed but never advance the returned
// offset, and a budget bounds them so a pointer loop cannot hang the caller.
func decodeName(msg []byte, off int) (string, int, bool) {
	var labels []string
	next := -1
	for budget := 0; budget < 128; budget++ {
		if off >= len(msg) {
			return "", 0, false
		}
		n := int(msg[off])
		switch {
		case n == 0:
			if next < 0 {
				next = off + 1
			}
			return strings.Join(labels, "."), next, true
		case n&0xC0 == 0xC0:
			if off+1 >= len(msg) {
				return "", 0, false
			}
			if next < 0 {
				next = off + 2
			}
			off = int(binary.BigEndian.Uint16(msg[off:]) & 0x3FFF)
		default:
			if off+1+n > len(msg) {
				return "", 0, false
			}
			labels = append(labels, string(msg[off+1:off+1+n]))
			off += 1 + n
		}
	}
	return "", 0, false
}
