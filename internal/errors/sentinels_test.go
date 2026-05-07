package errors_test

import (
	stderrs "errors"
	"fmt"
	"testing"

	terr "github.com/geoffgodwin/tekhton/internal/errors"
)

func TestSentinelsAreDistinct(t *testing.T) {
	t.Parallel()
	all := []error{
		terr.ErrTransient,
		terr.ErrFatal,
		terr.ErrUserActionRequired,
		terr.ErrConfigInvalid,
		terr.ErrUpstreamLimit,
	}
	for i, a := range all {
		for j, b := range all {
			if i == j {
				continue
			}
			if stderrs.Is(a, b) {
				t.Errorf("sentinels at %d and %d collide: %v == %v", i, j, a, b)
			}
		}
	}
}

func TestWrappedSentinelMatches(t *testing.T) {
	t.Parallel()
	cases := []struct {
		base error
	}{
		{terr.ErrTransient},
		{terr.ErrFatal},
		{terr.ErrUserActionRequired},
		{terr.ErrConfigInvalid},
		{terr.ErrUpstreamLimit},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.base.Error(), func(t *testing.T) {
			t.Parallel()
			wrapped := fmt.Errorf("wrapped: %w", tc.base)
			if !stderrs.Is(wrapped, tc.base) {
				t.Fatalf("errors.Is failed for wrapped sentinel %v", tc.base)
			}
		})
	}
}
