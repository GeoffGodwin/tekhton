## Test Audit Report

### Audit Summary
Tests audited: 1 file (tests/test_m127_buildfix_routing.sh), 7 assertions across 4 test sections
Verdict: PASS

### Findings

#### ISOLATION: _safe_read_file sourced optionally but called unconditionally
- File: tests/test_m127_buildfix_routing.sh:24
- Issue: `lib/prompts.sh` is sourced with `2>/dev/null || true` (graceful / optional),
  but `_bf_read_raw_errors()` — called directly in test sections 1 and 2 — delegates
  to `_safe_read_file`, which is defined in `lib/prompts.sh`. If prompts.sh fails to
  load for any reason (e.g., new unmet dependency, CI environment difference), the
  two `_bf_read_raw_errors` test sections crash with "command not found" under
  `set -euo pipefail` rather than reporting a clean test failure. Every other test
  file in this repo that sources a stage using `_safe_read_file` defines an explicit
  stub (e.g., test_docs_agent_stage_smoke.sh:48, test_audit_tests.sh:33,
  test_clarify_handle.sh:28). This file does not.
- Severity: MEDIUM
- Action: Add an explicit stub immediately after the prompts.sh source line:
  `_safe_read_file() { cat "$1" 2>/dev/null || true; }`
  This makes tests 1 and 2 environment-independent without changing their behavior
  when prompts.sh is available.

#### COVERAGE: mixed_uncertain and unknown_only routing arms lack terminal behavior assertions
- File: tests/test_m127_buildfix_routing.sh (file-level)
- Issue: The file covers the noncode_dominant arm (exit 1 + write_pipeline_state env_failure)
  and the _bf_read_raw_errors primary/fallback paths. The mixed_uncertain arm
  (_bf_emit_routing_diagnosis + _bf_invoke_build_fix with extra context) and the
  unknown_only arm (_bf_invoke_build_fix with low-confidence guidance) have no
  orchestrator-level terminal behavior test in either test_m127_buildfix_routing.sh
  or test_m127_routing.sh. Token routing for those arms is verified in
  test_m127_routing.sh, but what happens after the token is dispatched (diagnosis
  file written, build-fix invoked) is untested at the _run_buildfix_routing level.
  The tester explicitly scoped to reviewer-flagged gaps; this is a future coverage
  debt, not a defect in the current tests.
- Severity: LOW
- Action: In a future cycle, add two subshell tests mirroring the noncode_dominant
  test: one for mixed_uncertain (verify _bf_emit_routing_diagnosis is called + exit
  code from _bf_invoke_build_fix), one for unknown_only (verify _bf_invoke_build_fix
  receives the low-confidence extra_context block).

#### None (remaining rubric points)

Assertion honesty — CLEAR: SENTINEL values are written by the test itself; exit codes
come from real function execution through the real classify_routing_decision call chain;
the write_pipeline_state arg capture tests real positional argument ordering
(arg1="coder", arg2="env_failure") matching the implementation at
stages/coder_buildfix.sh:139-144.

Weakening — CLEAR: The test_gates_bypass_flow.sh Test 2 assertion flip (was "returns 1",
now "returns 0") is documented inline with a pointer to M127 and correctly reflects
the intentional semantic change to has_only_noncode_errors — unmatched/noise lines
no longer silently coerce to code. This is a legitimate update, not weakening.

Implementation exercise — CLEAR: The noncode_dominant subshell test exercises the
real classify_routing_decision → load_error_patterns → pattern-registry path with
a live "ECONNREFUSED 127.0.0.1:5432" input that genuinely matches the service_dep
pattern (error_patterns_registry.sh:53), producing the expected noncode_dominant
token via pure integer arithmetic. Mocks are minimal and targeted: only the four
side-effectful helpers (write_pipeline_state, append_human_action, _build_resume_flag,
run_build_gate) are stubbed.

Scope alignment — CLEAR: All function references (_bf_read_raw_errors,
_run_buildfix_routing, classify_routing_decision, has_only_noncode_errors) resolve
to current code in lib/error_patterns_classify.sh and stages/coder_buildfix.sh.
No orphaned or stale references detected.

Freshness samples (test_init_synthesize.sh, test_init_synthesize_marker_appending.sh,
test_init_synthesize_preamble_trim.sh) — UNAFFECTED: M127 does not touch
init_synthesize and these files reference no error-classification symbols. No
staleness risk.
