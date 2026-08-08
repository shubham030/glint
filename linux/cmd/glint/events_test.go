package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/shubham030/glint/linux/proto"
)

func TestPrintEventsFiltersByMode(t *testing.T) {
	var buf []byte
	for _, e := range []proto.Event{
		{Type: proto.EvtDown, ID: 0, X: 120, Y: 300},
		{Type: proto.EvtStats, X: 7, Y: 2},
		{Type: proto.EvtUp, ID: 0, X: 121, Y: 301},
	} {
		buf = proto.AppendEvent(buf, e)
	}

	var out bytes.Buffer
	printEvents(&out, buf, "touch", false)
	got := out.String()
	if !strings.Contains(got, "down id=0 panel=(120,300)") || !strings.Contains(got, "up id=0") {
		t.Errorf("touch mode printed:\n%s", got)
	}
	if strings.Contains(got, "stats") {
		t.Errorf("touch mode leaked a stats event:\n%s", got)
	}

	out.Reset()
	printEvents(&out, buf, "stats", false)
	if got := out.String(); got != "stats dropped=7 resyncs=2\n" {
		t.Errorf("stats mode printed %q", got)
	}

	out.Reset()
	printEvents(&out, buf, "stats", true)
	if n := strings.Count(out.String(), "\n"); n != 3 {
		t.Errorf("-all printed %d lines, want 3", n)
	}
}

// A transfer holding several queued events must be split at 12-byte
// boundaries, and a trailing partial event ignored.
func TestPrintEventsHandlesPartialTail(t *testing.T) {
	buf := proto.AppendEvent(nil, proto.Event{Type: proto.EvtMove, X: 1, Y: 2})
	buf = append(buf, 0xde, 0xad) // half an event
	var out bytes.Buffer
	printEvents(&out, buf, "touch", false)
	if got := out.String(); got != "move id=0 panel=(1,2)\n" {
		t.Errorf("printed %q", got)
	}
}

func TestLoopStopsAtDeadline(t *testing.T) {
	calls := 0
	start := time.Now()
	if err := loop(context.Background(), 100, 1, func() error {
		calls++
		return nil
	}); err != nil {
		t.Fatalf("loop: %v", err)
	}
	if elapsed := time.Since(start); elapsed < 900*time.Millisecond || elapsed > 3*time.Second {
		t.Errorf("1-second loop ran for %v", elapsed)
	}
	if calls < 10 {
		t.Errorf("100fps for a second made %d calls", calls)
	}
}

func TestLoopStopsOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	if err := loop(ctx, 50, 0, func() error {
		calls++
		return nil
	}); err != nil {
		t.Errorf("cancelling the context must be a clean stop, got %v", err)
	}
	if calls == 0 {
		t.Error("loop never ran the step")
	}
}

func TestLoopPropagatesStepErrors(t *testing.T) {
	want := context.DeadlineExceeded
	if err := loop(context.Background(), 10, 0, func() error { return want }); err != want {
		t.Errorf("got %v, want %v", err, want)
	}
}
