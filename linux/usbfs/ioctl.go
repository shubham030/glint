package usbfs

import "unsafe"

// Linux ioctl request encoding (the asm-generic scheme, which both arm and
// amd64 use). Kept out of the _linux file so the numbers can be unit-tested on
// a developer's machine, where there is no device to try them against.
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
// with it the ioctl number, which encodes the struct size — differs between
// 32-bit and 64-bit userspace: 16 bytes on armv6, 24 on amd64. Declaring a
// real pointer field lets the compiler lay it out correctly for both instead
// of hardcoding offsets.
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

// emptyBuffer backs zero-length transfers so the kernel never sees a null data
// pointer.
var emptyBuffer [1]byte

func bufferPointer(b []byte) unsafe.Pointer {
	if len(b) == 0 {
		return unsafe.Pointer(&emptyBuffer[0])
	}
	return unsafe.Pointer(&b[0])
}
