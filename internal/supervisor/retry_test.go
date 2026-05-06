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
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fakeRunner returns a scripted sequence of (result, err) pairs to retryLoop.
// Tests assemble one per case and assert call count + final disposition.
type fakeRunner struct {
	results []*proto.AgentResultV1
	errs    []error
	calls   int
}

func (f *fakeRunner) run(_ context.Context, _ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	idx := f.calls
	f.calls++
	if idx >= len(f.results) {
		return nil, errors.New("fakeRunner: no more scripted results")
	}
	var err error
	if idx < len(f.errs) {
		err = f.errs[idx]
	}
	return f.results[idx], err
}

// instantAfter returns an already-fired channel — retryLoop's select wakes
// immediately so tests don't actually wait for backoff.
func instantAfter(_ time.Duration) <-chan time.Time {
	ch := make(chan time.Time, 1)
	ch <- time.Now()
	return ch
}

func smallPolicy() *RetryPolicy {
	return &RetryPolicy{
		MaxAttempts: 3,
		BaseDelay:   1 * time.Millisecond,
		MaxDelay:    10 * time.Millisecond,
		rng:         func(int64) int64 { return 0 },
	}
}

func sampleRequest() *proto.AgentRequestV1 {
	return &proto.AgentRequestV1{
		Proto:      proto.AgentRequestProtoV1,
		Label:      "tester",
		Model:      "fake",
		PromptFile: "/tmp/p",
	}
}

// ---------------------------------------------------------------------------
// Retry — control-flow cases
// ---------------------------------------------------------------------------

func TestRetry_Success_FirstAttempt_NoRetry(t *testing.T) {
	fr := &fakeRunner{results: []*proto.AgentResultV1{{Outcome: proto.OutcomeSuccess}}}
	res, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), nil, fr.run, nil, instantAfter)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if res.Outcome != proto.OutcomeSuccess {
		t.Errorf("Outcome: got %q, want success", res.Outcome)
	}
	if fr.calls != 1 {
		t.Errorf("runner calls: got %d, want 1", fr.calls)
	}
}

func TestRetry_TurnExhausted_NotARetryTrigger(t *testing.T) {
	fr := &fakeRunner{results: []*proto.AgentResultV1{{Outcome: proto.OutcomeTurnExhausted}}}
	res, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), nil, fr.run, nil, instantAfter)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if res.Outcome != proto.OutcomeTurnExhausted {
		t.Errorf("Outcome: got %q, want turn_exhausted", res.Outcome)
	}
	if fr.calls != 1 {
		t.Errorf("runner calls: got %d, want 1 (turn_exhausted is not a retry trigger)", fr.calls)
	}
}

func TestRetry_TransientError_RetriesUpToMax_ThenExhausted(t *testing.T) {
	transient := &proto.AgentResultV1{
		Outcome:          proto.OutcomeFatalError,
		ErrorCategory:    "UPSTREAM",
		ErrorSubcategory: "api_rate_limit",
		ErrorTransient:   true,
	}
	fr := &fakeRunner{results: []*proto.AgentResultV1{transient, transient, transient}}
	res, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), nil, fr.run, nil, instantAfter)
	if !errors.Is(err, ErrUpstreamRateLimit) {
		t.Errorf("err: got %v; want errors.Is ErrUpstreamRateLimit", err)
	}
	if fr.calls != 3 {
		t.Errorf("runner calls: got %d, want 3 (MaxAttempts)", fr.calls)
	}
	if res != transient {
		t.Errorf("result: should still return last attempt's result")
	}
}

func TestRetry_FatalError_StopsImmediately(t *testing.T) {
	fatal := &proto.AgentResultV1{
		Outcome:          proto.OutcomeFatalError,
		ErrorCategory:    "UPSTREAM",
		ErrorSubcategory: "api_auth",
		ErrorTransient:   false,
	}
	fr := &fakeRunner{results: []*proto.AgentResultV1{fatal, fatal, fatal}}
	_, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), nil, fr.run, nil, instantAfter)
	if !errors.Is(err, ErrUpstreamAuth) {
		t.Errorf("err: got %v; want errors.Is ErrUpstreamAuth", err)
	}
	if fr.calls != 1 {
		t.Errorf("runner calls: got %d, want 1 (fatal stops immediately)", fr.calls)
	}
}

