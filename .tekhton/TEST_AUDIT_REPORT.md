## Test Audit Report

### Audit Summary
Tests audited: 4 files, 23 test functions/assertions
(14 Go functions in internal/runner/env_test.go, 6 Go functions in internal/proto/stage_env_test.go,
3 bash assertions in tests/test_v4_env_contract.sh, tests/run_tests.sh is a runner — no test functions)
Verdict: PASS

### Findings

#### EXERCISE: test_v4_env_contract.sh Test 1 comment overstates its coverage
- File: tests/test_v4_env_contract.sh:52-101
- Issue: The comment at lines 55-57 claims "We exercise `tekhton config defaults --emit shell` to capture the config-key half of the contract" and the file header (line 8) says "verified through the actual binary's emit path." Neither is true. The TEKHTON binary is built at lines 42-44 and `$TEKHTON_BIN` is assigned at line 45, but the variable is never invoked during Test 1's assertion block. The runtime-flag probe uses a hand-coded heredoc (`TEST_ENV`). The test is checking "can bash read these statically-defined env vars under set -u" — trivially true regardless of what `EnvBuilder.AsKV` actually emits. A regression that renamed `MILESTONE_MODE` to `MS_MODE` in internal/runner/env.go:163 would not be caught here; the real producer-side guard is `TestAsKV_RuntimeFlagsAlwaysExported` in internal/runner/env_test.go:128. The bash test provides only consumer-side smoke coverage (bash tolerates the vars) but its comments imply binary-parity.
- Severity: MEDIUM
- Action: Either (a) replace the `TEST_ENV` heredoc with output from `$TEKHTON_BIN run --env-emit` or a dedicated subcommand, making this a true end-to-end parity test, or (b) rewrite the comment to accurately describe the test as a static bash consumer-side smoke check; remove the mention of `tekhton config defaults --emit shell` since that command is never called in Test 1.

#### COVERAGE: test_v4_env_contract.sh Test 3 has an unconditional pass branch
- File: tests/test_v4_env_contract.sh:152-183
- Issue: The `|| true` on line 172 (`bash "${TEKHTON_HOME}/lib/finalize_shim.sh" _hook_does_not_exist 2>&1 || true`) absorbs all non-zero exits, making `probe_rc` always 0. Pass/fail is delegated entirely to string-grep branches. The else branch (lines 181-183) passes unconditionally when neither "unbound variable" nor "unknown hook" appears in the output. An empty output, a silent crash, or a refactored diagnostic message all produce a pass. If the shim is updated to emit a different message for unknown hooks, the test silently degrades to the always-pass else branch.
- Severity: LOW
- Action: Add a non-empty output guard before the else-pass: `[[ -z "$probe_out" ]] && fail "finalize_shim.sh produced no output"`. Alternatively, assert that `finalize_shim.sh` exits with a specific non-zero code for an unknown hook rather than relying solely on grep.

#### ISOLATION: test_v4_env_contract.sh Test 2 reads the real milestone directory
- File: tests/test_v4_env_contract.sh:121-122
- Issue: `MILESTONE_DIR` is set to `"${TEKHTON_HOME}/.claude/milestones"` — the live checked-in directory, not a temp fixture. `_intake_get_milestone_content` (called at line 130) reads files from that path. The test only asserts on exit code (rc=0), not on content, which limits blast radius. However, if the milestone directory is absent (bare checkout) or enters a transitional state (milestone file deleted by finalize after completion), `_intake_get_milestone_content` may exit non-zero for a reason unrelated to the env contract being tested, producing a false failure that is hard to diagnose.
- Severity: LOW
- Action: Create a minimal temp fixture directory with a stub milestone file via `$(mktemp -d)`, point `MILESTONE_DIR` at it, and clean up in an `EXIT` trap. This makes the test hermetic and independent of the pipeline's own milestone lifecycle.
