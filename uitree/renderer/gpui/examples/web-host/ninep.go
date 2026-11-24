//go:build !plan9

package main

// A 9P2000 client with one request in flight at a time: all the counter
// needs (read an event, then write the ctl).

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
)

const nofid = ^uint32(0)

type client struct {
	mu    sync.Mutex
	conn  net.Conn
	msize uint32
	fid   uint32
}

func dial(d string) (*client, error) {
	var conn net.Conn
	var err error
	switch {
	case strings.HasPrefix(d, "unix!"):
		conn, err = net.Dial("unix", d[5:])
	case strings.HasPrefix(d, "tcp!"):
		p := strings.Split(d, "!")
		conn, err = net.Dial("tcp", p[1]+":"+p[2])
	default:
		conn, err = net.Dial("unix", d)
	}
	if err != nil {
		return nil, err
	}
	c := &client{conn: conn, msize: 65536, fid: 1}
	r, err := c.rpc(100, 0xffff, u32(c.msize), str("9P2000"))
	if err != nil {
		return nil, err
	}
	c.msize = binary.LittleEndian.Uint32(r)
	if _, err := c.rpc(104, 1, u32(0), u32(nofid), str("counter"), str("")); err != nil {
		return nil, err
	}
	return c, nil
}

func u16(v uint16) []byte { b := make([]byte, 2); binary.LittleEndian.PutUint16(b, v); return b }
func u32(v uint32) []byte { b := make([]byte, 4); binary.LittleEndian.PutUint32(b, v); return b }
func u64(v uint64) []byte { b := make([]byte, 8); binary.LittleEndian.PutUint64(b, v); return b }
func str(s string) []byte  { return append(u16(uint16(len(s))), s...) }

func (c *client) rpc(typ uint8, tag uint16, parts ...[]byte) ([]byte, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	var body []byte
	for _, p := range parts {
		body = append(body, p...)
	}
	msg := append(u32(uint32(7+len(body))), typ)
	msg = append(msg, u16(tag)...)
	msg = append(msg, body...)
	if _, err := c.conn.Write(msg); err != nil {
		return nil, err
	}
	var sz [4]byte
	if _, err := io.ReadFull(c.conn, sz[:]); err != nil {
		return nil, err
	}
	rest := make([]byte, binary.LittleEndian.Uint32(sz[:])-4)
	if _, err := io.ReadFull(c.conn, rest); err != nil {
		return nil, err
	}
	if rest[0] == 107 {
		n := binary.LittleEndian.Uint16(rest[3:])
		return nil, errors.New(string(rest[5 : 5+n]))
	}
	return rest[3:], nil
}

func (c *client) open(names []string, mode uint8) (uint32, error) {
	c.fid++
	f := c.fid
	parts := [][]byte{u32(0), u32(f), u16(uint16(len(names)))}
	for _, n := range names {
		parts = append(parts, str(n))
	}
	if _, err := c.rpc(110, 1, parts...); err != nil {
		return 0, err
	}
	if _, err := c.rpc(112, 1, u32(f), []byte{mode}); err != nil {
		return 0, err
	}
	return f, nil
}

func (c *client) read(fid uint32, off uint64, n uint32) ([]byte, error) {
	r, err := c.rpc(116, 1, u32(fid), u64(off), u32(n))
	if err != nil {
		return nil, err
	}
	k := binary.LittleEndian.Uint32(r)
	return r[4 : 4+k], nil
}

func (c *client) write(fid uint32, off uint64, p []byte) error {
	for len(p) > 0 {
		k := len(p)
		if max := int(c.msize) - 24; k > max {
			k = max
		}
		if _, err := c.rpc(118, 1, u32(fid), u64(off), u32(uint32(k)), p[:k]); err != nil {
			return err
		}
		p = p[k:]
		off += uint64(k)
	}
	return nil
}