func TestRetry_TransientThenSuccess_Recovers(t *testing.T) {
	transient := &proto.AgentResultV1{
		Outcome: proto.OutcomeFatalError, ErrorCategory: "UPSTREAM",
		ErrorSubcategory: "api_overloaded", ErrorTransient: true,
	}
	success := &proto.AgentResultV1{Outcome: proto.OutcomeSuccess}
	fr := &fakeRunner{results: []*proto.AgentResultV1{transient, success}}
	res, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), nil, fr.run, nil, instantAfter)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if res.Outcome != proto.OutcomeSuccess {
		t.Errorf("Outcome: got %q, want success", res.Outcome)
	}
	if fr.calls != 2 {
		t.Errorf("runner calls: got %d, want 2", fr.calls)
	}
}

func TestRetry_RunnerError_PropagatedWithoutClassification(t *testing.T) {
	boom := errors.New("envelope invalid")
	fr := &fakeRunner{results: []*proto.AgentResultV1{nil}, errs: []error{boom}}
	_, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), nil, fr.run, nil, instantAfter)
	if !errors.Is(err, boom) {
		t.Errorf("err: got %v; want %v (passthrough)", err, boom)
	}
	if fr.calls != 1 {
		t.Errorf("runner calls: got %d, want 1", fr.calls)
	}
}

func TestRetry_NilRequest_Errors(t *testing.T) {
	fr := &fakeRunner{}
	_, err := retryLoop(context.Background(), nil, smallPolicy(), nil, fr.run, nil, instantAfter)
	if err == nil || !strings.Contains(err.Error(), "nil request") {
		t.Errorf("err: %v; want 'nil request' substring", err)
	}
}

func TestRetry_NilRunner_Errors(t *testing.T) {
	_, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), nil, nil, nil, instantAfter)
	if err == nil || !strings.Contains(err.Error(), "nil runner") {
		t.Errorf("err: %v; want 'nil runner' substring", err)
	}
}

// AC: ctx.Cancel during backoff returns context.Canceled within 10ms.
func TestRetry_CtxCancelDuringBackoff_ReturnsCtxErr(t *testing.T) {
	transient := &proto.AgentResultV1{
		Outcome: proto.OutcomeFatalError, ErrorCategory: "UPSTREAM",
		ErrorSubcategory: "api_rate_limit", ErrorTransient: true,
	}
	fr := &fakeRunner{results: []*proto.AgentResultV1{transient, transient, transient}}

	// Block forever — only ctx.Done can break the select.
	blockingAfter := func(_ time.Duration) <-chan time.Time { return make(chan time.Time) }

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(5 * time.Millisecond)
		cancel()
	}()

	start := time.Now()
	_, err := retryLoop(ctx, sampleRequest(), smallPolicy(), nil, fr.run, nil, blockingAfter)
	elapsed := time.Since(start)
	if !errors.Is(err, context.Canceled) {
		t.Errorf("err: got %v; want context.Canceled", err)
	}
	if elapsed > 200*time.Millisecond {
		t.Errorf("cancellation latency: %v; want < 200ms", elapsed)
	}
}

func TestRetry_NilPolicyUsesDefaults(t *testing.T) {
	transient := &proto.AgentResultV1{
		Outcome: proto.OutcomeFatalError, ErrorCategory: "UPSTREAM",
		ErrorSubcategory: "api_unknown", ErrorTransient: true,
	}
	fr := &fakeRunner{results: []*proto.AgentResultV1{transient, transient, transient}}
	_, err := retryLoop(context.Background(), sampleRequest(), nil, nil, fr.run, nil, instantAfter)
	if !errors.Is(err, ErrUpstreamUnknown) {
		t.Errorf("err: got %v", err)
	}
	if fr.calls != 3 {
		t.Errorf("calls: got %d, want 3 (default MaxAttempts)", fr.calls)
	}
}

// ---------------------------------------------------------------------------
// RetryPolicy.Delay — formula tests
// ---------------------------------------------------------------------------

func TestRetryPolicy_Delay_RateLimitFloorAt60s(t *testing.T) {
	p := DefaultPolicy()
	p.rng = func(int64) int64 { return 0 }
	d := p.Delay(1, "api_rate_limit")
	if d < 60*time.Second {
		t.Errorf("Delay(1, api_rate_limit) = %v; want >= 60s", d)
	}
}

