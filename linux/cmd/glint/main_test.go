package main

import (
	"strings"
	"testing"

	"github.com/shubham030/glint/linux/proto"
	"github.com/shubham030/glint/linux/usbfs"
)

func TestRunRejectsUnknownModeBeforeOpeningTheDevice(t *testing.T) {
	err := run([]string{"barz"})
	if err == nil || !strings.Contains(err.Error(), "unknown mode") {
		t.Errorf(`run("barz") = %v, want an "unknown mode" error`, err)
	}
	if err := run(nil); err == nil {
		t.Error("run with no arguments should fail")
	}
	if err := run([]string{"help"}); err != nil {
		t.Errorf("run(help) = %v, want nil", err)
	}
}

// The usage text and the accepted verbs must not drift apart.
func TestUsageListsEveryMode(t *testing.T) {
	for mode := range modes {
		if !strings.Contains(usage, "\n  "+mode) {
			t.Errorf("mode %q is accepted but missing from the usage text", mode)
		}
	}
}

func TestRunControlValidatesArguments(t *testing.T) {
	dev := usbLink{&usbfs.Device{}} // never reached by the rejected cases
	for _, args := range [][]string{{}, {"1", "2"}, {"nope"}, {"-1"}, {"256"}} {
		err := runControl(dev, proto.CmdBacklight, args, 255, "glint backlight <0-255>")
		if err == nil || !strings.HasPrefix(err.Error(), "usage:") {
			t.Errorf("backlight %v = %v, want a usage error", args, err)
		}
	}
	if err := runControl(dev, proto.CmdSleep, []string{"2"}, 1, "glint sleep <0|1>"); err == nil {
		t.Error("sleep 2 should be rejected")
	}
	// A valid argument gets as far as the transport, which has no device.
	err := runControl(dev, proto.CmdBacklight, []string{"128"}, 255, "glint backlight <0-255>")
	if err == nil || strings.HasPrefix(err.Error(), "usage:") {
		t.Errorf("backlight 128 = %v, want a transport error", err)
	}
}

func TestTakeTransportFlagsPullsThemOutOfTheModeArguments(t *testing.T) {
	for _, tc := range []struct {
		args []string
		host string
		port int
		rest []string
	}{
		{[]string{"-seconds", "5"}, "", defaultNetPort, []string{"-seconds", "5"}},
		{[]string{"-net", "glint-335b.local"}, "glint-335b.local", defaultNetPort, nil},
		{[]string{"-net=1.2.3.4", "-fill"}, "1.2.3.4", defaultNetPort, []string{"-fill"}},
		{[]string{"-net"}, "auto", defaultNetPort, nil},
		{[]string{"-fill", "-net", "-landscape"}, "auto", defaultNetPort, []string{"-fill", "-landscape"}},
		{[]string{"-net", "pi.local", "-port", "9000"}, "pi.local", 9000, nil},
	} {
		host, port, rest, err := takeTransportFlags(tc.args)
		if err != nil {
			t.Errorf("%v: %v", tc.args, err)
			continue
		}
		if host != tc.host || port != tc.port {
			t.Errorf("%v -> host %q port %d, want %q %d", tc.args, host, port, tc.host, tc.port)
		}
		if strings.Join(rest, " ") != strings.Join(tc.rest, " ") {
			t.Errorf("%v -> rest %v, want %v", tc.args, rest, tc.rest)
		}
	}

	if _, _, _, err := takeTransportFlags([]string{"-port"}); err == nil {
		t.Error("-port with no number should be rejected")
	}
}
