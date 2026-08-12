// Command glint drives a glint panel from Linux over usbfs — no libusb, no
// cgo, no X server. See linux/README.md for build and udev setup.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/shubham030/glint/linux/mdns"
	"github.com/shubham030/glint/linux/proto"
)

const usage = `usage: glint <mode> [flags]

  hello                                  handshake and print the panel's geometry
  bars [-seconds N] [-fps N]             animated colour bars (transport test)
  image [-fill] [-landscape] <path>      show a PNG or JPEG
  fb [-dev /dev/fb0] [-fps N] [-native]  mirror a Linux framebuffer
     [-fill] [-landscape] [-seconds N]
  stats                                  print STATS events from the device
  touch                                  print touch events in panel coords
  backlight <0-255>                      set the backlight
  sleep <0|1>                            panel off / on
  fbinfo [-dev /dev/fb0]                 print framebuffer geometry (no panel needed)
  panels                                 list panels on the network (no panel needed)

Any mode takes -net <host|auto> to use Wi-Fi instead of USB, and -port N.
Streaming modes run until Ctrl-C unless -seconds is given.
`

func main() {
	if err := run(os.Args[1:]); err != nil {
		if errors.Is(err, context.Canceled) {
			return // Ctrl-C is a clean stop
		}
		fmt.Fprintf(os.Stderr, "glint: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		fmt.Fprint(os.Stderr, usage)
		return errors.New("no mode given")
	}
	mode, rest := args[0], args[1:]
	if mode == "help" || mode == "-h" || mode == "--help" {
		fmt.Print(usage)
		return nil
	}

	// -net/-port choose the transport for every mode, so they are pulled out
	// before the per-mode flag set sees them.
	netHost, netPort, rest, err := takeTransportFlags(rest)
	if err != nil {
		return err
	}
	// Reject a typo before opening the device, so it reports the typo rather
	// than "no glint device on the USB bus".
	if !modes[mode] {
		fmt.Fprint(os.Stderr, usage)
		return fmt.Errorf("unknown mode %q", mode)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Reports on the framebuffer without needing the panel, which is the only
	// way to check the fbdev ioctls and the reported stride on a machine the
	// panel is not plugged into.
	if mode == "fbinfo" {
		return runFramebufferInfo(rest)
	}

	// Discovery needs no panel either, and it is the answer to "what is the
	// name of my board".
	if mode == "panels" {
		return runPanels()
	}

	dev, err := openLink(netHost, netPort)
	if err != nil {
		return err
	}
	defer dev.Close()

	hello, err := handshake(dev)
	if err != nil {
		return err
	}
	fmt.Printf("%s, %s\n", hello, dev.Describe())

	return dispatch(ctx, dev, hello, mode, rest)
}

// modes is the set of accepted verbs, kept beside dispatch.
var modes = map[string]bool{
	"hello": true, "bars": true, "image": true, "fb": true,
	"stats": true, "touch": true, "backlight": true, "sleep": true,
	"fbinfo": true, "panels": true,
}

// takeTransportFlags removes -net/-port from args and returns their values.
// A bare -net (or -net auto) means "find a panel on the network".
func takeTransportFlags(args []string) (host string, port int, rest []string, err error) {
	port = defaultNetPort
	for i := 0; i < len(args); i++ {
		a := args[i]
		name, value, hasValue := strings.Cut(strings.TrimPrefix(strings.TrimPrefix(a, "-"), "-"), "=")
		if !strings.HasPrefix(a, "-") || (name != "net" && name != "port") {
			rest = append(rest, a)
			continue
		}
		if !hasValue {
			// A following word is the value unless it is the next flag; a bare
			// -net at the end of the line is legal and means auto.
			if i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") {
				value = args[i+1]
				i++
			} else if name == "net" {
				value = "auto"
			} else {
				return "", 0, nil, errors.New("-port needs a number")
			}
		}
		if name == "port" {
			if port, err = strconv.Atoi(value); err != nil {
				return "", 0, nil, fmt.Errorf("-port %q: not a number", value)
			}
			continue
		}
		host = value
	}
	return host, port, rest, nil
}

// runPanels lists the panels advertising themselves on this network.
func runPanels() error {
	names, err := mdns.Browse(mdns.GlintService, 2*time.Second)
	if err != nil && !errors.Is(err, mdns.ErrNoAnswer) {
		return err
	}
	if len(names) == 0 {
		fmt.Println("no panels are advertising themselves on this network")
		return nil
	}
	for _, n := range names {
		line := fmt.Sprintf("-net %s.local", n)
		if ip, rerr := mdns.Resolve(n+".local", 2*time.Second); rerr == nil {
			line += fmt.Sprintf("   (%s)", ip)
		} else {
			line += "   (advertised but not answering — stale entry?)"
		}
		fmt.Println(line)
	}
	return nil
}

func dispatch(ctx context.Context, dev link, hello proto.Hello, mode string, args []string) error {
	switch mode {
	case "hello":
		return nil
	case "bars":
		return runBars(ctx, dev, hello, args)
	case "image":
		return runImage(ctx, dev, hello, args)
	case "fb":
		return runFramebuffer(ctx, dev, hello, args)
	case "stats", "touch":
		return runEvents(ctx, dev, mode, args)
	case "backlight":
		return runControl(dev, proto.CmdBacklight, args, 255, "glint backlight <0-255>")
	case "sleep":
		return runControl(dev, proto.CmdSleep, args, 1, "glint sleep <0|1>")
	default:
		fmt.Fprint(os.Stderr, usage)
		return fmt.Errorf("unknown mode %q", mode)
	}
}

// handshake performs the CmdHello control read every mode starts with.
func handshake(dev link) (proto.Hello, error) {
	buf := make([]byte, proto.HelloSize)
	n, err := dev.ControlRead(proto.CmdHello, 0, buf)
	if err != nil {
		return proto.Hello{}, err
	}
	hello, err := proto.ParseHello(buf[:n])
	if err != nil {
		return proto.Hello{}, fmt.Errorf("bad HELLO reply: %w", err)
	}
	return hello, nil
}

// runControl handles the one-argument control writes.
func runControl(dev link, request uint8, args []string, maxValue int, use string) error {
	if len(args) != 1 {
		return errors.New("usage: " + use)
	}
	v, err := strconv.Atoi(args[0])
	if err != nil || v < 0 || v > maxValue {
		return errors.New("usage: " + use)
	}
	return dev.ControlWrite(request, uint16(v))
}

// newFlags builds a flag set that reports errors instead of exiting.
func newFlags(mode string) *flag.FlagSet {
	fs := flag.NewFlagSet(mode, flag.ContinueOnError)
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: glint %s [flags]\n", mode)
		fs.PrintDefaults()
	}
	return fs
}
