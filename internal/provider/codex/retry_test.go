package codex

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// --- DefaultRetryPolicy contract tests ---

// TestDefaultRetryPolicy_RetryableSet verifies that the documented retryable
// subcategory set matches the acceptance criteria: QUOTA and OVERLOADED are
// retryable; AUTH and BAD_REQUEST are not.
func TestDefaultRetryPolicy_RetryableSet(t *testing.T) {
	p := DefaultRetryPolicy()

	retryable := []string{"QUOTA", "OVERLOADED", "NETWORK", "STREAM", "RETRY_EXHAUSTED", "UNTYPED", "SERVER_5XX"}
	for _, sub := range retryable {
		if !p.RetryableSubcategories[sub] {
			t.Errorf("RetryableSubcategories[%q] = false, want true", sub)
		}
	}

	nonRetryable := []string{"AUTH", "BAD_REQUEST", "CONTEXT_OVERFLOW", "POLICY", "SANDBOX", "CONTEXT"}
	for _, sub := range nonRetryable {
		if p.RetryableSubcategories[sub] {
			t.Errorf("RetryableSubcategories[%q] = true, want false", sub)
		}
	}
}

// --- backoffWithJitter tests ---

// TestBackoffWithJitter_ExponentialGrowth verifies that backoffWithJitter
// produces deterministic exponential durations when jitter is disabled and
// that they are bounded by maxDelay.
func TestBackoffWithJitter_ExponentialGrowth(t *testing.T) {
	base := 100 * time.Millisecond
	maxDelay := 10 * time.Second

	// With jitter=0 the sequence must be exactly base * 2^(attempt-1), capped.
	for attempt := 1; attempt <= 6; attempt++ {
		got := backoffWithJitter(base, attempt, maxDelay, 0)
		shift := attempt - 1
		if shift > 10 {
			shift = 10
		}
		want := base << shift
		if want > maxDelay {
			want = maxDelay
		}
		if got != want {
			t.Errorf("attempt %d: backoffWithJitter = %v, want %v", attempt, got, want)
		}
	}
}

// TestBackoffWithJitter_NeverNegative verifies that with aggressive jitter the
// result is never negative (implementation clamps to base on underflow).
func TestBackoffWithJitter_NeverNegative(t *testing.T) {
	base := 1 * time.Second
	maxDelay := 5 * time.Second

	for attempt := 1; attempt <= 20; attempt++ {
		got := backoffWithJitter(base, attempt, maxDelay, 0.5)
		if got < 0 {
			t.Errorf("attempt %d: got negative duration %v; must be ≥ 0", attempt, got)
		}
	}
}

// TestBackoffWithJitter_BoundedByMaxDelay verifies that without jitter the
// duration never exceeds maxDelay.
func TestBackoffWithJitter_BoundedByMaxDelay(t *testing.T) {
	base := 100 * time.Millisecond
	maxDelay := 500 * time.Millisecond

	for attempt := 1; attempt <= 30; attempt++ {
		got := backoffWithJitter(base, attempt, maxDelay, 0)
		if got > maxDelay {
			t.Errorf("attempt %d: duration %v exceeds maxDelay %v", attempt, got, maxDelay)
		}
	}
}

// --- RunAgentWithRetry tests using shell stubs ---

// stubSuccess builds a shell stub that emits a successful Codex run
// (task_started + task_complete → OutcomeSuccess).
func stubSuccess(t *testing.T, dir string) string {
	t.Helper()
	return makeShellStub(t, dir, "success.sh",
		`printf '{"id":"s1","msg":{"type":"task_started","turn_id":"1"}}\n'
printf '{"id":"s1","msg":{"type":"task_complete","turn_id":"1","duration_ms":10}}\n'`)
}

// countNewlines counts the number of newline-terminated lines in data.
func countNewlines(data []byte) int {
	return bytes.Count(data, []byte("\n"))
}

// TestRunAgentWithRetry_SuccessOnFirstAttempt verifies that when the first
// attempt succeeds, RunAgentWithRetry returns OutcomeSuccess without retrying.
func TestRunAgentWithRetry_SuccessOnFirstAttempt(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()
	stub := stubSuccess(t, dir)
	p := NewWithBinary(stub)

	policy := &RetryPolicy{
		MaxAttempts:            3,
		BaseDelay:              1 * time.Millisecond,
		MaxDelay:               10 * time.Millisecond,
		JitterFraction:         0,
		RetryableSubcategories: map[string]bool{"QUOTA": true},
	}
	req := &provider.Request{
		Prompt:           "test",
		ProviderSpecific: map[string]string{"codex.output_last_message": filepath.Join(dir, "last.md")},
	}

	res, err := p.RunAgentWithRetry(context.Background(), req, policy)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Outcome != provider.OutcomeSuccess {
		t.Errorf("Outcome = %v, want OutcomeSuccess", res.Outcome)
	}
}

