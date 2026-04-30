## Planned Tests
- [x] `tests/test_tui_liveness_probe.sh` — Verify liveness probe detection and state management
- [x] `tests/test_tui_liveness_sampling.sh` — Verify probe only fires every N writes (sampling optimization)
- [x] `tests/test_human_complete_loop_resets.sh` — Verify per-iteration resets prevent watchdog firing

## Test Run Results
Passed: 24  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_tui_liveness_probe.sh`
- [x] `tests/test_tui_liveness_sampling.sh`
- [x] `tests/test_human_complete_loop_resets.sh`

## Test Summary

### test_tui_liveness_probe.sh (9 tests)
Comprehensive verification of the `_tui_check_sidecar_liveness` probe implementation:
1. Probe returns 0 when _TUI_ACTIVE=false (no-op path)
2. Probe returns 0 when _TUI_PID is empty (no-op path)
3. Probe always returns 0 (safe for hot paths)
4. Probe detects dead sidecar and flips _TUI_ACTIVE=false
5. Probe clears _TUI_PID on detection
6. Probe removes pidfile on detection
7. Probe respects sampling interval (no check before INTERVAL)
8. Probe resets counter to 0 after check
9. Probe correctly identifies live process (kill -0 succeeds)

### test_tui_liveness_sampling.sh (7 tests)
Sampling optimization verification ensuring the probe only fires every N writes:
1. Counter increments on each probe call (when active with PID)
2. Probe doesn't fire before reaching interval (9 calls, interval=10)
3. Probe fires exactly at interval boundary (5 calls, interval=5)
4. Counter resets to 0 after probe fires
5. Second sampling cycle initializes correctly after reset
6. Probe respects runtime interval configuration (interval=7)
7. Default _TUI_LIVENESS_INTERVAL is 20

### test_human_complete_loop_resets.sh (8 tests)
Verification of per-iteration resets in the human-complete loop:
1. Reset functions exist and are callable
2. tui_reset_for_next_milestone zeros _TUI_AGENT_TURNS_USED
3. tui_reset_for_next_milestone refreshes status-file mtime
4. tui_reset_for_next_milestone clears lifecycle tracking
5. tui_reset_for_next_milestone clears recent events
6. out_reset_pass is callable and tracked
7. Sequential reset pattern works (out_reset_pass → tui_reset_for_next_milestone)
8. Resets prevent watchdog accumulation (turns → 0)

## Coverage Analysis

The tests provide comprehensive coverage of all task requirements:

### Liveness Probe Implementation (lib/tui_liveness.sh)
- **Detection mechanism**: `kill -0 "$_TUI_PID"` syscall (atomic, zero-overhead on live process)
- **State management**: Flips `_TUI_ACTIVE=false`, clears `_TUI_PID`, removes pidfile
- **Observability**: Single `warn` line emitted: "TUI sidecar exited (pid X; likely watchdog timeout); continuing in CLI mode"
- **Sampling optimization**: Counter-based sampling (every 20 writes) avoids syscall overhead
- **Integration point**: Called from `_tui_write_status` (hot path), safe no-op when inactive/no-PID

### Per-Iteration Resets (tekhton.sh:2630-2644)
- **out_reset_pass()**: Resets display state between note iterations
- **tui_reset_for_next_milestone()**: Zeros `_TUI_AGENT_TURNS_USED` and refreshes status-file mtime
- **Watchdog prevention**: Removes idle+stale+turns preconditions that accumulate in quiet windows (inbox drain, triage, quota-probe sleeps)
- **Safety guards**: Both calls wrapped in `declare -f ... &>/dev/null` checks for robustness

### Test Coverage Matrix
| Requirement | test_tui_liveness_probe | test_tui_liveness_sampling | test_human_complete_loop_resets | Status |
|---|---|---|---|---|
| Dead sidecar detection (kill -0) | ✓ test_probe_detects_dead_sidecar | — | — | ✓ |
| _TUI_ACTIVE flip | ✓ test_probe_detects_dead_sidecar | — | — | ✓ |
| _TUI_PID cleared | ✓ test_probe_clears_pid | — | — | ✓ |
| pidfile removed | ✓ test_probe_removes_pidfile | — | — | ✓ |
| Warning emitted | ✓ test_probe_* (observed in output) | — | — | ✓ |
| Sampling every N writes | — | ✓ test_counter_* & test_probe_fires_at_interval | — | ✓ |
| Configurable interval | — | ✓ test_interval_configuration | — | ✓ |
| Default interval=20 | — | ✓ test_default_interval | — | ✓ |
| out_reset_pass callable | — | — | ✓ test_out_reset_pass_callable | ✓ |
| tui_reset_for_next_milestone callable | — | — | ✓ test_reset_functions_exist | ✓ |
| Zeros _TUI_AGENT_TURNS_USED | — | — | ✓ test_tui_reset_zeros_turns | ✓ |
| Refreshes status-file mtime | — | — | ✓ test_tui_reset_refreshes_mtime | ✓ |
| Sequential reset pattern | — | — | ✓ test_sequential_resets | ✓ |

All 24 tests pass. Full test suite shows: **Shell 479 passed, 0 failed | Python 250 passed, 14 skipped**