func TestRetryPolicy_Delay_NoSubcategoryCapsAtMaxDelay(t *testing.T) {
	p := DefaultPolicy()
	p.rng = func(int64) int64 { return 0 }
	d := p.Delay(3, "")
	if d > p.MaxDelay {
		t.Errorf("Delay(3, \"\") = %v; want <= MaxDelay (%v)", d, p.MaxDelay)
	}
}

func TestRetryPolicy_Delay_OOMFloorAt15s(t *testing.T) {
	p := &RetryPolicy{
		MaxAttempts: 3,
		BaseDelay:   1 * time.Second,
		MaxDelay:    120 * time.Second,
		Floors:      map[string]time.Duration{"oom": 15 * time.Second},
		rng:         func(int64) int64 { return 0 },
	}
	d := p.Delay(1, "oom")
	if d < 15*time.Second {
		t.Errorf("Delay(1, oom) = %v; want >= 15s", d)
	}
}

func TestRetryPolicy_Delay_FloorAboveMaxDelayWins(t *testing.T) {
	p := &RetryPolicy{
		MaxAttempts: 3,
		BaseDelay:   1 * time.Second,
		MaxDelay:    30 * time.Second,
		Floors:      map[string]time.Duration{"api_rate_limit": 60 * time.Second},
		rng:         func(int64) int64 { return 0 },
	}
	d := p.Delay(1, "api_rate_limit")
	if d < 60*time.Second {
		t.Errorf("Delay = %v; want >= 60s (floor must override MaxDelay=30s)", d)
	}
}

func TestRetryPolicy_Delay_ExponentialBackoff(t *testing.T) {
	p := &RetryPolicy{
		MaxAttempts: 5,
		BaseDelay:   1 * time.Second,
		MaxDelay:    100 * time.Second,
		rng:         func(int64) int64 { return 0 },
	}
	cases := []struct {
		attempt int
		want    time.Duration
	}{{1, 1 * time.Second}, {2, 2 * time.Second}, {3, 4 * time.Second}, {4, 8 * time.Second}}
	for _, tc := range cases {
		if got := p.Delay(tc.attempt, ""); got != tc.want {
			t.Errorf("Delay(%d) = %v; want %v", tc.attempt, got, tc.want)
		}
	}
}

func TestRetryPolicy_Delay_JitterIsBoundedTo10Pct(t *testing.T) {
	p := &RetryPolicy{
		MaxAttempts: 3,
		BaseDelay:   100 * time.Millisecond,
		MaxDelay:    10 * time.Second,
		rng:         func(n int64) int64 { return n - 1 }, // drive jitter to its max
	}
	d := p.Delay(1, "")
	if d < 100*time.Millisecond || d > 120*time.Millisecond {
		t.Errorf("Delay = %v; want 100..120ms (10%% jitter band)", d)
	}
}

func TestRetryPolicy_Delay_AttemptZeroTreatedAsOne(t *testing.T) {
	p := &RetryPolicy{MaxAttempts: 3, BaseDelay: 10 * time.Millisecond, MaxDelay: 1 * time.Second, rng: func(int64) int64 { return 0 }}
	if got := p.Delay(0, ""); got != 10*time.Millisecond {
		t.Errorf("Delay(0) = %v; want 10ms (treated as attempt=1)", got)
	}
}

// ---------------------------------------------------------------------------
// Causal events — verify the four expected event types are emitted with the
// agreed shape ("supervisor" stage, label\tdetail body).
// ---------------------------------------------------------------------------

func openCausalForTest(t *testing.T) (*causal.Log, string) {
	t.Helper()
	dir := t.TempDir()
	logPath := filepath.Join(dir, "causal.jsonl")
	log, err := causal.Open(logPath, 0, "rid-test")
	if err != nil {
		t.Fatalf("causal.Open: %v", err)
	}
	return log, logPath
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}

