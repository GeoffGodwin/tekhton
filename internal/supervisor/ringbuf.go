package supervisor

import "sync"

// ringBuf is the fixed-size circular buffer that backs AgentResultV1.StdoutTail.
// V3's bash supervisor kept the last N lines in a tail file; we keep them in
// memory and snapshot at completion. Mutex-guarded because the decoder
// goroutine adds while the main goroutine may snapshot.
type ringBuf struct {
	mu   sync.Mutex
	buf  []string
	size int
	head int  // next write position
	full bool // true once size lines have been written
}

// newRingBuf builds a ring with the given capacity. A zero or negative size
// is clamped to 1; the decoder always wants at least one slot.
func newRingBuf(size int) *ringBuf {
	if size <= 0 {
		size = 1
	}
	return &ringBuf{buf: make([]string, size), size: size}
}

// add appends one line, evicting the oldest if the ring is full.
func (r *ringBuf) add(line string) {
	r.mu.Lock()
	r.buf[r.head] = line
	r.head++
	if r.head == r.size {
		r.head = 0
		r.full = true
	}
	r.mu.Unlock()
}

// snapshot returns the buffered lines in chronological order (oldest first).
// Callers receive a fresh slice — mutating it does not affect the ring.
func (r *ringBuf) snapshot() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.full {
		out := make([]string, r.head)
		copy(out, r.buf[:r.head])
		return out
	}
	out := make([]string, r.size)
	copy(out, r.buf[r.head:])
	copy(out[r.size-r.head:], r.buf[:r.head])
	return out
}

// len reports the number of buffered lines (≤ size). Used by tests.
func (r *ringBuf) len() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.full {
		return r.size
	}
	return r.head
}
