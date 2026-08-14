
package usbfs

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// sysfsUSBDevices holds one directory per USB device and per interface; only
// the device directories carry idVendor/idProduct.
// Overridable so discovery can be tested against a synthetic tree.
var (
	sysfsUSBDevices = "/sys/bus/usb/devices"
	devBusUSB       = "/dev/bus/usb"
)

// find locates the first device matching vid:pid and works out how to reach it.
func find(vid, pid uint16) (deviceInfo, error) {
	entries, err := os.ReadDir(sysfsUSBDevices)
	if err != nil {
		return deviceInfo{}, fmt.Errorf("scan %s: %w", sysfsUSBDevices, err)
	}
	for _, e := range entries {
		dir := filepath.Join(sysfsUSBDevices, e.Name())
		if !idsMatch(dir, vid, pid) {
			continue
		}
		bus, err := readUint(dir, "busnum", 10)
		if err != nil {
			continue
		}
		dev, err := readUint(dir, "devnum", 10)
		if err != nil {
			continue
		}
		speed, _ := readAttr(dir, "speed")
		return deviceInfo{
			path:      filepath.Join(devBusUSB, fmt.Sprintf("%03d", bus), fmt.Sprintf("%03d", dev)),
			speed:     speed,
			maxPacket: bulkPacketSize(dir, e.Name(), speed),
		}, nil
	}
	return deviceInfo{}, fmt.Errorf("%04x:%04x: %w", vid, pid, ErrNotFound)
}

func idsMatch(dir string, vid, pid uint16) bool {
	gotVID, err := readUint(dir, "idVendor", 16)
	if err != nil {
		return false // an interface directory, or one this process may not read
	}
	gotPID, err := readUint(dir, "idProduct", 16)
	return err == nil && uint16(gotVID) == vid && uint16(gotPID) == pid
}

// bulkPacketSize prefers the endpoint descriptor the kernel already parsed and
// falls back to what the link speed implies.
func bulkPacketSize(dir, name, speed string) int {
	epDir := filepath.Join(dir, name+":1.0", fmt.Sprintf("ep_%02x", 0x01))
	if v, err := readUint(epDir, "wMaxPacketSize", 16); err == nil {
		// Bits 0..10 are the size; the rest encode high-bandwidth transactions.
		if size := int(v & 0x7ff); size > 0 {
			return size
		}
	}
	return packetForSpeed(speed)
}

func readAttr(dir, name string) (string, error) {
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

func readUint(dir, name string, base int) (uint64, error) {
	s, err := readAttr(dir, name)
	if err != nil {
		return 0, err
	}
	v, err := strconv.ParseUint(s, base, 32)
	if err != nil {
		return 0, fmt.Errorf("%s/%s = %q: %w", dir, name, s, err)
	}
	return v, nil
}
