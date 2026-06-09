package codex

import (
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

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
		{2, provider.OutcomeUnknown},
		{-1, provider.OutcomeUnknown},
		{255, provider.OutcomeUnknown},
	}
	for _, tc := range cases {
		got := interpretExitCode(tc.code)
		if got != tc.want {
			t.Errorf("interpretExitCode(%d) = %v, want %v", tc.code, got, tc.want)
		}
	}
}
