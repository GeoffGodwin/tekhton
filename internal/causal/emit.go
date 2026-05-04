// Package causal owns the writer side of the causal event log.
//
// The log file format is documented in internal/proto.CausalEventV1; this
// package provides the in-process API (Log type) and the small helpers that
// format event IDs and timestamps. Readers (bash query layer today, future
// Go consumers) do not import this package — they read the JSONL contract.
package causal

import (
	"fmt"
	"time"
)

// FormatEventID produces "<stage>.NNN" with three-digit zero padding to match
// the bash writer's output for the first 999 events per stage. After 999 the
// sequence simply widens (e.g. "coder.1000"); printf "%03d" in bash behaves
// the same way, so parity is preserved.
func FormatEventID(stage string, seq int64) string {
	return fmt.Sprintf("%s.%03d", stage, seq)
}

// nowRFC3339 returns the current UTC time in the same format the bash writer
// used: `2006-01-02T15:04:05Z`. We deliberately avoid RFC3339Nano because
// bash's `date -u +"%Y-%m-%dT%H:%M:%SZ"` is second-precision; matching that
// keeps the parity diff narrow (only timestamp values differ, not formats).
func nowRFC3339() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}
