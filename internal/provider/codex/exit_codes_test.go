package codex

import (
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// TestInterpretExitCode_Table exercises every explicit mapping in interpretExitCode
// and the catch-all path. The spec (m07 exit_codes.go) maps:
//
//	0   → OutcomeSuccess
//	1   → OutcomeUpstreamError (catch-all failure)
//	124 → OutcomeTimeout       (GNU timeout signal)
//	137 → OutcomeAborted       (SIGKILL)
//	143 → OutcomeAborted       (SIGTERM / context cancel)
//	*   → OutcomeUnknown
func TestInterpretExitCode_Table(t *testing.T) {
	cases := []struct {
		code int
		want provider.Outcome
	}{
		{0, provider.OutcomeSuccess},
		{1, provider.OutcomeUpstreamError},
		{124, provider.OutcomeTimeout},
		{137, provider.OutcomeAborted},
		{143, provider.OutcomeAborted},
		// Unrecognised non-zero codes fall through to OutcomeUnknown.
		{2, provider.OutcomeUnknown},
		{126, provider.OutcomeUnknown},
		{255, provider.OutcomeUnknown},
		{-1, provider.OutcomeUnknown},
	}

	for _, tc := range cases {
		got := interpretExitCode(tc.code)
		if got != tc.want {
			t.Errorf("interpretExitCode(%d) = %v, want %v", tc.code, got, tc.want)
		}
	}
}

// TestInterpretExitCode_ZeroIsSuccess pins the primary happy path: a clean
// Codex run returns exit code 0 and must map to OutcomeSuccess, not any
// error outcome.
func TestInterpretExitCode_ZeroIsSuccess(t *testing.T) {
	got := interpretExitCode(0)
	if got != provider.OutcomeSuccess {
		t.Errorf("exit 0 must be OutcomeSuccess, got %v", got)
	}
	if got == provider.OutcomeUpstreamError || got == provider.OutcomeUnknown {
		t.Error("exit 0 must not map to an error outcome")
	}
}

// TestInterpretExitCode_NonZeroNotSuccess asserts that no non-zero exit code
// maps to OutcomeSuccess.
func TestInterpretExitCode_NonZeroNotSuccess(t *testing.T) {
	nonZero := []int{1, 2, 124, 137, 143, 255}
	for _, code := range nonZero {
		if got := interpretExitCode(code); got == provider.OutcomeSuccess {
			t.Errorf("interpretExitCode(%d) = OutcomeSuccess; only exit 0 should succeed", code)
		}
	}
}
