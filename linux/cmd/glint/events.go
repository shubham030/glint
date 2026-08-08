package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/shubham030/glint/linux/proto"
	"github.com/shubham030/glint/linux/usbfs"
)

// runEvents drains the bulk IN endpoint and prints the events the mode cares
// about: "touch" for calibration, "stats" for the device's own counters.
func runEvents(ctx context.Context, dev *usbfs.Device, mode string, args []string) error {
	fs := newFlags(mode)
	all := fs.Bool("all", false, "print every event type, not just this mode's")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if mode == "touch" {
		fmt.Println("tap the panel — Ctrl-C to stop")
	} else {
		fmt.Println("waiting for STATS events — an idle device stays silent")
	}

	// Read a whole max-packet transfer: the device may have several 12-byte
	// events queued, and asking for fewer bytes than it sends is an overflow.
	buf := make([]byte, max(dev.MaxPacketSize(), proto.EventSize))
	for {
		if ctx.Err() != nil {
			return nil
		}
		n, err := dev.BulkRead(ctx, buf)
		switch {
		case errors.Is(err, usbfs.ErrTimeout):
			continue // no events pending, which is the common case
		case errors.Is(err, context.Canceled):
			return nil
		case err != nil:
			return err
		}
		printEvents(os.Stdout, buf[:n], mode, *all)
	}
}

func printEvents(w io.Writer, buf []byte, mode string, all bool) {
	for off := 0; off+proto.EventSize <= len(buf); off += proto.EventSize {
		evt, err := proto.ParseEvent(buf[off:])
		if err != nil {
			fmt.Fprintf(os.Stderr, "glint: %v\n", err)
			return // a bad magic means the stream is not event-aligned
		}
		if !all && !wanted(evt.Type, mode) {
			continue
		}
		fmt.Fprintln(w, describe(evt))
	}
}

func wanted(t proto.EventType, mode string) bool {
	if mode == "stats" {
		return t == proto.EvtStats
	}
	return t == proto.EvtDown || t == proto.EvtMove || t == proto.EvtUp
}

// describe formats one event. STATS reuses the coordinate fields for counters
// (firmware/main/usb_vendor.c: x = dropped tiles + sequence gaps, y = stream
// resyncs).
func describe(evt proto.Event) string {
	if evt.Type == proto.EvtStats {
		return fmt.Sprintf("stats dropped=%d resyncs=%d", evt.X, evt.Y)
	}
	return fmt.Sprintf("%s id=%d panel=(%d,%d)", evt.Type, evt.ID, evt.X, evt.Y)
}
