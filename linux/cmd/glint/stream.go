package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"image"
	"sync/atomic"
	"time"

	"github.com/shubham030/glint/linux/fb"
	"github.com/shubham030/glint/linux/proto"
	"github.com/shubham030/glint/linux/render"
)

// streamFlags are shared by every mode that pushes frames.
type streamFlags struct {
	fps       *int
	seconds   *int
	fill      *bool
	landscape *bool
	full      *bool
}

func (f streamFlags) mode() render.FitMode {
	if f.fill != nil && *f.fill {
		return render.Fill
	}
	return render.Fit
}

func addStreamFlags(fs *flag.FlagSet, defaultFPS int) streamFlags {
	return streamFlags{
		fps:       fs.Int("fps", defaultFPS, "frame rate cap"),
		seconds:   fs.Int("seconds", 0, "stop after N seconds (0 = until Ctrl-C)"),
		fill:      fs.Bool("fill", false, "cover the panel, cropping the overflow"),
		landscape: fs.Bool("landscape", false, "rotate for a sideways-mounted panel"),
		full:      fs.Bool("full", false, "send whole frames, no dirty-rect tiling"),
	}
}

func runBars(ctx context.Context, dev link, hello proto.Hello, args []string) error {
	fs := newFlags("bars")
	fps := fs.Int("fps", 10, "frame rate cap")
	seconds := fs.Int("seconds", 10, "stop after N seconds (0 = until Ctrl-C)")
	full := fs.Bool("full", false, "send whole frames, no dirty-rect tiling")
	if err := fs.Parse(args); err != nil {
		return err
	}

	sender, err := proto.NewTileSender(hello, proto.Options{})
	if err != nil {
		return err
	}
	if err := dev.ControlWrite(proto.CmdReset, 0); err != nil {
		return err
	}
	fmt.Printf("bars: %s\n", sender.Grid())

	m := newMeter()
	phase := 0
	err = loop(ctx, *fps, *seconds, func() error {
		px := render.ColorBars(hello.PanelW, hello.PanelH, phase)
		phase += 4
		/* Tiling and RLE make a frame rate say more about the content than the
		 * link, so -full measures the link itself: every frame whole. */
		st, serr := sender.Send(ctx, dev, px, *full)
		m.add(st)
		return serr
	})
	fmt.Println(m.summary())
	return err
}

func runImage(ctx context.Context, dev link, hello proto.Hello, args []string) error {
	fs := newFlags("image")
	fill := fs.Bool("fill", false, "cover the panel, cropping the overflow")
	landscape := fs.Bool("landscape", false, "rotate for a sideways-mounted panel")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: glint image [-fill] [-landscape] <path>")
	}
	path := fs.Arg(0)

	img, err := render.LoadImage(path)
	if err != nil {
		return err
	}
	mode := render.Fit
	if *fill {
		mode = render.Fill
	}
	px, err := render.RenderImage(img, hello.PanelW, hello.PanelH, mode, *landscape)
	if err != nil {
		return err
	}

	sender, err := proto.NewTileSender(hello, proto.Options{})
	if err != nil {
		return err
	}
	if err := dev.ControlWrite(proto.CmdReset, 0); err != nil {
		return err
	}
	st, err := sender.Send(ctx, dev, px, true)
	if err != nil {
		return err
	}
	fmt.Printf("sent %s (%dx%d): %d bytes in %d packets\n",
		path, img.Rect.Dx(), img.Rect.Dy(), st.Bytes, st.Packets)
	return nil
}

