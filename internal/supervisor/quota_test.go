package supervisor

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/causal"
)

// fakeClock is a controllable monotonic clock for the chunked-sleep tests.
// Tests advance via Tick() rather than wall time so the assertions don't
// race against the real scheduler.
type fakeClock struct {
	now time.Time
}

func (c *fakeClock) Now() time.Time       { return c.now }
func (c *fakeClock) Tick(d time.Duration) { c.now = c.now.Add(d) }
func (c *fakeClock) ResetTo(t time.Time)  { c.now = t }

// fakeSleep is a sleep seam where every call advances the test clock by
// the requested duration and returns an already-fired channel. The pause
// loop's select then immediately observes the timer fire, ticks the clock
// forward, emits a tick event, and re-evaluates remaining time.
func fakeSleep(c *fakeClock) func(time.Duration) <-chan time.Time {
	return func(d time.Duration) <-chan time.Time {
		c.Tick(d)
		ch := make(chan time.Time, 1)
		ch <- c.now
		return ch
	}
}

func newSupForTest(t *testing.T) (*Supervisor, *causal.Log, string) {
	t.Helper()
	dir := t.TempDir()
	logPath := filepath.Join(dir, "causal.jsonl")
	log, err := causal.Open(logPath, 0, "rid-test")
	if err != nil {
		t.Fatalf("causal.Open: %v", err)
	}
	return &Supervisor{causal: log, binary: "claude"}, log, logPath
}

// ---------------------------------------------------------------------------
// EnterQuotaPause
// ---------------------------------------------------------------------------

func TestEnterQuotaPause_NaturalRelease(t *testing.T) {
	sup, _, logPath := newSupForTest(t)
	clk := &fakeClock{now: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}
	until := clk.now.Add(10 * time.Second)

	err := sup.EnterQuotaPause(context.Background(), QuotaPause{
		Until:     until,
		Reason:    "api_rate_limit",
		ChunkSize: 5 * time.Second,
		clock:     clk.Now,
		sleep:     fakeSleep(clk),
	})
	if err != nil {
		t.Fatalf("EnterQuotaPause: %v", err)
	}
	if !clk.now.Equal(until) {
		t.Errorf("clock advanced to %v; want %v", clk.now, until)
	}

	body := readQuotaLog(t, logPath)
	for _, want := range []string{`"type":"quota_pause"`, `"type":"quota_tick"`, `"type":"quota_resume"`} {
		if !strings.Contains(body, want) {
			t.Errorf("causal log missing %s\n%s", want, body)
		}
	}
}

func TestEnterQuotaPause_CtxCancelMidPause_ReturnsCtxErr(t *testing.T) {
	sup, _, _ := newSupForTest(t)
	clk := &fakeClock{now: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}
	until := clk.now.Add(1 * time.Hour) // long pause; cancel must short-circuit

	ctx, cancel := context.WithCancel(context.Background())
	// Cancel after the first sleep call resolves, before the loop emits
	// its tick event. The fakeSleep below cancels via shared closure.
	cancelled := false
	sleep := func(d time.Duration) <-chan time.Time {
		clk.Tick(d)
		if !cancelled {
			cancelled = true
			cancel()
		}
		ch := make(chan time.Time, 1)
		ch <- clk.now
		return ch
	}

	err := sup.EnterQuotaPause(ctx, QuotaPause{
		Until:     until,
		Reason:    "api_rate_limit",
		ChunkSize: 5 * time.Second,
		clock:     clk.Now,
		sleep:     sleep,
	})
	// The ctx.Done() select-case is reachable on the iteration AFTER
	// cancel fires; either path (this iteration or next) returns
	// context.Canceled.
	if !errors.Is(err, context.Canceled) {
		t.Errorf("err: got %v; want context.Canceled", err)
	}
}

func TestEnterQuotaPause_MaxDurationCap(t *testing.T) {
	sup, _, logPath := newSupForTest(t)
	clk := &fakeClock{now: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}
	// Until is one year out — far past MaxDuration. The cap should fire.
	until := clk.now.Add(24 * time.Hour * 365)

	err := sup.EnterQuotaPause(context.Background(), QuotaPause{
		Until:       until,
		Reason:      "api_rate_limit",
		ChunkSize:   60 * time.Second,
		MaxDuration: 5 * time.Minute,
		clock:       clk.Now,
		sleep:       fakeSleep(clk),
	})
	if !errors.Is(err, ErrQuotaPauseCapped) {
		t.Errorf("err: got %v; want errors.Is ErrQuotaPauseCapped", err)
	}

	body := readQuotaLog(t, logPath)
	if !strings.Contains(body, `"type":"quota_pause_capped"`) {
		t.Errorf("causal log missing quota_pause_capped event\n%s", body)
	}
}

