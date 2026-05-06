# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-05-05 | "Implement Milestone 8: Quota Pause/Resume + Retry-After Parsing"] `retry.go:195` — `return lastResult, nil` at the bottom of `retryLoop` is dead for any positive `MaxAttempts` (every loop iteration returns). The only reachable path is `MaxAttempts <= 0`, where the loop body never executes and the function returns `(nil, nil)`. A caller receiving `(nil, nil)` has no clean way to distinguish "succeeded with nil result" from "policy was degenerate". Consider an early guard: `if p.MaxAttempts <= 0 { return nil, fmt.Errorf("supervisor: MaxAttempts must be > 0") }`.
- [ ] [2026-05-05 | "Implement Milestone 8: Quota Pause/Resume + Retry-After Parsing"] `retry.go:57-58` — `if p.BaseDelay <= 0 { return 0 }` silently converts a degenerate policy into a zero-delay retry loop. This is undocumented; a comment or the same guard pattern as MaxAttempts would make intent explicit to future readers.
- [ ] [2026-05-05 | "M07"] `retry.go:195` — `return lastResult, nil` at the bottom of `retryLoop` is dead for any positive `MaxAttempts` (every loop iteration returns). The only reachable path is `MaxAttempts <= 0`, where the loop body never executes and the function returns `(nil, nil)`. A caller receiving `(nil, nil)` has no clean way to distinguish "succeeded with nil result" from "policy was degenerate". Consider an early guard: `if p.MaxAttempts <= 0 { return nil, fmt.Errorf("supervisor: MaxAttempts must be > 0") }`.
- [ ] [2026-05-05 | "M07"] `retry.go:57-58` — `if p.BaseDelay <= 0 { return 0 }` silently converts a degenerate policy into a zero-delay retry loop. This is undocumented; a comment or the same guard pattern as MaxAttempts would make intent explicit to future readers.

## Resolved