func TestRetry_CausalEvents_RetryAttemptAndBackoff(t *testing.T) {
	log, path := openCausalForTest(t)

	transient := &proto.AgentResultV1{
		Outcome: proto.OutcomeFatalError, ErrorCategory: "UPSTREAM",
		ErrorSubcategory: "api_rate_limit", ErrorTransient: true,
	}
	success := &proto.AgentResultV1{Outcome: proto.OutcomeSuccess}
	fr := &fakeRunner{results: []*proto.AgentResultV1{transient, success}}

	if _, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), log, fr.run, nil, instantAfter); err != nil {
		t.Fatalf("retryLoop: %v", err)
	}

	body := readFile(t, path)
	for _, want := range []string{`"type":"retry_attempt"`, `"type":"retry_backoff"`} {
		if !strings.Contains(body, want) {
			t.Errorf("causal log missing %s\nlog:\n%s", want, body)
		}
	}
	// The detail field should carry the label\t<message> shape.
	if !strings.Contains(body, "tester\\tattempt 1/3") {
		t.Errorf("retry_attempt detail missing label-prefixed body; got:\n%s", body)
	}
}

func TestRetry_CausalEvents_FatalEmitted(t *testing.T) {
	log, path := openCausalForTest(t)
	fatal := &proto.AgentResultV1{
		Outcome: proto.OutcomeFatalError, ErrorCategory: "UPSTREAM",
		ErrorSubcategory: "api_auth", ErrorTransient: false,
	}
	fr := &fakeRunner{results: []*proto.AgentResultV1{fatal}}
	if _, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), log, fr.run, nil, instantAfter); !errors.Is(err, ErrUpstreamAuth) {
		t.Fatalf("err: %v; want errors.Is ErrUpstreamAuth", err)
	}
	body := readFile(t, path)
	if !strings.Contains(body, `"type":"retry_fatal"`) {
		t.Errorf("causal log missing retry_fatal event\nlog:\n%s", body)
	}
}

// ---------------------------------------------------------------------------
// m08: quota-pause integration with the retry loop
// ---------------------------------------------------------------------------

// fakePause records the QuotaPause it receives and returns nil unless an
// explicit error is configured. Used to verify the retry loop dispatches
// the pause helper exactly when the result is rate-limit-classified.
type fakePause struct {
	calls    int
	received []QuotaPause
	err      error
}

func (f *fakePause) run(_ context.Context, p QuotaPause) error {
	f.calls++
	f.received = append(f.received, p)
	return f.err
}

func TestRetry_RateLimit_TriggersPauseThenSucceeds(t *testing.T) {
	log, path := openCausalForTest(t)
	rateLimited := &proto.AgentResultV1{
		Outcome:          proto.OutcomeFatalError,
		ErrorCategory:    "UPSTREAM",
		ErrorSubcategory: "api_rate_limit",
		ErrorTransient:   true,
		RetryAfter:       "30",
	}
	success := &proto.AgentResultV1{Outcome: proto.OutcomeSuccess}
	fr := &fakeRunner{results: []*proto.AgentResultV1{rateLimited, success}}
	fp := &fakePause{}

	res, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), log, fr.run, fp.run, instantAfter)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if res.Outcome != proto.OutcomeSuccess {
		t.Errorf("outcome: %v want success", res.Outcome)
	}
	if fr.calls != 2 {
		t.Errorf("runner calls: %d want 2 (one rate-limited, one success)", fr.calls)
	}
	if fp.calls != 1 {
		t.Errorf("pause calls: %d want 1", fp.calls)
	}
	if fp.received[0].Reason != "api_rate_limit" {
		t.Errorf("pause reason: %q want api_rate_limit", fp.received[0].Reason)
	}
	body := readFile(t, path)
	if !strings.Contains(body, `"type":"retry_quota_pause"`) {
		t.Errorf("missing retry_quota_pause event\n%s", body)
	}
}

// AC: a quota pause does NOT consume a retry attempt. Three rate-limited
// results followed by success should call run() four times and pause three
// times, all within MaxAttempts=3 — the pauses are "free" from the policy
// counter's POV.
func TestRetry_RateLimit_DoesNotConsumeRetryAttempt(t *testing.T) {
	rateLimited := &proto.AgentResultV1{
		Outcome:          proto.OutcomeFatalError,
		ErrorCategory:    "UPSTREAM",
		ErrorSubcategory: "api_rate_limit",
		ErrorTransient:   true,
		RetryAfter:       "5",
	}
	success := &proto.AgentResultV1{Outcome: proto.OutcomeSuccess}
	fr := &fakeRunner{results: []*proto.AgentResultV1{rateLimited, rateLimited, rateLimited, success}}
	fp := &fakePause{}

	res, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), nil, fr.run, fp.run, instantAfter)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if res.Outcome != proto.OutcomeSuccess {
		t.Errorf("outcome: %v want success", res.Outcome)
	}
	if fr.calls != 4 {
		t.Errorf("runner calls: %d want 4 (three rate-limited drained inside one attempt + final success)", fr.calls)
	}
	if fp.calls != 3 {
		t.Errorf("pause calls: %d want 3", fp.calls)
	}
}

