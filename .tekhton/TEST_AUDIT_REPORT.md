## Test Audit Report

### Audit Summary
Tests audited: 3 files, 24 test functions
Verdict: PASS

### Findings

#### EXERCISE: test_human_complete_loop_resets.sh does not call _run_human_complete_loop
- File: tests/test_human_complete_loop_resets.sh:1-276
- Issue: The test suite's stated goal is to "Verify per-iteration resets in
  `_run_human_complete_loop`," but `_run_human_complete_loop` (tekhton.sh:2606)
  is never sourced or called. What the tests actually verify is that the
  component functions (`tui_reset_for_next_milestone`, `out_reset_pass`) behave
  correctly in isolation. The integration point — the declaration-guarded calls
  at tekhton.sh:2634-2644 that constitute the actual bug fix — goes untested.
  If those lines were deleted, every test in this file would still pass.
  `test_sequential_resets` (lines 196-229) simulates the call pattern with a
  hand-rolled `declare -f ... && call` block rather than exercising the real
  loop, which means the guard condition itself is untested.
  Note: the original task description acknowledged this limitation ("No new tests
  required beyond the manual repro — the failure mode is timing-dependent and not
  amenable to a deterministic unit test in the current TUI harness"), so the
  tester made a justified design choice. The gap is real but accepted.
- Severity: MEDIUM
- Action: Add a smoke test that sources tekhton.sh in stub mode (with mocked
  `pick_next_note` and `process_watchtower_inbox`) and confirms that after one
  iteration of `_run_human_complete_loop`, `_TUI_AGENT_TURNS_USED` is 0 and the
  status-file mtime was refreshed. Alternatively, document the accepted coverage
  gap in the test file header so future auditors understand the constraint.

#### SCOPE: test_reset_functions_exist validates the mock, not the real out_reset_pass
- File: tests/test_human_complete_loop_resets.sh:39-51
- Issue: `lib/common.sh` sources `lib/output.sh` which defines the real
  `out_reset_pass`. The test file then overrides it with a tracking mock at
  line 35. `test_reset_functions_exist` (line 40) calls `declare -f out_reset_pass`
  and passes — but it is finding the mock, not verifying the real function exists
  at its expected location in `lib/output.sh`. If the real `out_reset_pass` were
  deleted from `lib/output.sh`, this test would still pass (the mock would still
  be defined). The test therefore does not guard against the real function being
  removed.
- Severity: MEDIUM
- Action: Split the existence check from the mock declaration: capture
  `declare -f out_reset_pass` before defining the mock (to verify the real
  function was loaded from output.sh), then define the mock. Or rename the test
  to `test_mock_reset_functions_callable` to accurately reflect what it asserts.

#### ISOLATION: Dead-PID assumption relies on default kernel.pid_max
- File: tests/test_tui_liveness_probe.sh:54, 73, 88, 109; tests/test_tui_liveness_sampling.sh:52, 84, 118, 141
- Issue: Multiple tests use PID `99999` (and `88888`) as a "definitely dead"
  process. This holds reliably on Linux systems where `kernel.pid_max = 32768`
  (the default) since 99999 exceeds the maximum allocatable PID. On systems with
  a raised `pid_max` (Linux supports up to 4,194,304; some container environments
  set higher values), PID 99999 could be a live process, flipping the detection
  logic and causing `test_probe_detects_dead_sidecar`, `test_probe_clears_pid`,
  `test_probe_removes_pidfile`, and the sampling boundary tests to produce false
  failures or false passes depending on the process state at test time.
- Severity: LOW
- Action: Replace the hardcoded PID with a reliably-dead PID obtained by spawning
  and reaping a subprocess:
  ```bash
  ( exit 0 ) & dead_pid=$! ; wait "$dead_pid"
  # dead_pid is now guaranteed not to exist
  ```
  This is portable, cheap, and eliminates the assumption about pid_max.

#### NAMING: Misleading inline comment in test_probe_sampling_interval
- File: tests/test_tui_liveness_probe.sh:131
- Issue: The comment reads "First call should NOT trigger check (counter still 0
  after increment)" but after `_tui_check_sidecar_liveness` increments the
  counter the value is 1, not 0. The assertion (`_TUI_ACTIVE == "true"`) is
  correct — the probe does not fire on the first call — but the comment describes
  the wrong counter value and could mislead a maintainer.
- Severity: LOW
- Action: Change the comment to "counter is 1 after first call (1 < 20), probe
  does not fire" to accurately reflect the post-call counter state.

### Clean Findings (no issues)

**Assertion honesty — PASS.** No hard-coded expected values that don't derive
from implementation logic:
- Sampling boundary assertions (fire at N, not-fire at N-1) match the
  `_TUI_WRITE_COUNT_SINCE_LIVENESS < _TUI_LIVENESS_INTERVAL` branch in
  `tui_liveness.sh:59`.
- `_TUI_ACTIVE=false` / `_TUI_PID=""` / pidfile-removed assertions match the
  exact state mutations in `tui_liveness.sh:66-70`.
- `_TUI_AGENT_TURNS_USED=0` assertion in `test_tui_reset_zeros_turns` mirrors
  `tui_ops.sh:186`.
- `test_default_interval` asserts `_TUI_LIVENESS_INTERVAL == 20` which is the
  literal declaration at `tui_liveness.sh:24` — a contract test, not a magic
  number.

**Implementation exercise — PASS.** `_tui_check_sidecar_liveness` and
`tui_reset_for_next_milestone` are called directly against their real
implementations sourced from `lib/tui_liveness.sh` and `lib/tui_ops.sh`. No test
replaces these functions with stubs. `_tui_write_status` is exercised indirectly
through `tui_reset_for_next_milestone`, confirming the mtime-refresh behavior
through the real atomic-write path in `tui_liveness.sh:47-48`.

**Test weakening — PASS / none detected.** No existing tests were modified.
All three files are new additions.

**Test naming — PASS.** Function names are descriptive:
`test_probe_noop_when_inactive`, `test_probe_detects_dead_sidecar`,
`test_no_check_before_interval`, `test_probe_fires_at_interval`,
`test_tui_reset_zeros_turns`, `test_tui_reset_refreshes_mtime`, etc. All names
encode the scenario and the expected outcome.

**Test isolation — PASS.** All three test files create a `mktemp -d` temp
directory bound to `PROJECT_DIR` with a `trap '...' EXIT` cleanup guard. Pidfiles
and status-file fixtures are written inside this temp directory. No test reads
live `.tekhton/` artifacts, pipeline state, or run logs.