func runFramebuffer(ctx context.Context, dev link, hello proto.Hello, args []string) error {
	fs := newFlags("fb")
	path := fs.String("dev", fb.DefaultDevice, "framebuffer device")
	native := fs.Bool("native", false, "resize the framebuffer to the panel (no scaling)")
	sf := addStreamFlags(fs, 30)
	if err := fs.Parse(args); err != nil {
		return err
	}

	src, err := fb.Open(*path)
	if err != nil {
		return err
	}
	defer src.Close()

	if *native {
		// Match the console to the panel so glyphs are drawn at their final
		// size. A 1024x768 console squeezed into 320x480 is unreadable however
		// good the scaler is; at 1:1 the standard font is simply legible.
		w, h := hello.PanelW, hello.PanelH
		if *sf.landscape {
			w, h = h, w
		}
		restore, rerr := src.Resize(w, h)
		if rerr != nil {
			return fmt.Errorf("-native: %w", rerr)
		}
		defer func() {
			if err := restore(); err != nil {
				fmt.Printf("warning: could not restore the framebuffer: %v\n", err)
			}
		}()
	}

	info := src.Info()
	fmt.Printf("framebuffer %s: %s\n", *path, info)

	pipe, err := newFramebufferPipeline(info, hello, sf)
	if err != nil {
		return err
	}
	fmt.Printf("mirroring: %s\n", pipe.sender.Grid())

	// Drain bulk IN for as long as we are streaming. Waiting for the reader to
	// finish before returning keeps it off the file descriptor that the
	// caller's deferred Close is about to take away.
	ctx, cancel := context.WithCancel(ctx)
	var resync atomic.Bool
	done := make(chan struct{})
	go func() {
		defer close(done)
		watchEvents(ctx, dev, &resync)
	}()
	defer func() {
		cancel()
		<-done
	}()

	m := newMeter()
	err = loop(ctx, *sf.fps, *sf.seconds, func() error {
		if resync.Swap(false) {
			fmt.Println("device reported losses — forcing a full refresh")
			pipe.sender.Invalidate()
		}
		frame, ferr := src.Frame()
		if ferr != nil {
			return ferr
		}
		st, serr := pipe.push(ctx, dev, frame, info.Stride, *sf.full)
		m.add(st)
		return serr
	})
	fmt.Println(m.summary())
	return err
}

// framebufferPipeline holds the per-frame scratch so streaming allocates
// nothing after startup.
type framebufferPipeline struct {
	conv   *render.Converter
	scaler *render.Scaler
	sender *proto.TileSender
	rgba   *image.RGBA
	px     []uint16
}

func newFramebufferPipeline(info fb.Info, hello proto.Hello, sf streamFlags) (*framebufferPipeline, error) {
	conv, err := render.NewConverter(info.Format)
	if err != nil {
		return nil, err
	}
	scaler, err := render.NewScaler(info.Width, info.Height, hello.PanelW, hello.PanelH, sf.mode(), *sf.landscape)
	if err != nil {
		return nil, err
	}
	sender, err := proto.NewTileSender(hello, proto.Options{})
	if err != nil {
		return nil, err
	}
	return &framebufferPipeline{
		conv:   conv,
		scaler: scaler,
		sender: sender,
		rgba:   image.NewRGBA(image.Rect(0, 0, info.Width, info.Height)),
		px:     make([]uint16, hello.PanelW*hello.PanelH),
	}, nil
}

func (p *framebufferPipeline) push(ctx context.Context, c proto.Conn, frame []byte, stride int, full bool) (proto.Stats, error) {
	if err := p.conv.ToRGBA(frame, stride, p.rgba); err != nil {
		return proto.Stats{}, err
	}
	if err := p.scaler.Render(p.rgba, p.px); err != nil {
		return proto.Stats{}, err
	}
	return p.sender.Send(ctx, c, p.px, full)
}

// loop runs step at the requested rate until the deadline passes or the
// context is cancelled, which is a clean stop rather than an error.
func loop(ctx context.Context, fps, seconds int, step func() error) error {
	if fps < 1 {
		fps = 1
	}
	budget := time.Second / time.Duration(fps)
	var deadline time.Time
	if seconds > 0 {
		deadline = time.Now().Add(time.Duration(seconds) * time.Second)
	}
	for {
		start := time.Now()
		if err := step(); err != nil {
			if errors.Is(err, context.Canceled) {
				return nil
			}
			return err
		}
		if !deadline.IsZero() && !time.Now().Before(deadline) {
			return nil
		}
		timer := time.NewTimer(budget - time.Since(start))
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil
		case <-timer.C:
		}
	}
}

// meter accumulates what the tiler sent and reports throughput once a second.
type meter struct {
	start  time.Time
	last   time.Time
	frames int
	bytes  int
	tiles  int
}

func newMeter() *meter {
	now := time.Now()
	return &meter{start: now, last: now}
}

func (m *meter) add(st proto.Stats) {
	m.frames++
	m.bytes += st.Bytes
	m.tiles += st.Tiles
	if now := time.Now(); now.Sub(m.last) >= time.Second {
		m.last = now
		fmt.Printf("frame %d  %.2f MB/s avg  %.1f fps\n",
			m.frames, m.rate(), float64(m.frames)/time.Since(m.start).Seconds())
	}
}

func (m *meter) rate() float64 {
	return float64(m.bytes) / time.Since(m.start).Seconds() / 1e6
}

func (m *meter) summary() string {
	elapsed := time.Since(m.start).Seconds()
	return fmt.Sprintf("sent %d frames, %d tiles, %.1f KB, %.2f MB/s, effective %.1f fps",
		m.frames, m.tiles, float64(m.bytes)/1024, m.rate(), float64(m.frames)/elapsed)
}
