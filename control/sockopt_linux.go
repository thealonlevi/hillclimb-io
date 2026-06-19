//go:build linux

package main

import (
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

// controlListen is the net.ListenConfig.Control hook. It runs on every reuseport
// listen socket BEFORE bind, setting SO_REUSEADDR and SO_REUSEPORT. TCP_FASTOPEN
// is enabled best-effort (soft-fail). We deliberately do NOT set the listen backlog.
func controlListen(network, address string, c syscall.RawConn) error {
	var setErr error
	err := c.Control(func(fd uintptr) {
		f := int(fd)
		if e := unix.SetsockoptInt(f, unix.SOL_SOCKET, unix.SO_REUSEADDR, 1); e != nil {
			setErr = e
			return
		}
		if e := unix.SetsockoptInt(f, unix.SOL_SOCKET, unix.SO_REUSEPORT, 1); e != nil {
			setErr = e
			return
		}
		// TCP Fast Open is optional — soft-fail if the kernel/socket rejects it.
		_ = unix.SetsockoptInt(f, unix.IPPROTO_TCP, unix.TCP_FASTOPEN, 1)
	})
	if err != nil {
		return err
	}
	return setErr
}

// setConnOpts sets per-connection options on an accepted client socket:
// TCP_NODELAY=1, SO_KEEPALIVE=1, plus the reference proxy's keepalive timers.
func setConnOpts(c net.Conn) {
	tc, ok := c.(*net.TCPConn)
	if !ok {
		return
	}
	rc, err := tc.SyscallConn()
	if err != nil {
		return
	}
	_ = rc.Control(func(fd uintptr) {
		f := int(fd)
		_ = unix.SetsockoptInt(f, unix.IPPROTO_TCP, unix.TCP_NODELAY, 1)
		_ = unix.SetsockoptInt(f, unix.SOL_SOCKET, unix.SO_KEEPALIVE, 1)
		_ = unix.SetsockoptInt(f, unix.IPPROTO_TCP, unix.TCP_KEEPIDLE, 60)
		_ = unix.SetsockoptInt(f, unix.IPPROTO_TCP, unix.TCP_KEEPINTVL, 10)
		_ = unix.SetsockoptInt(f, unix.IPPROTO_TCP, unix.TCP_KEEPCNT, 5)
	})
}