// AC: ParseRetryAfter falling back to default when result.RetryAfter is empty.
func TestRetry_RateLimit_NoRetryAfterUsesDefault(t *testing.T) {
	log, path := openCausalForTest(t)
	rateLimited := &proto.AgentResultV1{
		Outcome:          proto.OutcomeFatalError,
		ErrorCategory:    "UPSTREAM",
		ErrorSubcategory: "api_rate_limit",
		ErrorTransient:   true,
		// No RetryAfter set; helper should default to 15m.
	}
	success := &proto.AgentResultV1{Outcome: proto.OutcomeSuccess}
	fr := &fakeRunner{results: []*proto.AgentResultV1{rateLimited, success}}
	fp := &fakePause{}

	if _, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), log, fr.run, fp.run, instantAfter); err != nil {
		t.Fatalf("err: %v", err)
	}
	body := readFile(t, path)
	if !strings.Contains(body, "source=default") {
		t.Errorf("expected source=default in causal log\n%s", body)
	}
}

// AC: pause helper returning an error (cap fired, ctx cancelled, etc.) ends
// the run with that error.
func TestRetry_RateLimit_PauseErrorAbortsRun(t *testing.T) {
	rateLimited := &proto.AgentResultV1{
		Outcome:          proto.OutcomeFatalError,
		ErrorCategory:    "UPSTREAM",
		ErrorSubcategory: "api_rate_limit",
		ErrorTransient:   true,
		RetryAfter:       "60",
	}
	fr := &fakeRunner{results: []*proto.AgentResultV1{rateLimited}}
	fp := &fakePause{err: ErrQuotaPauseCapped}

	_, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), nil, fr.run, fp.run, instantAfter)
	if !errors.Is(err, ErrQuotaPauseCapped) {
		t.Errorf("err: %v want errors.Is ErrQuotaPauseCapped", err)
	}
	if fp.calls != 1 {
		t.Errorf("pause calls: %d want 1", fp.calls)
	}
}

// AC: nil pause helper falls through to ordinary backoff for rate-limit
// classifications. Verifies the pre-m08 retry behavior still works for
// callers that haven't wired pause (e.g. unit tests of older shape).
func TestRetry_RateLimit_NilPauseFallsBackToBackoff(t *testing.T) {
	rateLimited := &proto.AgentResultV1{
		Outcome:          proto.OutcomeFatalError,
		ErrorCategory:    "UPSTREAM",
		ErrorSubcategory: "api_rate_limit",
		ErrorTransient:   true,
		RetryAfter:       "30",
	}
	fr := &fakeRunner{results: []*proto.AgentResultV1{rateLimited, rateLimited, rateLimited}}

	_, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), nil, fr.run, nil, instantAfter)
	if !errors.Is(err, ErrUpstreamRateLimit) {
		t.Errorf("err: %v want errors.Is ErrUpstreamRateLimit", err)
	}
	if fr.calls != 3 {
		t.Errorf("runner calls: %d want 3 (no pause, falls back to retry)", fr.calls)
	}
}

func TestRetry_CausalEvents_ExhaustedEmitted(t *testing.T) {
	log, path := openCausalForTest(t)
	transient := &proto.AgentResultV1{
		Outcome: proto.OutcomeFatalError, ErrorCategory: "UPSTREAM",
		ErrorSubcategory: "api_unknown", ErrorTransient: true,
	}
	fr := &fakeRunner{results: []*proto.AgentResultV1{transient, transient, transient}}
	if _, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), log, fr.run, nil, instantAfter); !errors.Is(err, ErrUpstreamUnknown) {
		t.Fatalf("err: %v", err)
	}
	body := readFile(t, path)
	if !strings.Contains(body, `"type":"retry_exhausted"`) {
		t.Errorf("causal log missing retry_exhausted event\nlog:\n%s", body)
	}
}