func TestEnterQuotaPause_UntilInPastIsNoop(t *testing.T) {
	sup, _, logPath := newSupForTest(t)
	clk := &fakeClock{now: time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)}
	past := clk.now.Add(-1 * time.Minute)

	err := sup.EnterQuotaPause(context.Background(), QuotaPause{
		Until:  past,
		Reason: "api_rate_limit",
		clock:  clk.Now,
		sleep:  fakeSleep(clk),
	})
	if err != nil {
		t.Fatalf("EnterQuotaPause: %v", err)
	}
	body := readQuotaLog(t, logPath)
	if !strings.Contains(body, `"type":"quota_pause"`) {
		t.Errorf("expected quota_pause event\n%s", body)
	}
	if !strings.Contains(body, `"type":"quota_resume"`) {
		t.Errorf("expected quota_resume event\n%s", body)
	}
}

func TestEnterQuotaPause_DefaultsApplied(t *testing.T) {
	sup, _, _ := newSupForTest(t)
	clk := &fakeClock{now: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}
	until := clk.now.Add(7 * time.Second)
	// ChunkSize=0 → defaults to 5s; without a default, the inner loop
	// would emit no ticks for a 7-second pause.
	err := sup.EnterQuotaPause(context.Background(), QuotaPause{
		Until: until,
		clock: clk.Now,
		sleep: fakeSleep(clk),
	})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
}

// ---------------------------------------------------------------------------
// ParseRetryAfter
// ---------------------------------------------------------------------------

func TestParseRetryAfter_IntegerSeconds(t *testing.T) {
	before := time.Now()
	got, ok := ParseRetryAfter("60")
	after := time.Now()
	if !ok {
		t.Fatalf("ok=false; want true")
	}
	expectedMin := before.Add(60 * time.Second)
	expectedMax := after.Add(60 * time.Second)
	if got.Before(expectedMin) || got.After(expectedMax) {
		t.Errorf("got %v; want in [%v, %v]", got, expectedMin, expectedMax)
	}
}

func TestParseRetryAfter_HTTPDate(t *testing.T) {
	got, ok := ParseRetryAfter("Wed, 21 Oct 2026 07:28:00 GMT")
	if !ok {
		t.Fatalf("ok=false; want true")
	}
	want := time.Date(2026, 10, 21, 7, 28, 0, 0, time.UTC)
	if !got.Equal(want) {
		t.Errorf("got %v; want %v", got, want)
	}
}

