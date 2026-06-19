// Command accept-control is the FROZEN control arm of the accept-bench benchmark.
//
// It is a faithful Go clone of a high-performance reference proxy's accept path:
// SO_REUSEPORT accept fan-out, one goroutine per reuseport socket, goroutine-per-
// connection dispatch, and an optional TCP_INFO-driven adaptive scaler. It does NOT
// proxy — per connection it accepts, reads the request bytes once, writes the exact
// 19-byte REPLY_BYTES, and closes.
package main

import (
	"context"
	"flag"
	"log"
	"net"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// replyBytes is the exact, byte-for-byte fixed reply (19 bytes).
var replyBytes = []byte("HTTP/1.1 200 OK\r\n\r\n")

const (
	// floorCap is the upper bound on the floor socket count: min(GOMAXPROCS, 8).
	floorCap = 8
	// scalerInterval is how often the adaptive scaler probes queue depth.
	scalerInterval = 2 * time.Second
	// highWater is the accept-queue depth that triggers a doubling.
	highWater = 40
	// maxSockets is the grow-only ceiling on reuseport sockets.
	maxSockets = 64
	// readBuf is the per-connection request read buffer (read once, up to 512 bytes).
	readBuf = 512
)

func main() {
	port := flag.Int("port", 30, "TCP port to listen on")
	scaler := flag.Bool("scaler", false, "enable the adaptive (grow-only) reuseport scaler")
	flag.Parse()

	s := &server{port: *port}

	// Floor socket count: min(GOMAXPROCS, 8).
	floor := runtime.GOMAXPROCS(0)
	if floor > floorCap {
		floor = floorCap
	}
	if floor < 1 {
		floor = 1
	}

	for i := 0; i < floor; i++ {
		if err := s.addListener(); err != nil {
			log.Fatalf("control: failed to create reuseport listener %d: %v", i, err)
		}
	}

	log.Printf("control: listening on :%d with %d reuseport socket(s), scaler=%v",
		*port, floor, *scaler)

	if *scaler {
		go s.runScaler()
	}

	// Block forever; accept goroutines do the work.
	select {}
}

// server owns the set of reuseport listen sockets and grows it (grow-only).
type server struct {
	port int

	mu        sync.Mutex
	listeners []*listenSocket // protected by mu
	count     atomic.Int64    // current number of reuseport sockets
}

// listenSocket pairs a net.Listener with the raw fd needed for TCP_INFO probing.
type listenSocket struct {
	ln net.Listener
	fd int // dup'd file descriptor of the listen socket, for getsockopt
}

// addListener creates one more reuseport listen socket, records its fd for probing,
// and launches its accept loop. Safe to call concurrently with the scaler.
func (s *server) addListener() error {
	lc := net.ListenConfig{Control: controlListen}

	ln, err := lc.Listen(context.Background(), "tcp", net.JoinHostPort("", itoa(s.port)))
	if err != nil {
		return err
	}

	fd, err := rawFD(ln)
	if err != nil {
		ln.Close()
		return err
	}

	socket := &listenSocket{ln: ln, fd: fd}

	s.mu.Lock()
	s.listeners = append(s.listeners, socket)
	s.mu.Unlock()
	s.count.Add(1)

	go s.acceptLoop(socket)
	return nil
}

// acceptLoop runs a tight accept loop, spawning a fresh goroutine per connection.
func (s *server) acceptLoop(socket *listenSocket) {
	for {
		c, err := socket.ln.Accept()
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Temporary() { //nolint:staticcheck
				continue
			}
			// Permanent error (e.g. listener closed): stop this loop.
			return
		}
		go handleConn(c)
	}
}

// handleConn reads the request once, writes the exact reply, and closes.
func handleConn(c net.Conn) {
	defer c.Close()

	setConnOpts(c)

	// Read the client's request bytes once (up to readBuf). We deliberately do a
	// single read of a fixed chunk — enough to consume the request line/headers a
	// client sends before we reply, matching the observed external behavior.
	var buf [readBuf]byte
	_, _ = c.Read(buf[:])

	// Write the EXACT 19-byte reply, in full.
	if _, err := writeFull(c, replyBytes); err != nil {
		return
	}
}

// writeFull writes all of p, retrying short writes.
func writeFull(c net.Conn, p []byte) (int, error) {
	total := 0
	for total < len(p) {
		n, err := c.Write(p[total:])
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// runScaler probes the deepest accept-queue depth every scalerInterval and doubles
// the reuseport socket count (grow-only, capped at maxSockets) on high water.
func (s *server) runScaler() {
	ticker := time.NewTicker(scalerInterval)
	defer ticker.Stop()

	for range ticker.C {
		deepest := s.deepestQueueDepth()
		if deepest < highWater {
			continue
		}

		cur := int(s.count.Load())
		if cur >= maxSockets {
			continue
		}
		target := cur * 2
		if target > maxSockets {
			target = maxSockets
		}

		log.Printf("control: scaler high-water (depth=%d) — growing %d -> %d sockets",
			deepest, cur, target)
		for i := cur; i < target; i++ {
			if err := s.addListener(); err != nil {
				log.Printf("control: scaler failed to add listener: %v", err)
				break
			}
		}
	}
}

// deepestQueueDepth returns the largest sk_ack_backlog (TCP_INFO tcpi_unacked)
// across all current listen sockets.
func (s *server) deepestQueueDepth() int {
	s.mu.Lock()
	sockets := make([]*listenSocket, len(s.listeners))
	copy(sockets, s.listeners)
	s.mu.Unlock()

	deepest := 0
	for _, sock := range sockets {
		info, err := unix.GetsockoptTCPInfo(sock.fd, unix.IPPROTO_TCP, unix.TCP_INFO)
		if err != nil {
			continue
		}
		// For a LISTEN socket the kernel overloads tcpi_unacked with sk_ack_backlog,
		// i.e. the current accept-queue depth.
		if d := int(info.Unacked); d > deepest {
			deepest = d
		}
	}
	return deepest
}

// rawFD returns a dup'd file descriptor for the listener's underlying socket.
// The caller does not own ln's lifetime via this fd; it's used read-only for
// getsockopt, and the dup keeps it valid for the process lifetime.
func rawFD(ln net.Listener) (int, error) {
	tl, ok := ln.(*net.TCPListener)
	if !ok {
		return -1, errNotTCP
	}
	f, err := tl.File() // dup's the fd
	if err != nil {
		return -1, err
	}
	// f's fd is owned by f; keep f alive by leaking it intentionally for the
	// process lifetime so the fd stays valid for probing. Return the fd number.
	return int(f.Fd()), nil
}

var errNotTCP = &net.OpError{Op: "listen", Err: syscall.EINVAL}

// itoa is a tiny strconv.Itoa to avoid pulling in strconv just for the port.
func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	neg := i < 0
	if neg {
		i = -i
	}
	var b [20]byte
	pos := len(b)
	for i > 0 {
		pos--
		b[pos] = byte('0' + i%10)
		i /= 10
	}
	if neg {
		pos--
		b[pos] = '-'
	}
	return string(b[pos:])
}
