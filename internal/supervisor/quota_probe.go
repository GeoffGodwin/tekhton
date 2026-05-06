package supervisor

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"os/exec"
	"strings"
	"time"

	"github.com/geoffgodwin/tekhton/internal/causal"
)

// V3 parity defaults — match QUOTA_PROBE_MIN_INTERVAL / QUOTA_PROBE_MAX_INTERVAL
// from lib/config_defaults.sh (10m floor, 30m cap). The 1.5× back-off matches
// _quota_next_probe_delay in lib/quota_probe.sh; we encode it as *3/2 in
// integer ns rather than a float multiplier to stay byte-equivalent with the
// bash math.
const (
	defaultProbeMinInterval = 10 * time.Minute
	defaultProbeMaxInterval = 30 * time.Minute
)

// ProbeKind selects which strategy Probe uses to test whether the upstream
// quota has been lifted. The cheapest probe (Version) is the default; the
// fallback path actually consumes API quota and is only meant as a last
// resort matching V3's mode-detection logic.
type ProbeKind int

const (
	// ProbeVersion runs `claude --version` — zero tokens, zero auth.
	ProbeVersion ProbeKind = iota
	// ProbeZeroTurn runs `claude --max-turns 0` with an empty prompt.
	// Slightly more expensive; catches the case where --version works
	// but real invocations still 429.
	ProbeZeroTurn
	// ProbeFallback runs a tiny real invocation. Burns API quota; the
	// caller MUST rate-limit it externally (back-off floor).
	ProbeFallback
)

// String returns the V3-equivalent name (`version` / `zero_turn` / `fallback`)
// so causal events and CLI output line up with the bash side.
func (k ProbeKind) String() string {
	switch k {
	case ProbeVersion:
		return "version"
	case ProbeZeroTurn:
		return "zero_turn"
	case ProbeFallback:
		return "fallback"
	}
	return "unknown"
}

// ProbeResult is the outcome of one Probe call.
type ProbeResult int

const (
	// ProbeQuotaActive — the upstream is still rate-limited.
	ProbeQuotaActive ProbeResult = iota
	// ProbeQuotaLifted — the upstream accepted the probe; quota appears
	// available. Callers may attempt the real run.
	ProbeQuotaLifted
	// ProbeError — the probe itself failed in an ambiguous way (e.g. the
	// claude binary is missing). Callers should treat this as
	// quota-still-active for safety.
	ProbeError
)

// String returns "active" / "lifted" / "error" — used by quota CLI output.
func (r ProbeResult) String() string {
	switch r {
	case ProbeQuotaActive:
		return "active"
	case ProbeQuotaLifted:
		return "lifted"
	case ProbeError:
		return "error"
	}
	return "unknown"
}

// probeRunner is the test seam — production substitutes exec.CommandContext
// via runProbeCommand; tests inject a fake that returns scripted (exitCode,
// stderr) tuples.
type probeRunner func(ctx context.Context, kind ProbeKind, binary string) (exitCode int, stderr string, err error)

// Probe runs one quota probe of the requested kind and reports the result.
// The agent binary is taken from the supervisor (TEKHTON_AGENT_BINARY env
// override applies). A nonzero probe exit + a recognizable rate-limit
// signature in stderr means the upstream is still rate-limited; any other
// nonzero exit (binary missing, network down) returns ProbeError so the
// caller can decide whether to keep waiting or escalate.
func (s *Supervisor) Probe(ctx context.Context, kind ProbeKind) ProbeResult {
	return s.probe(ctx, kind, runProbeCommand)
}

// probe is the testable workhorse — same shape as Probe but takes the
// runner as an explicit dep injection. Tests pass a fake; Probe passes
// runProbeCommand.
func (s *Supervisor) probe(ctx context.Context, kind ProbeKind, runner probeRunner) ProbeResult {
	if runner == nil {
		runner = runProbeCommand
	}
	exitCode, stderr, err := runner(ctx, kind, s.binary)
	emitProbeEvent(s.causal, kind, exitCode, err)

	if err != nil {
		// Couldn't even run the probe — the kernel returned ENOENT or
		// the context fired. Treat as error rather than active so the
		// caller can fall through to a longer wait.
		return ProbeError
	}
	if exitCode == 0 {
		return ProbeQuotaLifted
	}
	if isRateLimitStderr(stderr) {
		return ProbeQuotaActive
	}
	// Nonzero exit but the stderr doesn't smell like a rate limit: a
	// flaky probe (network blip, transient 5xx). Conservatively return
	// ProbeError so the caller doesn't immediately re-attempt the real
	// invocation and waste budget.
	return ProbeError
}