func TestParseRetryAfter_Garbage(t *testing.T) {
	cases := []string{"", "garbage", "not-a-date", "-5"}
	for _, c := range cases {
		t.Run(c, func(t *testing.T) {
			got, ok := ParseRetryAfter(c)
			if ok {
				t.Errorf("%q: ok=true want false", c)
			}
			if !got.IsZero() {
				t.Errorf("%q: time=%v want zero", c, got)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Probe — fakeRunner-driven tests
// ---------------------------------------------------------------------------

type fakeProbeResult struct {
	exitCode int
	stderr   string
	err      error
}

func (r fakeProbeResult) runner(_ context.Context, _ ProbeKind, _ string) (int, string, error) {
	return r.exitCode, r.stderr, r.err
}

func TestProbe_QuotaLifted_OnZeroExit(t *testing.T) {
	sup, _, _ := newSupForTest(t)
	got := sup.probe(context.Background(), ProbeVersion, fakeProbeResult{exitCode: 0}.runner)
	if got != ProbeQuotaLifted {
		t.Errorf("got %v; want ProbeQuotaLifted", got)
	}
}

func TestProbe_QuotaActive_OnRateLimitStderr(t *testing.T) {
	sup, _, _ := newSupForTest(t)
	cases := []string{
		"HTTP 429 rate limit exceeded",
		"Error: rate-limit reached",
		"too many requests; try again later",
		"upstream is overloaded, please retry",
	}
	for _, stderr := range cases {
		t.Run(stderr, func(t *testing.T) {
			got := sup.probe(context.Background(), ProbeVersion,
				fakeProbeResult{exitCode: 1, stderr: stderr}.runner)
			if got != ProbeQuotaActive {
				t.Errorf("stderr=%q: got %v; want ProbeQuotaActive", stderr, got)
			}
		})
	}
}

func TestProbe_Error_OnRunnerError(t *testing.T) {
	sup, _, _ := newSupForTest(t)
	got := sup.probe(context.Background(), ProbeVersion,
		fakeProbeResult{exitCode: -1, err: errors.New("ENOENT")}.runner)
	if got != ProbeError {
		t.Errorf("got %v; want ProbeError", got)
	}
}

func TestProbe_Error_OnUnrecognizedExitCode(t *testing.T) {
	sup, _, _ := newSupForTest(t)
	// Nonzero exit but no rate-limit smell — could be a transient 5xx,
	// network blip. Conservatively classified as ProbeError so the
	// caller doesn't immediately retry.
	got := sup.probe(context.Background(), ProbeVersion,
		fakeProbeResult{exitCode: 1, stderr: "connection reset"}.runner)
	if got != ProbeError {
		t.Errorf("got %v; want ProbeError", got)
	}
}

func TestProbe_EmitsCausalEvent(t *testing.T) {
	sup, _, logPath := newSupForTest(t)
	_ = sup.probe(context.Background(), ProbeFallback,
		fakeProbeResult{exitCode: 0}.runner)
	body := readQuotaLog(t, logPath)
	if !strings.Contains(body, `"type":"quota_probe"`) {
		t.Errorf("missing quota_probe event\n%s", body)
	}
	if !strings.Contains(body, "kind=fallback") {
		t.Errorf("kind=fallback not in detail\n%s", body)
	}
}

// ---------------------------------------------------------------------------
// ProbeSchedule.NextDelay — back-off curve
// ---------------------------------------------------------------------------

func TestProbeSchedule_FirstDelayUsesMin(t *testing.T) {
	sch := &ProbeSchedule{
		MinInterval: 10 * time.Minute,
		MaxInterval: 30 * time.Minute,
		rng:         func(int64) int64 { return 10 }, // factor=100, no jitter
	}
	d := sch.NextDelay(1, 0)
	if d != 10*time.Minute {
		t.Errorf("d = %v; want 10m", d)
	}
}

func TestProbeSchedule_BackoffGrowsBy3Halves(t *testing.T) {
	sch := &ProbeSchedule{
		MinInterval: 10 * time.Minute,
		MaxInterval: 30 * time.Minute,
		rng:         func(int64) int64 { return 10 }, // factor=100
	}
	// probe 2 with prev=10m → still floored at min (10m)
	if d := sch.NextDelay(2, 10*time.Minute); d != 15*time.Minute {
		t.Errorf("probe2: %v; want 15m", d)
	}
	// probe 3 with prev=15m → 22m30s, well under cap
	if d := sch.NextDelay(3, 15*time.Minute); d != 22*time.Minute+30*time.Second {
		t.Errorf("probe3: %v; want 22m30s", d)
	}
	// probe 4 with prev=22m30s → 33m45s, capped at 30m
	if d := sch.NextDelay(4, 22*time.Minute+30*time.Second); d != 30*time.Minute {
		t.Errorf("probe4: %v; want 30m (cap)", d)
	}
}

func TestProbeSchedule_JitterBoundsTo10Pct(t *testing.T) {
	cases := []struct {
		jitter int64
		min    time.Duration
		max    time.Duration
	}{
		// rng=0 → factor=90 → 9m
		{0, 9 * time.Minute, 9 * time.Minute},
		// rng=10 → factor=100 → 10m
		{10, 10 * time.Minute, 10 * time.Minute},
		// rng=20 → factor=110 → 11m
		{20, 11 * time.Minute, 11 * time.Minute},
	}
	for _, tc := range cases {
		t.Run("", func(t *testing.T) {
			sch := &ProbeSchedule{
				MinInterval: 10 * time.Minute,
				MaxInterval: 30 * time.Minute,
				rng:         func(int64) int64 { return tc.jitter },
			}
			d := sch.NextDelay(1, 0)
			if d < tc.min || d > tc.max {
				t.Errorf("rng=%d: d=%v want [%v, %v]", tc.jitter, d, tc.min, tc.max)
			}
		})
	}
}

func TestProbeSchedule_DefaultsApplied(t *testing.T) {
	sch := DefaultProbeSchedule()
	if sch.MinInterval != defaultProbeMinInterval {
		t.Errorf("MinInterval = %v; want %v", sch.MinInterval, defaultProbeMinInterval)
	}
	if sch.MaxInterval != defaultProbeMaxInterval {
		t.Errorf("MaxInterval = %v; want %v", sch.MaxInterval, defaultProbeMaxInterval)
	}
	// jitter() with nil rng must not panic.
	if got := sch.jitter(0); got != 0 {
		t.Errorf("jitter(0) = %d; want 0", got)
	}
}

// TestProbeKind_String_AllForms covers each enum value plus the unknown
// fallback so the renderer's switch can't silently drift.
func TestProbeKind_String_AllForms(t *testing.T) {
	cases := []struct {
		kind ProbeKind
		want string
	}{
		{ProbeVersion, "version"},
		{ProbeZeroTurn, "zero_turn"},
		{ProbeFallback, "fallback"},
		{ProbeKind(99), "unknown"},
	}
	for _, tc := range cases {
		if got := tc.kind.String(); got != tc.want {
			t.Errorf("ProbeKind(%d).String() = %q want %q", tc.kind, got, tc.want)
		}
	}
}

func TestProbeResult_String_AllForms(t *testing.T) {
	cases := []struct {
		r    ProbeResult
		want string
	}{
		{ProbeQuotaActive, "active"},
		{ProbeQuotaLifted, "lifted"},
		{ProbeError, "error"},
		{ProbeResult(99), "unknown"},
	}
	for _, tc := range cases {
		if got := tc.r.String(); got != tc.want {
			t.Errorf("ProbeResult(%d).String() = %q want %q", tc.r, got, tc.want)
		}
	}
}

// TestProbe_PublicEntryUsesDefaultRunner exercises the public Probe()
// wrapper. We point the supervisor at a binary that does not exist so
// runProbeCommand returns an exec error, which the wrapper maps to
// ProbeError. This gives the seam coverage without a network probe.
func TestProbe_PublicEntryUsesDefaultRunner(t *testing.T) {
	sup := &Supervisor{binary: "/no/such/binary/for/probe"}
	for _, kind := range []ProbeKind{ProbeVersion, ProbeZeroTurn, ProbeFallback} {
		t.Run(kind.String(), func(t *testing.T) {
			got := sup.Probe(context.Background(), kind)
			if got != ProbeError {
				t.Errorf("kind=%s: got %v; want ProbeError", kind, got)
			}
		})
	}
}

// TestRunProbeCommand_UnknownKindErrors covers the default branch of the
// switch — a future enum addition without a switch case would otherwise
// silently fall through to a wrong invocation.
func TestRunProbeCommand_UnknownKindErrors(t *testing.T) {
	exitCode, _, err := runProbeCommand(context.Background(), ProbeKind(99), "claude")
	if err == nil {
		t.Fatalf("err: nil; want unknown probe kind")
	}
	if exitCode != -1 {
		t.Errorf("exit: %d; want -1", exitCode)
	}
}

// ---------------------------------------------------------------------------
// IsRateLimitStderr — V3 vocabulary parity
// ---------------------------------------------------------------------------

func TestIsRateLimitStderr_DetectsV3Vocabulary(t *testing.T) {
	cases := []struct {
		input string
		want  bool
	}{
		{"", false},
		{"unrelated error", false},
		{"HTTP 429: rate limit exceeded", true},
		{"Error: rate_limit hit", true},
		{"quota exceeded", true},
		{"too many requests", true},
		{"capacity reached", true},
		{"upstream overloaded", true},
		{"USAGE LIMIT", true}, // case-insensitive
	}
	for _, tc := range cases {
		t.Run(tc.input, func(t *testing.T) {
			got := isRateLimitStderr(tc.input)
			if got != tc.want {
				t.Errorf("isRateLimitStderr(%q) = %v; want %v", tc.input, got, tc.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

func readQuotaLog(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}
