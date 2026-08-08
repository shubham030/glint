package usbfs

import (
	"context"
	"errors"
	"testing"
)

func TestSpeedNames(t *testing.T) {
	for speed, want := range map[string]string{
		"1.5":   "low",
		"12":    "full",
		"480":   "high",
		"5000":  "super",
		"10000": "super",
		"":      "unknown",
		"junk":  "unknown",
	} {
		if got := speedName(speed); got != want {
			t.Errorf("speedName(%q) = %q, want %q", speed, got, want)
		}
	}
}

// The ZLP rule hangs off this: high speed bulk is 512 bytes, full speed 64.
func TestPacketForSpeed(t *testing.T) {
	for speed, want := range map[string]int{
		"1.5": 64, "12": 64, "480": 512, "5000": 1024, "": 64,
	} {
		if got := packetForSpeed(speed); got != want {
			t.Errorf("packetForSpeed(%q) = %d, want %d", speed, got, want)
		}
	}
}

func TestOpenFailsWithoutDevice(t *testing.T) {
	// On darwin this hits the stub; on a Linux box with no panel attached it
	// hits the sysfs walk. Either way Open must fail rather than return a
	// half-built Device.
	d, err := Open(0xdead, 0xbeef)
	if err == nil {
		d.Close()
		t.Fatal("Open succeeded for a device that cannot exist")
	}
	if !errors.Is(err, ErrUnsupported) && !errors.Is(err, ErrNotFound) {
		t.Logf("Open returned %v", err) // permission or sysfs shape, still a failure
	}
}

func TestClosedDeviceDoesNotPanic(t *testing.T) {
	d := &Device{}
	if err := d.Close(); err != nil {
		t.Errorf("closing a zero Device: %v", err)
	}
	if err := d.BulkWrite(context.Background(), []byte{1, 2, 3}); err == nil {
		t.Error("BulkWrite on a closed device should fail")
	}
}

func TestBulkWriteHonoursCancelledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	d := &Device{}
	if err := d.BulkWrite(ctx, []byte{1}); !errors.Is(err, context.Canceled) {
		t.Errorf("got %v, want context.Canceled", err)
	}
	if _, err := d.BulkRead(ctx, make([]byte, 12)); !errors.Is(err, context.Canceled) {
		t.Errorf("got %v, want context.Canceled", err)
	}
}
