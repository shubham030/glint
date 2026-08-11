package main

import (
	"fmt"

	"github.com/shubham030/glint/linux/fb"
)

// runFramebufferInfo opens a framebuffer, prints what the kernel reports and
// reads one frame — no USB involved.
//
// This exists because `fb` mode receives an already-open panel, so the fbdev
// ioctls are unreachable on a machine the panel is not attached to. The struct
// layouts behind FBIOGET_VSCREENINFO/FBIOGET_FSCREENINFO are reasoned from the
// kernel headers rather than confirmed against a running kernel, and a wrong
// `fb_fix_screeninfo` padding shows up as a plausible-looking stride that
// skews every frame. Comparing this output with `fbset -i` settles it.
func runFramebufferInfo(args []string) error {
	fs := newFlags("fbinfo")
	path := fs.String("dev", fb.DefaultDevice, "framebuffer device")
	if err := fs.Parse(args); err != nil {
		return err
	}

	dev, err := fb.Open(*path)
	if err != nil {
		return fmt.Errorf("open %s: %w", *path, err)
	}
	defer dev.Close()

	info := dev.Info()
	fmt.Printf("%s: %s\n", *path, info)
	fmt.Printf("  %d bytes per frame (%d rows x %d stride)\n",
		info.Stride*info.Height, info.Height, info.Stride)

	if err := info.Validate(); err != nil {
		return fmt.Errorf("unusable mode: %w", err)
	}

	frame, err := dev.Frame()
	if err != nil {
		return fmt.Errorf("read a frame: %w", err)
	}
	if want := info.Stride * info.Height; len(frame) != want {
		return fmt.Errorf("read %d bytes, expected %d", len(frame), want)
	}
	fmt.Printf("  read %d bytes OK — compare the geometry above with `fbset -i`\n",
		len(frame))
	return nil
}