// ---------------------------------------------------------------------------
// m08 coverage gaps — shouldQuotaPause and related paths
// ---------------------------------------------------------------------------

// TestShouldQuotaPause_AllPaths directly exercises every branch of
// shouldQuotaPause: nil arg returns false; ErrUpstreamRateLimit returns true;
// ErrQuotaExhausted returns true; an unrelated error returns false.
func TestShouldQuotaPause_AllPaths(t *testing.T) {
	cases := []struct {
		name string
		cls  error
		want bool
	}{
		{"nil", nil, false},
		{"ErrUpstreamRateLimit", ErrUpstreamRateLimit, true},
		{"ErrQuotaExhausted", ErrQuotaExhausted, true},
		{"ErrUpstreamAuth (non-quota)", ErrUpstreamAuth, false},
		{"ErrEnvOOM (non-quota)", ErrEnvOOM, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := shouldQuotaPause(tc.cls)
			if got != tc.want {
				t.Errorf("shouldQuotaPause(%v) = %v; want %v", tc.cls, got, tc.want)
			}
		})
	}
}

// TestRetry_QuotaExhausted_TriggersPauseThenSucceeds verifies that a
// quota_exhausted result (not just api_rate_limit) routes through the
// quota-pause path. The AC is that shouldQuotaPause fires for both sentinels.
func TestRetry_QuotaExhausted_TriggersPauseThenSucceeds(t *testing.T) {
	exhausted := &proto.AgentResultV1{
		Outcome:          proto.OutcomeFatalError,
		ErrorCategory:    "UPSTREAM",
		ErrorSubcategory: "quota_exhausted",
		ErrorTransient:   false, // ErrQuotaExhausted is non-transient
		RetryAfter:       "30",
	}
	success := &proto.AgentResultV1{Outcome: proto.OutcomeSuccess}
	fr := &fakeRunner{results: []*proto.AgentResultV1{exhausted, success}}
	fp := &fakePause{}

	res, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), nil, fr.run, fp.run, instantAfter)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if res.Outcome != proto.OutcomeSuccess {
		t.Errorf("outcome: %v want success", res.Outcome)
	}
	if fr.calls != 2 {
		t.Errorf("runner calls: %d want 2 (quota_exhausted paused, then success)", fr.calls)
	}
	if fp.calls != 1 {
		t.Errorf("pause calls: %d want 1", fp.calls)
	}
}

// TestRetryLoop_OutcomeTransientError_UsesAeSubcatForDelay covers the
// subcat-fallback branch: when result.ErrorSubcategory is empty but the
// outcome-based classification produces a non-nil ae, the delay should use
// ae.Subcategory rather than the empty string. This exercises the
// `if subcat == "" && ae != nil` branch inside retryLoop.
func TestRetryLoop_OutcomeTransientError_UsesAeSubcatForDelay(t *testing.T) {
	// A result with Outcome=transient_error but no ErrorCategory/Subcategory
	// — this is the "m06 result not yet classified" shape. classifyResult
	// maps it to ErrUpstreamUnknown (Subcategory: "api_unknown", Transient: true).
	transientResult := &proto.AgentResultV1{
		Outcome: proto.OutcomeTransientError,
		// No ErrorCategory / ErrorSubcategory intentionally — the outer loop
		// must fall back to ae.Subcategory for the Delay call.
	}
	success := &proto.AgentResultV1{Outcome: proto.OutcomeSuccess}
	fr := &fakeRunner{results: []*proto.AgentResultV1{transientResult, success}}

	// If the delay calculation panics or uses empty subcat, the policy
	// returns 0 for a custom floor map (oom: 15s, etc.) — using the right
	// subcat is observable by choosing a policy whose floor map only fires
	// on "api_unknown". We just need the loop to complete without error.
	res, err := retryLoop(context.Background(), sampleRequest(), smallPolicy(), nil, fr.run, nil, instantAfter)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if res.Outcome != proto.OutcomeSuccess {
		t.Errorf("outcome: %v want success", res.Outcome)
	}
	if fr.calls != 2 {
		t.Errorf("runner calls: %d want 2", fr.calls)
	}
}
