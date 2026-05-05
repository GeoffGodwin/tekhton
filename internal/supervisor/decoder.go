package supervisor

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"sync/atomic"
	"time"
)

// scannerInitBuf is bufio.Scanner's initial allocation. A 64 KB scratch is
// fine for the common case; the cap below grows on demand up to scannerMaxBuf.
const scannerInitBuf = 64 * 1024

// scannerMaxBuf bounds a single line's length. claude streaming events can
// embed multi-MB tool results — see m06's "Watch For" note. The default 64 KB
// fails silently with bufio.ErrTooLong, which would manifest as "agent stopped
// emitting output" and a spurious activity timeout, so we bump it explicitly.
const scannerMaxBuf = 4 * 1024 * 1024

// activityTimer is the subset of *time.Timer the decoder uses. Existing as
// an interface lets a future fake clock drive Reset() without spawning a real
// timer in unit tests; the production type is *time.Timer.
type activityTimer interface {
	Reset(time.Duration) bool
}

// event is the decoded form of one stdout line. The decoder forwards JSON
// lines whose `type` parses; non-JSON lines (or JSON missing a type) are
// captured in the ring buffer but no event is emitted. Raw is the original
// line so downstream consumers can re-marshal or log verbatim.
type event struct {
	Type   string          `json:"type"`
	Turn   int             `json:"turn,omitempty"`
	Detail json.RawMessage `json:"detail,omitempty"`
	Raw    string          `json:"-"`
}

// decoderConfig wires the decoder's collaborators. Splitting it from decode()
// keeps the production call site readable while letting tests construct one
// with a fake timer.
type decoderConfig struct {
	timer        activityTimer
	timeout      time.Duration
	lastActivity *atomic.Int64
	rb           *ringBuf
	out          chan<- event
}

// decode reads lines from r until EOF or ctx is cancelled. Each line:
//
//  1. Is appended to the ring buffer (always — JSON or not).
//  2. Stamps the activity timestamp and resets the activity timer. The reset
//     happens for any line, mirroring V3's "any output counts as activity"
//     contract; without it a long bash invocation that emits non-JSON
//     progress text would falsely trip the activity timeout.
//  3. If the line parses as JSON with a non-empty `type`, an event is sent
//     to cfg.out. Lines that fail to parse are silently dropped at the
//     channel — the ring buffer is the diagnostic record.
//
// decode returns the bufio.Scanner error, which is nil on clean EOF. Callers
// distinguish "process closed stdout" (nil) from "I/O failed mid-stream"
// (non-nil) using this return.
func decode(ctx context.Context, r io.Reader, cfg decoderConfig) error {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, scannerInitBuf), scannerMaxBuf)
	for sc.Scan() {
		line := sc.Text()
		cfg.rb.add(line)
		if cfg.lastActivity != nil {
			cfg.lastActivity.Store(time.Now().UnixNano())
		}
		if cfg.timer != nil && cfg.timeout > 0 {
			cfg.timer.Reset(cfg.timeout)
		}

		var ev event
		if err := json.Unmarshal([]byte(line), &ev); err != nil || ev.Type == "" {
			// Non-JSON or untyped lines: ring buffer keeps them, but no
			// event flows downstream. The decoder must not panic on
			// malformed input — agents writing partial JSON during
			// shutdown is a normal occurrence.
			continue
		}
		ev.Raw = line
		select {
		case <-ctx.Done():
			return ctx.Err()
		case cfg.out <- ev:
		}
	}
	return sc.Err()
}

// finalTurn extracts the highest turn number observed across emitted events.
// Used by Run to populate AgentResultV1.TurnsUsed without bookkeeping inside
// the hot decode loop.
func finalTurn(events []event) int {
	highest := 0
	for _, ev := range events {
		if ev.Turn > highest {
			highest = ev.Turn
		}
	}
	return highest
}
