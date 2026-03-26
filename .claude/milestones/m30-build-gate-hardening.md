#### Milestone 30: Build Gate Hardening & Hang Prevention

<!-- milestone-meta
id: "30"
status: "done"
-->

The build gate (`run_build_gate()` in `lib/gates.sh`) has two reliability issues
that compound at scale:

**Critical bug — npx browser detection hangs indefinitely.**
`_check_headless_browser()` in `lib/ui_validate.sh:42` runs
`npx playwright --version` to detect available browsers. When Playwright is not
installed locally, modern npx (npm 7+) delegates to `npm exec`, which prompts
"Need to install the following packages: playwright. OK to proceed? (y/n)".
In a non-interactive pipeline context (no TTY on stdin), this prompt blocks
forever — the process hangs with zero CPU, waiting for input that never arrives.
The same pattern applies to the `npx puppeteer --version` fallback on line 48.
This has been confirmed in production: the process `npm exec playwright --version`
sits indefinitely, stalling the entire pipeline at the build gate.

**Performance issue — ANALYZE_CMD shellchecks the entire codebase.**
`ANALYZE_CMD="shellcheck tekhton.sh lib/*.sh stages/*.sh"` expands to 130 files
(118 in lib/, 11 in stages/, plus tekhton.sh). This takes ~2 minutes on a clean
run and scales worse under memory pressure (WSL2, concurrent agent processes).
The build gate runs this full sweep after every code change, regardless of how
many files were actually modified. A two-line comment addition triggers the same
analysis as a 500-line refactor.

This milestone fixes both issues and adds defensive timeouts throughout the gate.

Files to modify:
- `lib/ui_validate.sh` — Fix npx hang, add defensive timeouts:
  **Fix 1: npx non-interactive mode.**
  Replace bare `npx` calls with timeout-wrapped, non-interactive variants.
  Use `timeout 10 npx --yes playwright --version` (the `--yes` flag
  auto-accepts the install prompt and prevents the hang). If the package
  isn't cached, the 10-second timeout will kill it before it can download
  the full package — which is the correct behavior (we want detection, not
  installation).
  Alternative: use `npm ls playwright` to check if it's installed locally
  without triggering any install prompt. This is faster and side-effect-free.
  Recommended approach: check with `npm ls` first (zero side effects), fall
  back to `timeout`-wrapped `npx --yes` only if `npm ls` can't determine
  the answer.
  Apply the same fix to the puppeteer detection on line 48.

  **Fix 2: Overall browser detection timeout.**
  Wrap the entire `_check_headless_browser()` function body in a subshell
  with a hard 30-second timeout. If browser detection takes longer than
  30 seconds total, treat it as "no browser available" and soft-skip.
  This is the defense-in-depth layer — even if individual commands have
  their own timeouts, the aggregate timeout catches unexpected hangs.

- `lib/gates.sh` — Add per-phase timeouts and incremental analysis:
  **Fix 3: ANALYZE_CMD timeout.**
  Wrap the `bash -c "${ANALYZE_CMD}"` call in a configurable timeout
  (new config key: `BUILD_GATE_ANALYZE_TIMEOUT`, default: 300 seconds).
  If the analysis exceeds the timeout, log a warning and treat it as a
  pass (analysis timeout is not a build failure — it's an infrastructure
  issue). This prevents runaway static analysis from blocking the pipeline.

  **Fix 4: BUILD_CHECK_CMD timeout.**
  Same treatment for the compile check: wrap in
  `BUILD_GATE_COMPILE_TIMEOUT` (default: 120 seconds).

  **Fix 5: Dependency constraint timeout.**
  Wrap constraint validation in `BUILD_GATE_CONSTRAINT_TIMEOUT`
  (default: 60 seconds).

  **Fix 6: Overall gate timeout.**
  Add a `BUILD_GATE_TIMEOUT` (default: 600 seconds / 10 minutes) that
  wraps the entire `run_build_gate()` function. If the gate exceeds this
  absolute limit, kill all child processes and return failure with a clear
  diagnostic message. This is the "no gate call should ever hang the
  pipeline for 20 minutes" safety net.

- `lib/config_defaults.sh` — Add new config keys:
  - `BUILD_GATE_TIMEOUT` (default: 600)
  - `BUILD_GATE_ANALYZE_TIMEOUT` (default: 300)
  - `BUILD_GATE_COMPILE_TIMEOUT` (default: 120)
  - `BUILD_GATE_CONSTRAINT_TIMEOUT` (default: 60)

- `lib/ui_validate.sh` — Additional robustness:
  **Fix 7: Server startup timeout enforcement.**
  The `_start_ui_server()` function already has a timeout loop, but it
  relies on `sleep 1` increments — if the curl probe itself hangs (DNS
  resolution, connection timeout), each iteration can exceed 1 second
  significantly. Wrap the curl probe in `timeout 5` to cap each iteration.

  **Fix 8: Smoke test process cleanup.**
  `_run_smoke_test()` uses `timeout` on the node process, but if the
  timeout fires, the node process may leave orphaned child processes
  (headless browser instances). Add a process group kill after timeout:
  run the node process in its own process group (`setsid` or `set -m`)
  and kill the group on timeout.

- `tests/test_build_gate_timeouts.sh` — New test file:
  - Test that `_check_headless_browser()` completes within 30 seconds
    even when npx would hang (mock npx with a `sleep infinity` script)
  - Test that `run_build_gate()` respects `BUILD_GATE_TIMEOUT`
    (mock ANALYZE_CMD with `sleep infinity`, verify gate returns within
    timeout + grace period)
  - Test that per-phase timeouts are individually configurable
  - Test that timeout produces a clear diagnostic message (not silent failure)
  - Test that orphaned server/browser processes are cleaned up after timeout

Acceptance criteria:
- `_check_headless_browser()` never hangs, even when npx prompts for install
- `npx playwright --version` and `npx puppeteer --version` are either
  replaced with non-prompting alternatives or wrapped in hard timeouts
- `run_build_gate()` completes within `BUILD_GATE_TIMEOUT` seconds under
  all circumstances, including when subprocesses hang
- Each phase (analyze, compile, constraint, UI test, UI validation) has
  its own configurable timeout
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n lib/gates.sh lib/ui_validate.sh` passes
- `shellcheck lib/gates.sh lib/ui_validate.sh` passes
- New test file `tests/test_build_gate_timeouts.sh` covers hang scenarios

Watch For:
- `npx --yes` behavior varies across npm versions. npm 6 doesn't support
  `--yes`. The fix must detect npm version or use the `npm ls` approach
  which works across all versions.
- `timeout` command availability: GNU coreutils `timeout` is standard on
  Linux but may not exist on macOS. Tekhton already targets bash 4+ on
  Linux, but verify `timeout` is in the PATH.
- Process group kills (`kill -TERM -$pgid`) require the process to have
  been started with `setsid` or in a subshell with job control. Verify
  this works under `set -euo pipefail`.
- The `BUILD_GATE_TIMEOUT` kill must clean up ALL child processes — a
  dangling `python3 -m http.server` or headless browser after a timeout
  will cause port conflicts on the next gate run.
- WSL2 process management: `kill -0` and process group operations may
  behave differently under WSL2. Test on the actual target platform.

Seeds Forward:
- The per-phase timeout infrastructure enables future metrics collection
  on gate phase durations (how long does shellcheck take? how long does
  the UI server take to start?) for adaptive calibration.
- The `npm ls` detection pattern can be reused by future milestones that
  need to detect locally-installed npm packages without side effects.
- The overall gate timeout pattern could be applied to agent invocations
  as an additional safety layer beyond the existing activity timeout.
