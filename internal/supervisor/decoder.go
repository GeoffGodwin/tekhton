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
//
// NumTurns mirrors the `num_turns` field claude CLI 2.1 emits on its terminal
// `type:"result"` event. The V3 supervisor counted turns by watching for an
// internal `turn` field claude no longer emits; mapping the 2.1 result event
// here is what feeds AgentResultV1.TurnsUsed.
type event struct {
	Type     string          `json:"type"`
	Subtype  string          `json:"subtype,omitempty"`
	Turn     int             `json:"turn,omitempty"`
	NumTurns int             `json:"num_turns,omitempty"`
	Detail   json.RawMessage `json:"detail,omitempty"`
	// Claude CLI 2.1 result-event fields we used to drop on the floor:
	// PermissionDenials lists every tool call the permission system
	// blocked. Critical diagnostic — explains "agent did nothing" runs
	// where the prompt asked for Write/Edit but the tool got silently
	// denied. TerminalReason is the canonical "why did the run end"
	// signal (completed | error | interrupted | max_turns), more
	// informative than IsError alone. APIErrorStatus distinguishes
	// "API returned 5xx" from "agent decided to error out."
	PermissionDenials json.RawMessage `json:"permission_denials,omitempty"`
	TerminalReason    string          `json:"terminal_reason,omitempty"`
	APIErrorStatus    string          `json:"api_error_status,omitempty"`
	// RetryDelayMs comes from system/api_retry events (added in 2.1.x).
	// When non-zero, claude is in an internal retry loop and we should
	// NOT trip the activity timer for that window.
	RetryDelayMs int `json:"retry_delay_ms,omitempty"`
	Raw          string `json:"-"`
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
		// Claude CLI 2.1 emits system/api_retry events when it hits an
		// upstream 429/5xx and back-pedals. The retry window is silent —
		// no further stdout for RetryDelayMs ms — which would otherwise
		// look like a stuck agent and trip the activity timeout, killing
		// a run that was about to recover on its own. Extend the timer
		// past the announced retry deadline (with the normal idle window
		// stacked on top) so the supervisor stays out of the way.
		if cfg.timer != nil && cfg.timeout > 0 && ev.RetryDelayMs > 0 &&
			(ev.Type == "api_retry" || (ev.Type == "system" && ev.Subtype == "api_retry")) {
			cfg.timer.Reset(cfg.timeout + time.Duration(ev.RetryDelayMs)*time.Millisecond)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case cfg.out <- ev:
		}
	}
	return sc.Err()
}

// resultDiagnostics scans the event stream for the terminal `result` event
// and returns the diagnostic fields claude CLI 2.1 packs into it. These feed
// AgentResultV1's diagnostic surface so post-mortem of a "did nothing" run
// doesn't require re-running with stream-json instrumentation.
//
// permissionDenials is the count of entries in the result's
// permission_denials[] array. Non-zero values are the FIRST thing to check
// when an agent burned turns without producing diffs — every denied tool
// call costs context but produces nothing.
func resultDiagnostics(events []event) (subtype, terminalReason, apiErrorStatus string, permissionDenials int) {
	for i := len(events) - 1; i >= 0; i-- {
		ev := events[i]
		if ev.Type != "result" {
			continue
		}
		subtype = ev.Subtype
		terminalReason = ev.TerminalReason
		apiErrorStatus = ev.APIErrorStatus
		if len(ev.PermissionDenials) > 0 {
			var arr []json.RawMessage
			if err := json.Unmarshal(ev.PermissionDenials, &arr); err == nil {
				permissionDenials = len(arr)
			}
		}
		return
	}
	return
}

// finalTurn extracts the highest turn number observed across emitted events.
// Used by Run to populate AgentResultV1.TurnsUsed without bookkeeping inside
// the hot decode loop.
//
// Claude CLI 2.1's terminal event is `type:"result"` with `num_turns:N`. The
// pre-2.1 stream emitted intermediate events with a per-line `turn` field;
// we keep that path for backward compatibility (and for fake-agent fixtures
// in tests) but prefer NumTurns when it is set, since it represents the
// authoritative count at end-of-run.
func finalTurn(events []event) int {
	highest := 0
	for _, ev := range events {
		if ev.NumTurns > highest {
			highest = ev.NumTurns
		}
		if ev.Turn > highest {
			highest = ev.Turn
		}
	}
	return highest
}