// TestRunAgentWithRetry_RetriesUpToMax verifies that RunAgentWithRetry calls
// RunAgent up to MaxAttempts times when each attempt returns a retryable
// subcategory (QUOTA). The stub counts invocations via a counter file.
func TestRunAgentWithRetry_RetriesUpToMax(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()
	counterFile := filepath.Join(dir, "count.txt")

	stub := makeShellStub(t, dir, "quota_loop.sh",
		`echo x >> `+counterFile+`
printf '{"id":"s1","msg":{"type":"error","message":"quota","codex_error_info":"usage_limit_exceeded"}}\n'`)

	p := NewWithBinary(stub)
	policy := &RetryPolicy{
		MaxAttempts:            3,
		BaseDelay:              1 * time.Millisecond,
		MaxDelay:               5 * time.Millisecond,
		JitterFraction:         0,
		RetryableSubcategories: map[string]bool{"QUOTA": true},
	}
	req := &provider.Request{
		Prompt:           "test",
		ProviderSpecific: map[string]string{"codex.output_last_message": filepath.Join(dir, "last.md")},
	}

	res, err := p.RunAgentWithRetry(context.Background(), req, policy)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.ErrorSubcategory != "QUOTA" {
		t.Errorf("ErrorSubcategory = %q, want %q", res.ErrorSubcategory, "QUOTA")
	}

	data, readErr := os.ReadFile(counterFile)
	if readErr != nil {
		t.Fatalf("read counter file: %v", readErr)
	}
	count := countNewlines(data)
	if count != 3 {
		t.Errorf("invocation count = %d, want 3 (MaxAttempts)", count)
	}
}

// TestRunAgentWithRetry_NoRetryForNonRetryable verifies that RunAgentWithRetry
// returns immediately (1 invocation) when ErrorSubcategory is AUTH, which is
// not in the retryable set.
func TestRunAgentWithRetry_NoRetryForNonRetryable(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()
	counterFile := filepath.Join(dir, "count.txt")

	stub := makeShellStub(t, dir, "auth_err.sh",
		`echo x >> `+counterFile+`
printf '{"id":"s1","msg":{"type":"error","message":"unauthorized","codex_error_info":"unauthorized"}}\n'`)

	p := NewWithBinary(stub)
	policy := &RetryPolicy{
		MaxAttempts:            3,
		BaseDelay:              1 * time.Millisecond,
		MaxDelay:               5 * time.Millisecond,
		JitterFraction:         0,
		RetryableSubcategories: map[string]bool{"QUOTA": true}, // AUTH not included
	}
	req := &provider.Request{
		Prompt:           "test",
		ProviderSpecific: map[string]string{"codex.output_last_message": filepath.Join(dir, "last.md")},
	}

	res, err := p.RunAgentWithRetry(context.Background(), req, policy)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.ErrorSubcategory != "AUTH" {
		t.Errorf("ErrorSubcategory = %q, want %q", res.ErrorSubcategory, "AUTH")
	}

	data, readErr := os.ReadFile(counterFile)
	if readErr != nil {
		t.Fatalf("read counter file: %v", readErr)
	}
	count := countNewlines(data)
	if count != 1 {
		t.Errorf("invocation count = %d, want 1 (no retry for AUTH)", count)
	}
}

// TestRunAgentWithRetry_ContextCancelledMidBackoff verifies that cancelling
// the context during the backoff sleep causes RunAgentWithRetry to return
// ctx.Err() rather than waiting for the full backoff to expire.
func TestRunAgentWithRetry_ContextCancelledMidBackoff(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()

	stub := makeShellStub(t, dir, "quota_slow.sh",
		`printf '{"id":"s1","msg":{"type":"error","message":"quota","codex_error_info":"usage_limit_exceeded"}}\n'`)

	p := NewWithBinary(stub)
	policy := &RetryPolicy{
		MaxAttempts:            5,
		BaseDelay:              2 * time.Second, // long backoff so cancel fires first
		MaxDelay:               10 * time.Second,
		JitterFraction:         0,
		RetryableSubcategories: map[string]bool{"QUOTA": true},
	}
	req := &provider.Request{
		Prompt:           "test",
		ProviderSpecific: map[string]string{"codex.output_last_message": filepath.Join(dir, "last.md")},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := p.RunAgentWithRetry(ctx, req, policy)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("expected non-nil error when context is cancelled mid-backoff")
	}
	// Must return well before the 2s backoff would have expired.
	if elapsed > 1*time.Second {
		t.Errorf("RunAgentWithRetry took %v; should have returned quickly on ctx cancellation", elapsed)
	}
}

// TestRunAgentWithRetry_NilPolicyUsesDefault verifies that passing nil for
// policy falls back to DefaultRetryPolicy without panicking.
func TestRunAgentWithRetry_NilPolicyUsesDefault(t *testing.T) {
	requireSh(t)
	dir := t.TempDir()
	stub := stubSuccess(t, dir)
	p := NewWithBinary(stub)

	req := &provider.Request{
		Prompt:           "test",
		ProviderSpecific: map[string]string{"codex.output_last_message": filepath.Join(dir, "last.md")},
	}

	res, err := p.RunAgentWithRetry(context.Background(), req, nil)
	if err != nil {
		t.Fatalf("unexpected error with nil policy: %v", err)
	}
	if res.Outcome != provider.OutcomeSuccess {
		t.Errorf("Outcome = %v, want OutcomeSuccess", res.Outcome)
	}
}
