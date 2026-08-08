//go:build !linux

package usbfs

import (
	"os"
	"time"
)

// Stubs so the CLI and the pure packages still build (and test) on a
// developer's machine. Every entry point fails the same way.

func find(uint16, uint16) (deviceInfo, error) { return deviceInfo{}, ErrUnsupported }

func claimInterface(*os.File, uint32) error { return ErrUnsupported }

func releaseInterface(*os.File, uint32) error { return ErrUnsupported }

func controlXfer(*os.File, uint8, uint8, uint16, uint16, []byte, time.Duration) (int, error) {
	return 0, ErrUnsupported
}

func bulkXfer(*os.File, uint8, []byte, time.Duration) (int, error) {
	return 0, ErrUnsupported
}
