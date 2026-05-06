package supervisor

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/geoffgodwin/tekhton/internal/causal"
)

// V3 parity defaults — match QUOTA_SLEEP_CHUNK and QUOTA_MAX_PAUSE_DURATION
// from lib/config_defaults.sh. The chunk size bounds SIGINT responsiveness
// during a pause; the max duration is the hard cap before EnterQuotaPause
// gives up and surfaces an error.
const (
	defaultPauseChunk       = 5 * time.Second
	maxPauseChunk           = 60 * time.Second
	defaultPauseMaxDuration = 5*time.Hour + 15*time.Minute
)

// QuotaPause configures one EnterQuotaPause call.
//
// Until is the wall-clock time the pause should release at — typically
// derived from the upstream Retry-After header via ParseRetryAfter. The
// pause sleeps in ChunkSize-bounded slices so a Ctrl-C lands within
// ChunkSize seconds. MaxDuration is the hard cap that fires when Until is
// further out than the supervisor is willing to wait (e.g. a misbehaved
// upstream returning a multi-day Retry-After).
type QuotaPause struct {
	Until       time.Time
	Reason      string
	ChunkSize   time.Duration
	MaxDuration time.Duration

	// clock and sleep are unexported test seams. Production code passes
	// nil and gets the real time package; tests substitute a virtual clock
	// so the chunked-sleep loop can be driven without real waits and the
	// "cancellation lands within ChunkSize" assertion is verifiable.
	clock func() time.Time
	sleep func(time.Duration) <-chan time.Time
}

// quotaPauseEvent is the well-known causal event type for a pause boundary.
// quotaTickEvent fires once per ChunkSize slice while the pause is active so
// the (Python) TUI sidecar can render a countdown by polling causal events.
const (
	quotaPauseEvent      = "quota_pause"
	quotaTickEvent       = "quota_tick"
	quotaResumeEvent     = "quota_resume"
	quotaPauseCappedType = "quota_pause_capped"
)

// EnterQuotaPause sleeps until p.Until is reached, ctx is cancelled, or
// p.MaxDuration elapses — whichever comes first. The sleep is chunked at
// p.ChunkSize so the goroutine wakes regularly to emit causal tick events
// and to observe ctx cancellation promptly.
//
// Returns nil on natural release, ctx.Err() on cancellation, or a wrapped
// "quota_pause_capped" error when MaxDuration fires before Until.
//
// Quota pauses do NOT consume retry attempts — the caller invokes this
// helper, then continues the retry loop without bumping its attempt
// counter. This matches V3 (lib/quota.sh) and the m08 design.
func (s *Supervisor) EnterQuotaPause(ctx context.Context, p QuotaPause) error {
	chunk := p.ChunkSize
	if chunk <= 0 {
		chunk = defaultPauseChunk
	}
	if chunk > maxPauseChunk {
		chunk = maxPauseChunk
	}
	maxDur := p.MaxDuration
	if maxDur <= 0 {
		maxDur = defaultPauseMaxDuration
	}
	now := p.clock
	if now == nil {
		now = time.Now
	}
	sleep := p.sleep
	if sleep == nil {
		sleep = time.After
	}

	start := now()
	deadline := p.Until
	if deadline.IsZero() || deadline.Before(start) {
		// Nothing to wait for — emit a no-op pause/resume pair so the
		// causal log still records the entry, then return.
		emitQuotaEvent(s.causal, quotaPauseEvent, p.Reason, "until=now")
		emitQuotaEvent(s.causal, quotaResumeEvent, p.Reason, "duration=0")
		return nil
	}

	hardCap := start.Add(maxDur)
	capped := false
	if deadline.After(hardCap) {
		deadline = hardCap
		capped = true
	}

	emitQuotaEvent(s.causal, quotaPauseEvent, p.Reason,
		fmt.Sprintf("until=%s capped=%t", p.Until.UTC().Format(time.RFC3339), capped))

	for {
		remaining := deadline.Sub(now())
		if remaining <= 0 {
			break
		}
		step := chunk
		if step > remaining {
			step = remaining
		}
		select {
		case <-sleep(step):
		case <-ctx.Done():
			emitQuotaEvent(s.causal, quotaResumeEvent, p.Reason,
				fmt.Sprintf("cancelled=%v", ctx.Err()))
			return ctx.Err()
		}
		emitQuotaEvent(s.causal, quotaTickEvent, p.Reason,
			fmt.Sprintf("remaining=%s", deadline.Sub(now()).Round(time.Second)))
	}

	if capped {
		emitQuotaEvent(s.causal, quotaPauseCappedType, p.Reason,
			fmt.Sprintf("max_duration=%s", maxDur))
		emitQuotaEvent(s.causal, quotaResumeEvent, p.Reason, "outcome=capped")
		return fmt.Errorf("%w (%s)", ErrQuotaPauseCapped, maxDur)
	}

	emitQuotaEvent(s.causal, quotaResumeEvent, p.Reason,
		fmt.Sprintf("duration=%s", now().Sub(start).Round(time.Second)))
	return nil
}

// ParseRetryAfter accepts either an integer seconds value or an HTTP-Date
// (RFC1123 + variants, via http.ParseTime) and returns the absolute time
// at which the retry should be attempted. The boolean is false (and the
// returned time is zero) when the input is empty or unparseable —
// callers fall back to QUOTA_MAX_PAUSE_DURATION in that path.
//
// http.ParseTime is the same parser net/http uses for Date headers; it
// already covers RFC1123, RFC850, and asctime forms so we don't need to
// list them ourselves.
func ParseRetryAfter(value string) (time.Time, bool) {
	if value == "" {
		return time.Time{}, false
	}
	if secs, err := strconv.Atoi(value); err == nil {
		if secs < 0 {
			return time.Time{}, false
		}
		return time.Now().Add(time.Duration(secs) * time.Second), true
	}
	if t, err := http.ParseTime(value); err == nil {
		return t, true
	}
	return time.Time{}, false
}

// emitQuotaEvent is the small helper that funnels every quota event through
// a single shape: stage="supervisor", body="<reason>\t<detail>". Bash
// consumers parse this exactly as they parse retry events (see retry.go's
// emitRetryEvent). nil log is a silent no-op so tests with no causal seam
// stay silent.
func emitQuotaEvent(log *causal.Log, eventType, reason, detail string) {
	if log == nil {
		return
	}
	if reason == "" {
		reason = "quota_pause"
	}
	_, _ = log.Emit(causal.EmitInput{
		Stage:  "supervisor",
		Type:   eventType,
		Detail: fmt.Sprintf("%s\t%s", reason, detail),
	})
}

// ErrQuotaPauseCapped is the sentinel returned when MaxDuration fires
// before Until is reached — i.e. the upstream Retry-After asked us to wait
// longer than the supervisor is willing to. Production callers fall through
// to the human-action path; tests use errors.Is to drive the assertion.
//
//nolint:gochecknoglobals // sentinel by design, same pattern as errors.go.
var ErrQuotaPauseCapped = errors.New("supervisor: quota pause exceeded MaxDuration")
