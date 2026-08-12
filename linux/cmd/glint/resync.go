package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync/atomic"

	"github.com/shubham030/glint/linux/proto"
	"github.com/shubham030/glint/linux/usbfs"
)

// resyncWatcher turns the device's STATS counters into a "resend everything"
// decision. The firmware reports cumulative totals in the coordinate fields
// (usb_vendor.c: x = tiles_dropped + seq_gaps, y = resyncs), each saturating
// at 0xFFFF — once a counter pins there, further losses are invisible and no
// more refreshes will be requested.
//
// Kept free of any I/O so the policy can be tested against a sequence of
// events.
type resyncWatcher struct {
	started bool
	dropped uint16
	resyncs uint16
}

// observe reports whether evt means the panel is missing pixels the host
// believes it already sent.
func (w *resyncWatcher) observe(evt proto.Event) bool {
	if evt.Type != proto.EvtStats {
		return false
	}
	if !w.started {
		w.started, w.dropped, w.resyncs = true, evt.X, evt.Y
		// The counters are cumulative, so a non-zero first report means tiles
		// were already lost before this process started watching.
		return evt.X > 0 || evt.Y > 0
	}
	// Any movement counts. A rise is the normal case; a counter going
	// backwards means the device restarted its own bookkeeping, in which case
	// the panel's contents no longer match what our hashes claim either.
	//
	// Resyncs matter as much as drops: the firmware only increments them when
	// it discards bytes hunting for a tile magic or rejects a malformed
	// header, and both mean a tile never reached the panel.
	moved := evt.X != w.dropped || evt.Y != w.resyncs
	w.dropped, w.resyncs = evt.X, evt.Y
	return moved
}

// scanEvents feeds every complete event in buf to w and reports whether any of
// them calls for a full refresh.
func scanEvents(buf []byte, w *resyncWatcher) bool {
	need := false
	for off := 0; off+proto.EventSize <= len(buf); off += proto.EventSize {
		evt, err := proto.ParseEvent(buf[off:])
		if err != nil {
			return need // not event-aligned; wait for the next transfer
		}
		if w.observe(evt) {
			need = true
		}
	}
	return need
}

// watchEvents drains the bulk IN endpoint for the lifetime of ctx and raises
// resync when the device reports losses.
//
// The pipe has to be drained even though nothing here prints the events: the
// device's TX FIFO is small, and once it fills, usb_vendor_send_event() drops
// every later event on the floor — including the STATS reports this loop
// exists to read. Only draining when the user asked for `touch` would leave
// the resync mechanism silently dead in exactly the long-running mode that
// needs it.
//
// It shares the Device with the frame loop: reads and writes are separate
// ioctls on separate endpoints. The TileSender is not concurrency-safe, so
// this only raises a flag — the invalidation happens on the frame goroutine.
func watchEvents(ctx context.Context, dev link, resync *atomic.Bool) {
	buf := make([]byte, max(dev.MaxPacketSize(), proto.EventSize))
	var w resyncWatcher
	for ctx.Err() == nil {
		n, err := dev.BulkRead(ctx, buf)
		switch {
		case errors.Is(err, usbfs.ErrTimeout):
			continue // an idle device is silent, which is the common case
		case err != nil:
			if ctx.Err() == nil {
				fmt.Fprintf(os.Stderr, "glint: event reader stopped: %v\n", err)
			}
			return
		}
		if scanEvents(buf[:n], &w) {
			resync.Store(true)
		}
	}
}
