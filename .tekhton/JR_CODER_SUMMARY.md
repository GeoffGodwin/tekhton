# JR Coder Summary — m45

## What Was Fixed

- `cmd/tekhton/gate.go::completionGateFromEnv` — `COMPLETION_GATE_GRACE_SECS=0` and
  `COMPLETION_GATE_RETRY_DELAY_SECS=0` previously fell back to their 3s/5s defaults
  because `envSeconds` rejects 0 via `n <= 0`. Added `envSecondsNonNeg` helper that
  uses `n < 0` as the invalidity guard (allowing 0), and switched the two grace/retry-
  delay call sites in `completionGateFromEnv` to use it. Setting either key to 0 now
  correctly disables the corresponding window, matching the CLAUDE.md docs and
  `pipeline.conf.example` promises.

## Files Modified

- `cmd/tekhton/gate.go`
