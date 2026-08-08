package usbfs

import (
	"testing"
	"unsafe"
)

// The request numbers encode the struct size, so they differ between armv6 and
// amd64. These are the values from the kernel's <linux/usbdevice_fs.h> on both
// widths; getting them wrong is an EINVAL nobody can debug from a Pi.
func TestIoctlEncoding(t *testing.T) {
	for _, tc := range []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"USBDEVFS_CONTROL 64-bit", ioc(iocRead|iocWrite, 'U', 0, 24), 0xC0185500},
		{"USBDEVFS_CONTROL 32-bit", ioc(iocRead|iocWrite, 'U', 0, 16), 0xC0105500},
		{"USBDEVFS_BULK 64-bit", ioc(iocRead|iocWrite, 'U', 2, 24), 0xC0185502},
		{"USBDEVFS_BULK 32-bit", ioc(iocRead|iocWrite, 'U', 2, 16), 0xC0105502},
		{"USBDEVFS_CLAIMINTERFACE", ioc(iocRead, 'U', 15, 4), 0x8004550F},
		{"USBDEVFS_RELEASEINTERFACE", ioc(iocRead, 'U', 16, 4), 0x80045510},
	} {
		if tc.got != tc.want {
			t.Errorf("%s = %#x, want %#x", tc.name, tc.got, tc.want)
		}
	}
}

// The transfer structs must match the kernel's layout for the pointer width
// they are compiled for.
func TestTransferStructLayout(t *testing.T) {
	ptr := unsafe.Sizeof(uintptr(0))
	wantCtrl, wantBulk, wantDataOffset := uintptr(16), uintptr(16), uintptr(12)
	if ptr == 8 {
		wantCtrl, wantBulk, wantDataOffset = 24, 24, 16
	}
	if got := unsafe.Sizeof(ctrlTransfer{}); got != wantCtrl {
		t.Errorf("sizeof(usbdevfs_ctrltransfer) = %d, want %d on a %d-byte-pointer platform", got, wantCtrl, ptr)
	}
	if got := unsafe.Sizeof(bulkTransfer{}); got != wantBulk {
		t.Errorf("sizeof(usbdevfs_bulktransfer) = %d, want %d", got, wantBulk)
	}
	if got := unsafe.Offsetof(ctrlTransfer{}.data); got != wantDataOffset {
		t.Errorf("ctrltransfer.data at offset %d, want %d", got, wantDataOffset)
	}
	if got := unsafe.Offsetof(bulkTransfer{}.data); got != wantDataOffset {
		t.Errorf("bulktransfer.data at offset %d, want %d", got, wantDataOffset)
	}
	// Field offsets the kernel reads directly.
	if got := unsafe.Offsetof(ctrlTransfer{}.timeout); got != 8 {
		t.Errorf("ctrltransfer.timeout at offset %d, want 8", got)
	}
	if got := unsafe.Offsetof(bulkTransfer{}.timeout); got != 8 {
		t.Errorf("bulktransfer.timeout at offset %d, want 8", got)
	}
}

// The armv6 layout cannot be observed from a 64-bit host, so model it: same
// fields, a 4-byte pointer. If the compiler pads these the way the kernel's
// 32-bit structs are packed, the real structs get it right on the Pi too.
type (
	ctrlTransfer32 struct {
		requestType uint8
		request     uint8
		value       uint16
		index       uint16
		length      uint16
		timeout     uint32
		data        uint32
	}
	bulkTransfer32 struct {
		ep      uint32
		length  uint32
		timeout uint32
		data    uint32
	}
)

func TestThirtyTwoBitLayout(t *testing.T) {
	if got := unsafe.Sizeof(ctrlTransfer32{}); got != 16 {
		t.Errorf("32-bit ctrltransfer is %d bytes, want 16", got)
	}
	if got := unsafe.Offsetof(ctrlTransfer32{}.data); got != 12 {
		t.Errorf("32-bit ctrltransfer.data at %d, want 12", got)
	}
	if got := unsafe.Sizeof(bulkTransfer32{}); got != 16 {
		t.Errorf("32-bit bulktransfer is %d bytes, want 16", got)
	}
	if got := unsafe.Offsetof(bulkTransfer32{}.data); got != 12 {
		t.Errorf("32-bit bulktransfer.data at %d, want 12", got)
	}
}

// The computed constants must agree with the encoding for this build's width.
func TestComputedRequestNumbers(t *testing.T) {
	want := map[string]uintptr{"control": 0xC0185500, "bulk": 0xC0185502}
	if unsafe.Sizeof(uintptr(0)) == 4 {
		want = map[string]uintptr{"control": 0xC0105500, "bulk": 0xC0105502}
	}
	if usbdevfsControl != want["control"] {
		t.Errorf("usbdevfsControl = %#x, want %#x", usbdevfsControl, want["control"])
	}
	if usbdevfsBulk != want["bulk"] {
		t.Errorf("usbdevfsBulk = %#x, want %#x", usbdevfsBulk, want["bulk"])
	}
	if usbdevfsClaimInterface != 0x8004550F || usbdevfsReleaseInterface != 0x80045510 {
		t.Errorf("claim/release = %#x/%#x", usbdevfsClaimInterface, usbdevfsReleaseInterface)
	}
}

func TestBufferPointerNeverNull(t *testing.T) {
	if bufferPointer(nil) == nil {
		t.Error("zero-length transfer would hand the kernel a null pointer")
	}
	b := []byte{1, 2, 3}
	if bufferPointer(b) != unsafe.Pointer(&b[0]) {
		t.Error("bufferPointer did not point at the buffer")
	}
}
