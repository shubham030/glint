package main

import (
	"testing"

	"github.com/shubham030/glint/linux/proto"
)

func stats(dropped, resyncs uint16) proto.Event {
	return proto.Event{Type: proto.EvtStats, X: dropped, Y: resyncs}
}

func TestResyncWatcherPolicy(t *testing.T) {
	for _, tc := range []struct {
		name   string
		events []proto.Event
		want   []bool
	}{
		{
			name:   "touch events never force a refresh",
			events: []proto.Event{{Type: proto.EvtDown, X: 5, Y: 5}, {Type: proto.EvtMove, X: 6, Y: 6}, {Type: proto.EvtUp}},
			want:   []bool{false, false, false},
		},
		{
			name:   "a clean first report changes nothing",
			events: []proto.Event{stats(0, 0), stats(0, 0)},
			want:   []bool{false, false},
		},
		{
			name:   "losses before the reader started watching still count",
			events: []proto.Event{stats(3, 0)},
			want:   []bool{true},
		},
		{
			name:   "a rise in dropped tiles forces a refresh, once",
			events: []proto.Event{stats(0, 0), stats(2, 0), stats(2, 0), stats(9, 0)},
			want:   []bool{false, true, false, true},
		},
		{
			name:   "a rise in resyncs counts too — a resync means a lost tile",
			events: []proto.Event{stats(0, 0), stats(0, 1)},
			want:   []bool{false, true},
		},
		{
			name:   "counters going backwards mean the device restarted",
			events: []proto.Event{stats(40, 3), stats(0, 0)},
			want:   []bool{true, true},
		},
		{
			name:   "a saturated counter stops asking",
			events: []proto.Event{stats(0xFFFF, 0), stats(0xFFFF, 0)},
			want:   []bool{true, false},
		},
	} {
		var w resyncWatcher
		for i, evt := range tc.events {
			if got := w.observe(evt); got != tc.want[i] {
				t.Errorf("%s: event %d (%+v) = %v, want %v", tc.name, i, evt, got, tc.want[i])
			}
		}
	}
}

// One bulk transfer can carry several queued events; a refresh anywhere in it
// must survive the rest of the batch.
func TestScanEventsBatches(t *testing.T) {
	var buf []byte
	for _, e := range []proto.Event{
		{Type: proto.EvtDown, X: 1, Y: 2},
		stats(0, 0),
		{Type: proto.EvtUp, X: 1, Y: 2},
	} {
		buf = proto.AppendEvent(buf, e)
	}
	var w resyncWatcher
	if scanEvents(buf, &w) {
		t.Error("a clean stats report asked for a refresh")
	}

	buf = proto.AppendEvent(nil, stats(1, 0))
	buf = proto.AppendEvent(buf, proto.Event{Type: proto.EvtMove, X: 3, Y: 4})
	if !scanEvents(buf, &w) {
		t.Error("a rise in dropped tiles was lost in the batch")
	}
	// The watcher must have consumed the new value, not re-fire on the next
	// identical report.
	if scanEvents(proto.AppendEvent(nil, stats(1, 0)), &w) {
		t.Error("the same counter value asked for a second refresh")
	}
}

func TestScanEventsIgnoresTruncatedAndGarbage(t *testing.T) {
	var w resyncWatcher
	if scanEvents([]byte{0xde, 0xad, 0xbe}, &w) {
		t.Error("a partial event asked for a refresh")
	}
	// A rise, then a byte of garbage: the good event still counts, the garbage
	// stops the scan rather than being misread as an event.
	buf := proto.AppendEvent(nil, stats(5, 0))
	buf = append(buf, make([]byte, proto.EventSize)...) // zeroed: bad magic
	if !scanEvents(buf, &w) {
		t.Error("a valid event before garbage was dropped")
	}
	if w.dropped != 5 {
		t.Errorf("watcher recorded dropped=%d, want 5", w.dropped)
	}
}
