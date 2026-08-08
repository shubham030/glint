//go:build linux

package usbfs

import (
	"os"
	"runtime"
	"syscall"
	"time"
	"unsafe"
)

// Linux ioctl request encoding (asm-generic, which arm and amd64 both use).
const (
	iocWrite = 1
	iocRead  = 2

	iocNRBits   = 8
	iocTypeBits = 8
	iocSizeBits = 14

	iocTypeShift = iocNRBits
	iocSizeShift = iocTypeShift + iocTypeBits
	iocDirShift  = iocSizeShift + iocSizeBits

	usbdevfsType = 'U'
)

func ioc(dir, typ, nr, size uintptr) uintptr {
	return dir<<iocDirShift | size<<iocSizeShift | typ<<iocTypeShift | nr
}

// struct usbdevfs_ctrltransfer. The trailing pointer is why the struct — and
// therefore the ioctl number, which encodes its size — differs between 32-bit
// and 64-bit userspace. Declaring it with a real pointer field lets the Go
// compiler lay it out correctly for both.
type ctrlTransfer struct {
	requestType uint8
	request     uint8
	value       uint16
	index       uint16
	length      uint16
	timeout     uint32
	data        unsafe.Pointer
}

// struct usbdevfs_bulktransfer.
type bulkTransfer struct {
	ep      uint32
	length  uint32
	timeout uint32
	data    unsafe.Pointer
}

var (
	usbdevfsControl          = ioc(iocRead|iocWrite, usbdevfsType, 0, unsafe.Sizeof(ctrlTransfer{}))
	usbdevfsBulk             = ioc(iocRead|iocWrite, usbdevfsType, 2, unsafe.Sizeof(bulkTransfer{}))
	usbdevfsClaimInterface   = ioc(iocRead, usbdevfsType, 15, unsafe.Sizeof(uint32(0)))
	usbdevfsReleaseInterface = ioc(iocRead, usbdevfsType, 16, unsafe.Sizeof(uint32(0)))
)

// ioctl issues one ioctl, retrying interrupted calls. usbfs returns the number
// of bytes transferred, so the raw return value is passed back.
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

// emptyBuffer backs zero-length transfers so the kernel never sees a null
// data pointer.
var emptyBuffer [1]byte

func bufferPointer(b []byte) unsafe.Pointer {
	if len(b) == 0 {
		return unsafe.Pointer(&emptyBuffer[0])
	}
	return unsafe.Pointer(&b[0])
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
