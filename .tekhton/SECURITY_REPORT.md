## Summary
This change adds milestone ID carry-over logic to the bash state writer (`lib/state_helpers.sh`) and two fixture-driven Go round-trip tests (`internal/runner/resume_test.go`). The surface is entirely internal: no user input, no network communication, no authentication changes, and no cryptographic operations. The bash changes touch variable expansion and JSON serialization in the existing bash-fallback writer; the Go changes add read-only test fixtures in temp directories. No new security-relevant attack surface is introduced.

## Findings

None

## Verdict
CLEAN
