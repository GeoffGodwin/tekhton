# JR Coder Summary — m33.1 Dashboard Emitters

## What Was Fixed

- `internal/dashboard/emit_timeline.go:106`: Removed spurious closing quote from the milestone verbosity filter substring. Changed `"type":"milestone_"` to `"type":"milestone_` so that real causal-log events like `{"type":"milestone_start",...}` are no longer silently dropped in normal verbosity mode. This restores milestone start/completion events in the Watchtower timeline.

## Files Modified

- `internal/dashboard/emit_timeline.go`
