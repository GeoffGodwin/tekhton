package codex

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestRateLimitWindow_Remaining verifies that Remaining returns limit-used for
// a healthy window.
func TestRateLimitWindow_Remaining(t *testing.T) {
	w := RateLimitWindow{Name: "primary", Used: 300, Limit: 1000}
	if got := w.Remaining(); got != 700 {
		t.Errorf("Remaining() = %d, want 700", got)
	}
}

// TestRateLimitWindow_Remaining_ExhaustedClampsToZero verifies that Remaining
// never returns a negative value even when used > limit (e.g., after a burst).
func TestRateLimitWindow_Remaining_ExhaustedClampsToZero(t *testing.T) {
	w := RateLimitWindow{Name: "primary", Used: 1050, Limit: 1000}
	if got := w.Remaining(); got != 0 {
		t.Errorf("Remaining() = %d, want 0 for over-limit window", got)
	}
}

// TestRateLimitWindow_Remaining_ZeroLimit returns 0 when Limit is not set.
func TestRateLimitWindow_Remaining_ZeroLimit(t *testing.T) {
	w := RateLimitWindow{Name: "primary", Used: 0, Limit: 0}
	if got := w.Remaining(); got != 0 {
		t.Errorf("Remaining() = %d, want 0 for zero-limit window", got)
	}
}

// TestShouldRetryAfter_ExhaustedWithFutureReset verifies that ShouldRetryAfter
// returns (d>0, true) when a window is fully exhausted and ResetAt is in the
// future.
func TestShouldRetryAfter_ExhaustedWithFutureReset(t *testing.T) {
	future := time.Now().Add(5 * time.Minute)
	snap := &RateLimitSnapshot{
		Windows: []RateLimitWindow{
			{Name: "primary", Used: 1000, Limit: 1000, ResetAt: &future},
		},
	}
	d, ok := snap.ShouldRetryAfter()
	if !ok {
		t.Fatal("ShouldRetryAfter() returned false; expected true for exhausted window with future ResetAt")
	}
	if d <= 0 {
		t.Errorf("ShouldRetryAfter() duration = %v, want > 0", d)
	}
}

// TestShouldRetryAfter_NonExhaustedWindows verifies that ShouldRetryAfter
// returns (0, false) when all windows still have remaining capacity.
func TestShouldRetryAfter_NonExhaustedWindows(t *testing.T) {
	snap := &RateLimitSnapshot{
		Windows: []RateLimitWindow{
			{Name: "primary", Used: 50, Limit: 1000},
			{Name: "secondary", Used: 200, Limit: 5000},
		},
	}
	d, ok := snap.ShouldRetryAfter()
	if ok {
		t.Errorf("ShouldRetryAfter() = (%v, true), want (0, false) for windows with remaining capacity", d)
	}
}

// TestShouldRetryAfter_NilSnapshot verifies that calling ShouldRetryAfter on a
// nil snapshot does not panic and returns (0, false).
func TestShouldRetryAfter_NilSnapshot(t *testing.T) {
	var snap *RateLimitSnapshot
	d, ok := snap.ShouldRetryAfter()
	if ok || d != 0 {
		t.Errorf("nil ShouldRetryAfter() = (%v, %v), want (0, false)", d, ok)
	}
}

// TestShouldRetryAfter_EmptyWindows verifies that a snapshot with no windows
// returns (0, false).
func TestShouldRetryAfter_EmptyWindows(t *testing.T) {
	snap := &RateLimitSnapshot{Windows: nil}
	d, ok := snap.ShouldRetryAfter()
	if ok || d != 0 {
		t.Errorf("empty-windows ShouldRetryAfter() = (%v, %v), want (0, false)", d, ok)
	}
}

// TestUnmarshalRateLimits_LowRemainingFixture verifies that UnmarshalRateLimits
// correctly decodes the low_remaining.json fixture and produces a snapshot with
// the expected window data.
func TestUnmarshalRateLimits_LowRemainingFixture(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "ratelimit_snapshots", "low_remaining.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	snap, err := UnmarshalRateLimits(json.RawMessage(raw))
	if err != nil {
		t.Fatalf("UnmarshalRateLimits: %v", err)
	}
	if snap == nil {
		t.Fatal("UnmarshalRateLimits returned nil snap for valid JSON")
	}
	if len(snap.Windows) != 2 {
		t.Fatalf("len(snap.Windows) = %d, want 2", len(snap.Windows))
	}
	primary := snap.Windows[0]
	if primary.Name != "primary" {
		t.Errorf("Windows[0].Name = %q, want %q", primary.Name, "primary")
	}
	if primary.Remaining() != 50 {
		t.Errorf("Windows[0].Remaining() = %d, want 50", primary.Remaining())
	}
	// Snapshot should preserve Raw bytes.
	if len(snap.Raw) == 0 {
		t.Error("snap.Raw is empty; UnmarshalRateLimits must preserve the raw payload")
	}
}

// TestUnmarshalRateLimits_EmptyRaw verifies that passing an empty RawMessage
// returns (nil, nil) — no error, no snapshot.
func TestUnmarshalRateLimits_EmptyRaw(t *testing.T) {
	snap, err := UnmarshalRateLimits(json.RawMessage{})
	if err != nil {
		t.Errorf("UnmarshalRateLimits(empty): unexpected error: %v", err)
	}
	if snap != nil {
		t.Errorf("UnmarshalRateLimits(empty): snap = %v, want nil", snap)
	}
}

// TestUnmarshalRateLimits_InvalidJSON verifies that malformed JSON returns
// a non-nil error and a nil snapshot.
func TestUnmarshalRateLimits_InvalidJSON(t *testing.T) {
	snap, err := UnmarshalRateLimits(json.RawMessage(`{invalid`))
	if err == nil {
		t.Error("UnmarshalRateLimits(invalid JSON): expected error, got nil")
	}
	if snap != nil {
		t.Errorf("UnmarshalRateLimits(invalid JSON): snap = %v, want nil", snap)
	}
}
