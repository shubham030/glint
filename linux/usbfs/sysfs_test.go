package usbfs

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// Discovery walks a real sysfs on a device, which cannot be exercised in CI or
// on a dev machine. These tests point it at a synthetic tree instead, so the
// parsing, the interface-directory skipping and the endpoint/speed fallbacks are
// covered without hardware.

type fakeDevice struct {
	name     string // sysfs directory, e.g. "1-1.4"
	vid, pid string // hex, as sysfs reports them
	busnum   string
	devnum   string
	speed    string
	maxPkt   string // hex wMaxPacketSize, "" to omit the endpoint entirely
}

func writeSysfs(t *testing.T, devs []fakeDevice, extraDirs ...string) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "devices")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}

	write := func(dir, name, val string) {
		t.Helper()
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name), []byte(val+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	for _, d := range devs {
		dir := filepath.Join(root, d.name)
		if d.vid != "" {
			write(dir, "idVendor", d.vid)
		}
		if d.pid != "" {
			write(dir, "idProduct", d.pid)
		}
		if d.busnum != "" {
			write(dir, "busnum", d.busnum)
		}
		if d.devnum != "" {
			write(dir, "devnum", d.devnum)
		}
		if d.speed != "" {
			write(dir, "speed", d.speed)
		}
		if d.maxPkt != "" {
			write(filepath.Join(dir, d.name+":1.0", "ep_01"), "wMaxPacketSize", d.maxPkt)
		}
	}
	// Interface directories and the like, which carry no idVendor.
	for _, extra := range extraDirs {
		if err := os.MkdirAll(filepath.Join(root, extra), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// useTree points discovery at a synthetic sysfs and a fake /dev root.
func useTree(t *testing.T, root string) string {
	t.Helper()
	devRoot := filepath.Join(t.TempDir(), "bus", "usb")
	oldSys, oldDev := sysfsUSBDevices, devBusUSB
	sysfsUSBDevices, devBusUSB = root, devRoot
	t.Cleanup(func() { sysfsUSBDevices, devBusUSB = oldSys, oldDev })
	return devRoot
}

func TestFindLocatesThePanelAmongOtherDevices(t *testing.T) {
	root := writeSysfs(t, []fakeDevice{
		{name: "usb1", vid: "1d6b", pid: "0002", busnum: "1", devnum: "1", speed: "480"},
		{name: "1-1", vid: "05e3", pid: "0608", busnum: "1", devnum: "2", speed: "480"},
		{name: "1-1.4", vid: "cafe", pid: "4010", busnum: "1", devnum: "7",
			speed: "480", maxPkt: "0200"},
	}, "1-1.4:1.0", "usb1:1.0")
	devRoot := useTree(t, root)

	got, err := find(0xCAFE, 0x4010)
	if err != nil {
		t.Fatalf("find: %v", err)
	}
	if want := filepath.Join(devRoot, "001", "007"); got.path != want {
		t.Errorf("path = %q, want %q", got.path, want)
	}
	if got.maxPacket != 512 {
		t.Errorf("maxPacket = %d, want 512 from the endpoint descriptor", got.maxPacket)
	}
	if got.speed != "480" {
		t.Errorf("speed = %q, want 480", got.speed)
	}
}

func TestFindReportsNotFoundWhenAbsent(t *testing.T) {
	root := writeSysfs(t, []fakeDevice{
		{name: "1-1", vid: "05e3", pid: "0608", busnum: "1", devnum: "2"},
	})
	useTree(t, root)

	if _, err := find(0xCAFE, 0x4010); !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

func TestFindFallsBackToSpeedWithoutAnEndpointDescriptor(t *testing.T) {
	for _, tc := range []struct {
		speed string
		want  int
	}{
		{"480", 512}, // high speed
		{"12", 64},   // full speed
		{"", 64},     // unknown: the conservative choice
	} {
		root := writeSysfs(t, []fakeDevice{
			{name: "1-1", vid: "cafe", pid: "4010", busnum: "1", devnum: "3",
				speed: tc.speed},
		})
		useTree(t, root)

		got, err := find(0xCAFE, 0x4010)
		if err != nil {
			t.Fatalf("speed %q: find: %v", tc.speed, err)
		}
		if got.maxPacket != tc.want {
			t.Errorf("speed %q: maxPacket = %d, want %d",
				tc.speed, got.maxPacket, tc.want)
		}
	}
}

// A wMaxPacketSize with high-bandwidth bits set must yield only the size.
func TestFindMasksHighBandwidthBits(t *testing.T) {
	root := writeSysfs(t, []fakeDevice{
		{name: "1-1", vid: "cafe", pid: "4010", busnum: "1", devnum: "3",
			speed: "480", maxPkt: "1200"}, // 0x1200: 2 transactions + 0x200
	})
	useTree(t, root)

	got, err := find(0xCAFE, 0x4010)
	if err != nil {
		t.Fatal(err)
	}
	if got.maxPacket != 512 {
		t.Errorf("maxPacket = %d, want 512 (size bits only)", got.maxPacket)
	}
}

// Entries missing busnum/devnum are unusable and must not be returned as a
// half-built path; discovery should keep looking.
func TestFindSkipsIncompleteEntriesAndKeepsScanning(t *testing.T) {
	root := writeSysfs(t, []fakeDevice{
		{name: "1-1", vid: "cafe", pid: "4010"}, // no busnum/devnum
		{name: "1-2", vid: "cafe", pid: "4010", busnum: "2", devnum: "9",
			speed: "480", maxPkt: "0200"},
	})
	devRoot := useTree(t, root)

	got, err := find(0xCAFE, 0x4010)
	if err != nil {
		t.Fatalf("find: %v", err)
	}
	if want := filepath.Join(devRoot, "002", "009"); got.path != want {
		t.Errorf("path = %q, want the complete entry %q", got.path, want)
	}
}

func TestFindIgnoresMalformedAttributes(t *testing.T) {
	root := writeSysfs(t, []fakeDevice{
		{name: "1-1", vid: "zzzz", pid: "4010", busnum: "1", devnum: "2"},
		{name: "1-2", vid: "cafe", pid: "4010", busnum: "notanumber", devnum: "2"},
	})
	useTree(t, root)

	if _, err := find(0xCAFE, 0x4010); !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

func TestFindErrorsWhenSysfsIsMissing(t *testing.T) {
	useTree(t, filepath.Join(t.TempDir(), "nope"))

	_, err := find(0xCAFE, 0x4010)
	if err == nil {
		t.Fatal("want an error when sysfs cannot be read")
	}
	if errors.Is(err, ErrNotFound) {
		t.Error("an unreadable sysfs is a scan failure, not a missing device")
	}
}
