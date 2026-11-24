//go:build !plan9

package main

import (
	"fmt"
	"io"
	"os"
	"strings"
)

type uiFS struct{ c *client }

// openUI dials $UI_DIAL (unix!PATH or tcp!HOST!PORT) and attaches.
func openUI() (*uiFS, error) {
	d := os.Getenv("UI_DIAL")
	if d == "" {
		return nil, fmt.Errorf("no $UI_DIAL")
	}
	c, err := dial(d)
	if err != nil {
		return nil, err
	}
	return &uiFS{c}, nil
}

func (u *uiFS) Open(path string, write bool) (io.ReadWriter, error) {
	mode := uint8(0)
	if write {
		mode = 1
	}
	fid, err := u.c.open(strings.Split(path, "/"), mode)
	if err != nil {
		return nil, err
	}
	return &file{u.c, fid, 0}, nil
}

type file struct {
	c   *client
	fid uint32
	off uint64
}

func (f *file) Read(p []byte) (int, error) {
	n := len(p)
	if max := int(f.c.msize) - 24; n > max {
		n = max
	}
	b, err := f.c.read(f.fid, f.off, uint32(n))
	if err != nil {
		return 0, err
	}
	if len(b) == 0 {
		return 0, io.EOF
	}
	f.off += uint64(len(b))
	return copy(p, b), nil
}

func (f *file) Write(p []byte) (int, error) {
	if err := f.c.write(f.fid, f.off, p); err != nil {
		return 0, err
	}
	f.off += uint64(len(p))
	return len(p), nil
}
