//go:build linux

package usbfs

import (
	"os"
	"runtime"
	"syscall"
	"time"
	"unsafe"
)

// ioctl issues one ioctl, retrying if a signal interrupts it. usbfs answers
// transfer ioctls with the number of bytes moved, so the raw return value is
// passed back to the caller.
func ioctl(f *os.File, request uintptr, arg unsafe.Pointer) (int, error) {
	if f == nil {
		return 0, os.ErrClosed
	}
	for {
		r, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), request, uintptr(arg))
		switch errno {
		case 0:
			return int(r), nil
		case syscall.EINTR:
			continue
		case syscall.ETIMEDOUT:
			return 0, ErrTimeout
		default:
			return 0, errno
		}
	}
}

func claimInterface(f *os.File, iface uint32) error {
	_, err := ioctl(f, usbdevfsClaimInterface, unsafe.Pointer(&iface))
	return err
}

func releaseInterface(f *os.File, iface uint32) error {
	_, err := ioctl(f, usbdevfsReleaseInterface, unsafe.Pointer(&iface))
	return err
}

func controlXfer(f *os.File, reqType, request uint8, value, index uint16, buf []byte, timeout time.Duration) (int, error) {
	ct := ctrlTransfer{
		requestType: reqType,
		request:     request,
		value:       value,
		index:       index,
		length:      uint16(len(buf)),
		timeout:     uint32(timeout.Milliseconds()),
		data:        bufferPointer(buf),
	}
	n, err := ioctl(f, usbdevfsControl, unsafe.Pointer(&ct))
	runtime.KeepAlive(buf)
	return n, err
}

func bulkXfer(f *os.File, endpoint uint8, buf []byte, timeout time.Duration) (int, error) {
	bt := bulkTransfer{
		ep:      uint32(endpoint),
		length:  uint32(len(buf)),
		timeout: uint32(timeout.Milliseconds()),
		data:    bufferPointer(buf),
	}
	n, err := ioctl(f, usbdevfsBulk, unsafe.Pointer(&bt))
	runtime.KeepAlive(buf)
	return n, err
}
