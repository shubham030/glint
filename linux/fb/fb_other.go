//go:build !linux

package fb

// Stub so the CLI builds on a developer's machine. Only Linux has
// FBIOGET_VSCREENINFO.

// Device is the non-Linux placeholder; it can never be constructed.
type Device struct{}

// Open always fails off Linux.
func Open(path string) (*Device, error) { return nil, ErrUnsupported }

// Info returns the zero mode.
func (d *Device) Info() Info { return Info{} }

// Frame always fails.
func (d *Device) Frame() ([]byte, error) { return nil, ErrUnsupported }

// Close is a no-op.
func (d *Device) Close() error { return nil }

// Resize always fails off Linux.
func (d *Device) Resize(w, h int) (func() error, error) { return nil, ErrUnsupported }
