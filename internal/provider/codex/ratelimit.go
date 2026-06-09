// Package codex — Rate-limit snapshot decoder and retry-timing advisor.
// V5 m11 — typed RateLimitSnapshot with ShouldRetryAfter + UnmarshalRateLimits.
package codex

import (
	"encoding/json"
	"fmt"
	"time"
)

// RateLimitWindow holds per-window rate-limit data from Codex token_count events.
type RateLimitWindow struct {
	Name       string     `json:"name"`
	Used       int64      `json:"used"`
	Limit      int64      `json:"limit"`
	ResetAt    *time.Time `json:"reset_at,omitempty"`
	WindowSecs int64      `json:"window_secs,omitempty"`
}

// Remaining returns the tokens remaining in this window. Returns 0 when the
// window is exhausted or when Limit is not positive.
func (w *RateLimitWindow) Remaining() int64 {
	if w.Limit <= 0 {
		return 0
	}
	rem := w.Limit - w.Used
	if rem < 0 {
		return 0
	}
	return rem
}

// ShouldRetryAfter examines the snapshot's windows and returns the suggested
// wait duration when a retry is likely productive. It selects the window with
// the smallest remaining capacity; if that window is fully exhausted and
// provides a ResetAt hint, it returns the time until reset. Returns (0, false)
// when no useful guidance can be derived (no windows, all have remaining, no
// ResetAt).
func (s *RateLimitSnapshot) ShouldRetryAfter() (time.Duration, bool) {
	if s == nil || len(s.Windows) == 0 {
		return 0, false
	}

	var (
		worst          *RateLimitWindow
		worstRemaining int64 = -1
	)
	for i := range s.Windows {
		w := &s.Windows[i]
		rem := w.Remaining()
		if worstRemaining < 0 || rem < worstRemaining {
			worst = w
			worstRemaining = rem
		}
	}
	if worst == nil {
		return 0, false
	}

	if worstRemaining == 0 && worst.ResetAt != nil {
		wait := time.Until(*worst.ResetAt)
		if wait < 0 {
			wait = 0
		}
		return wait, true
	}
	return 0, false
}

// UnmarshalRateLimits decodes the raw rate-limits payload from a
// TokenCountEvent. Returns nil when raw is empty (token_count events without a
// rate_limits field).
func UnmarshalRateLimits(raw json.RawMessage) (*RateLimitSnapshot, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	var snap RateLimitSnapshot
	if err := json.Unmarshal(raw, &snap); err != nil {
		return nil, fmt.Errorf("ratelimit: decode: %w", err)
	}
	snap.Raw = raw
	return &snap, nil
}
