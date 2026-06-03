package cleanup

import (
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/notes"
)

// docWithPending returns a parsed Document containing n Pending notes.
// Lives in trigger_test.go so the trigger gates can be exercised without
// touching the broader stage/results test fixtures.
func docWithPending(t *testing.T, n int) *notes.Document {
	t.Helper()
	lines := []string{"## Open"}
	for i := 0; i < n; i++ {
		lines = append(lines, "- [ ] [BUG] item "+itoa(i+1))
	}
	d, err := notes.Parse(strings.NewReader(strings.Join(lines, "\n") + "\n"))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	return d
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

func TestShouldRun_Disabled(t *testing.T) {
	t.Setenv("CLEANUP_ENABLED", "false")
	d := docWithPending(t, 10)
	if shouldRun(d) {
		t.Error("shouldRun(disabled) = true, want false")
	}
}

func TestShouldRun_Unset(t *testing.T) {
	// Unset CLEANUP_ENABLED should default to false (the bash default).
	t.Setenv("CLEANUP_ENABLED", "")
	d := docWithPending(t, 10)
	if shouldRun(d) {
		t.Error("shouldRun(unset) = true, want false")
	}
}

func TestShouldRun_BelowThreshold(t *testing.T) {
	t.Setenv("CLEANUP_ENABLED", "true")
	t.Setenv("CLEANUP_TRIGGER_THRESHOLD", "5")
	// 4 unresolved is strictly below 5; should NOT trigger. Bash
	// predicate at stages/cleanup.sh: `[ "$unresolved" -lt "$threshold" ]
	// && skip` — count of exactly threshold runs (see TestShouldRun_AtThreshold).
	d := docWithPending(t, 4)
	if shouldRun(d) {
		t.Error("shouldRun(4 unresolved, threshold 5) = true, want false")
	}
}

func TestShouldRun_AtThreshold(t *testing.T) {
	t.Setenv("CLEANUP_ENABLED", "true")
	t.Setenv("CLEANUP_TRIGGER_THRESHOLD", "5")
	// 5 unresolved is exactly at the threshold; should trigger. Matches the
	// bash predicate `[ unresolved -lt threshold ] && skip` — equal does NOT
	// skip.
	d := docWithPending(t, 5)
	if !shouldRun(d) {
		t.Error("shouldRun(5 unresolved, threshold 5) = false, want true (equal ≥ threshold)")
	}
}

func TestShouldRun_Triggers(t *testing.T) {
	t.Setenv("CLEANUP_ENABLED", "true")
	t.Setenv("CLEANUP_TRIGGER_THRESHOLD", "5")
	// 7 unresolved > 5; should trigger.
	d := docWithPending(t, 7)
	if !shouldRun(d) {
		t.Error("shouldRun(7 unresolved, threshold 5) = false, want true")
	}
}

func TestShouldRun_DefaultThreshold(t *testing.T) {
	t.Setenv("CLEANUP_ENABLED", "true")
	// Threshold unset → default 5; 6 unresolved triggers.
	d := docWithPending(t, 6)
	if !shouldRun(d) {
		t.Error("shouldRun(6 unresolved, default threshold) = false, want true")
	}
}