// runProbeCommand executes the actual claude probe. The argument shape
// mirrors lib/quota_probe.sh _quota_probe so the V3 ↔ Go behavior is
// observably identical at the seam.
func runProbeCommand(ctx context.Context, kind ProbeKind, binary string) (int, string, error) {
	if binary == "" {
		binary = "claude"
	}
	var cmd *exec.Cmd
	switch kind {
	case ProbeVersion:
		cmd = exec.CommandContext(ctx, binary, "--version")
	case ProbeZeroTurn:
		cmd = exec.CommandContext(ctx, binary,
			"--max-turns", "0", "--output-format", "text", "-p", "")
	case ProbeFallback:
		cmd = exec.CommandContext(ctx, binary,
			"--max-turns", "1", "--output-format", "json", "-p", "respond with OK")
	default:
		return -1, "", fmt.Errorf("supervisor: unknown probe kind %d", kind)
	}
	var stderr strings.Builder
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err == nil {
		return 0, stderr.String(), nil
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode(), stderr.String(), nil
	}
	// The exec layer itself failed (ENOENT etc.) — return the error so
	// the caller maps to ProbeError.
	return -1, stderr.String(), err
}

// rateLimitMarkers is the case-insensitive vocabulary lib/quota.sh
// is_rate_limit_error matches against. The Go-side detection mirrors that
// regex token-by-token so a stderr that bash classifies as a rate limit
// also classifies as a rate limit here.
var rateLimitMarkers = []string{
	"rate limit", "rate-limit", "rate_limit",
	"quota exceed", "quota-exceed",
	"usage limit", "usage-limit",
	"too many requests",
	"429",
	"capacity",
	"overloaded",
}

// isRateLimitStderr reports whether stderr contains any of the V3 rate-limit
// markers. The check is case-insensitive on a single-pass lower-case copy —
// for the small stderr volumes a probe produces this is cheap and matches
// V3's `grep -iE` semantics.
func isRateLimitStderr(stderr string) bool {
	if stderr == "" {
		return false
	}
	low := strings.ToLower(stderr)
	for _, m := range rateLimitMarkers {
		if strings.Contains(low, m) {
			return true
		}
	}
	return false
}

// emitProbeEvent funnels probe events through a single shape. quota_probe
// is the well-known type; the body carries the kind and outcome so a TUI
// or dashboard consumer can render the probe schedule without re-parsing
// supervisor logs.
func emitProbeEvent(log *causal.Log, kind ProbeKind, exitCode int, err error) {
	if log == nil {
		return
	}
	detail := fmt.Sprintf("kind=%s exit=%d", kind, exitCode)
	if err != nil {
		detail += " err=" + err.Error()
	}
	_, _ = log.Emit(causal.EmitInput{
		Stage:  "supervisor",
		Type:   "quota_probe",
		Detail: detail,
	})
}

// ProbeSchedule is the back-off schedule for repeated probes during a long
// pause. The defaults match V3 (lib/config_defaults.sh: QUOTA_PROBE_MIN_INTERVAL,
// QUOTA_PROBE_MAX_INTERVAL). Probe 1 fires at MinInterval; subsequent probes
// grow 1.5× up to MaxInterval, with ±10% jitter on every non-trivial delay
// so multiple supervisors hitting the same quota window don't synchronize.
type ProbeSchedule struct {
	MinInterval time.Duration
	MaxInterval time.Duration

	// rng is an injectable source for jitter — tests pass a deterministic
	// Int63n; production uses math/rand.
	rng func(int64) int64
}

// DefaultProbeSchedule returns a schedule with V3-equivalent floor/ceiling.
func DefaultProbeSchedule() *ProbeSchedule {
	return &ProbeSchedule{
		MinInterval: defaultProbeMinInterval,
		MaxInterval: defaultProbeMaxInterval,
	}
}

// NextDelay returns the wait before the (probeNum+1)-th probe. probeNum is
// 1-based: NextDelay(1, _) returns the wait between probe 1 and probe 2,
// and so on. prevDelay is the previous delay; pass 0 when probeNum<=1.
func (sch *ProbeSchedule) NextDelay(probeNum int, prevDelay time.Duration) time.Duration {
	min := sch.MinInterval
	if min <= 0 {
		min = defaultProbeMinInterval
	}
	max := sch.MaxInterval
	if max <= 0 {
		max = defaultProbeMaxInterval
	}
	if max < min {
		max = min
	}

	var d time.Duration
	if probeNum <= 1 {
		d = min
	} else {
		base := prevDelay
		if base <= 0 {
			base = min
		}
		// 1.5× scales as multiply-by-3-divide-by-2 in nanoseconds — keeps
		// the integer math byte-equivalent with the bash version.
		d = (base * 3) / 2
		if d < min {
			d = min
		}
	}
	if d > max {
		d = max
	}

	// ±10% jitter: factor in [0.9, 1.1).
	jitter := sch.jitter(21) // 0..20 inclusive → 90..110 / 100
	factor := 90 + jitter
	d = d * time.Duration(factor) / 100
	if d <= 0 {
		d = time.Second
	}
	return d
}

// jitter returns a uniform integer in [0, n). Production uses math/rand;
// tests substitute a deterministic source via sch.rng.
func (sch *ProbeSchedule) jitter(n int64) int64 {
	if n <= 0 {
		return 0
	}
	if sch.rng != nil {
		return sch.rng(n)
	}
	// G404: jitter is not security-sensitive — math/rand is appropriate.
	//nolint:gosec
	return rand.Int63n(n)
}
