// Package render turns pixels from any source — a decoded image file, a Linux
// framebuffer, a generated test pattern — into the panel's RGB565 layout.
//
// It is platform-neutral and depends only on the standard library.
package render

// RGB565 packs 8-bit channels into the panel's 16-bit pixel format.
func RGB565(r, g, b uint8) uint16 {
	return uint16(r>>3)<<11 | uint16(g>>2)<<5 | uint16(b>>3)
}

// ColorBars renders the classic 8-bar pattern. phase shifts the bars sideways
// so motion is visible on the panel. Mirrors the macOS host's pattern.
func ColorBars(width, height, phase int) []uint16 {
	colors := [...]uint16{
		RGB565(255, 255, 255),
		RGB565(255, 255, 0),
		RGB565(0, 255, 255),
		RGB565(0, 255, 0),
		RGB565(255, 0, 255),
		RGB565(255, 0, 0),
		RGB565(0, 0, 255),
		RGB565(0, 0, 0),
	}
	n := len(colors)
	px := make([]uint16, width*height)
	barWidth := max(1, width/n)
	for x := 0; x < width; x++ {
		px[x] = colors[((x+phase)/barWidth%n+n)%n]
	}
	for y := 1; y < height; y++ {
		copy(px[y*width:(y+1)*width], px[:width])
	}
	return px
}
