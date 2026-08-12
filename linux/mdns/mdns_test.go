package mdns

import (
	"encoding/binary"
	"testing"
)

func TestQueryIsAWellFormedQuestion(t *testing.T) {
	q := query("glint-335b.local", typeA)

	if got := binary.BigEndian.Uint16(q[4:]); got != 1 {
		t.Fatalf("QDCOUNT = %d, want 1", got)
	}
	name, next, ok := decodeName(q, 12)
	if !ok || name != "glint-335b.local" {
		t.Fatalf("name = %q ok=%v, want glint-335b.local", name, ok)
	}
	if got := binary.BigEndian.Uint16(q[next:]); got != typeA {
		t.Errorf("qtype = %d, want %d", got, typeA)
	}
	if got := binary.BigEndian.Uint16(q[next+2:]); got != classIN {
		t.Errorf("qclass = %d, want %d", got, classIN)
	}
}

// response builds a reply with one A record, answering the question it echoes.
func response(t *testing.T, host string, ip [4]byte) []byte {
	t.Helper()
	msg := make([]byte, 12)
	binary.BigEndian.PutUint16(msg[4:], 1) // QDCOUNT
	binary.BigEndian.PutUint16(msg[6:], 1) // ANCOUNT
	msg = encodeName(msg, host)
	msg = binary.BigEndian.AppendUint16(msg, typeA)
	msg = binary.BigEndian.AppendUint16(msg, classIN)

	nameAt := 12
	msg = append(msg, 0xC0, byte(nameAt)) // compression pointer to the question
	msg = binary.BigEndian.AppendUint16(msg, typeA)
	msg = binary.BigEndian.AppendUint16(msg, classIN)
	msg = binary.BigEndian.AppendUint32(msg, 120) // TTL
	msg = binary.BigEndian.AppendUint16(msg, 4)   // RDLENGTH
	return append(msg, ip[0], ip[1], ip[2], ip[3])
}

func TestParseFollowsCompressionPointers(t *testing.T) {
	msg := response(t, "glint-335b.local", [4]byte{192, 168, 1, 51})

	rrs, err := parse(msg)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(rrs) != 1 {
		t.Fatalf("got %d records, want 1", len(rrs))
	}
	if rrs[0].name != "glint-335b.local" {
		t.Errorf("name = %q", rrs[0].name)
	}
	if rrs[0].rrType != typeA {
		t.Errorf("type = %d, want A", rrs[0].rrType)
	}
	if want := [4]byte{192, 168, 1, 51}; [4]byte(rrs[0].data) != want {
		t.Errorf("data = %v, want %v", rrs[0].data, want)
	}
}

func TestDecodeNameRejectsAPointerLoop(t *testing.T) {
	// A pointer at offset 12 aiming at itself: a responder that did this would
	// hang a parser that trusts pointers, so the budget must stop it.
	msg := make([]byte, 14)
	binary.BigEndian.PutUint16(msg[4:], 1)
	msg[12], msg[13] = 0xC0, 12

	if _, _, ok := decodeName(msg, 12); ok {
		t.Fatal("decodeName accepted a self-referential pointer")
	}
}

func TestParseRejectsTruncatedRecords(t *testing.T) {
	msg := response(t, "glint-335b.local", [4]byte{10, 0, 0, 1})

	// Cut the address in half: the record claims 4 bytes and has 2.
	rrs, err := parse(msg[:len(msg)-2])
	if err != nil {
		return // rejecting the whole message is also acceptable
	}
	for _, rr := range rrs {
		if rr.rrType == typeA && len(rr.data) != 4 {
			t.Fatalf("returned a truncated A record: %v", rr.data)
		}
	}
}
