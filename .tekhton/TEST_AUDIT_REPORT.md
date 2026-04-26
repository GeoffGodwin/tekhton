---
## Test Audit Report

### Audit Summary
Tests audited: 2 files, 17 test functions
  - tests/test_m127_buildfix_routing.sh — 8 assertions across 4 test sections (M128 update: function rename only)
  - tests/test_build_fix_loop.sh — 9 test cases (T3–T10 + T9d-ext) covering the new M128 continuation loop
Verdict: PASS

### Findings

#### ISOLATION: _safe_read_file sourced optionally in test_m127_buildfix_routing.sh (pre-existing from M127)
- File: tests/test_m127_buildfix_routing.sh:25
- Issue: lib/prompts.sh is sourced with 2>/dev/null || true (graceful / optional), but
  _bf_read_raw_errors() — called directly in test sections 1 and 2 — delegates to
  _safe_read_file, which is defined in lib/prompts.sh. If prompts.sh fails to load for
  any reason, those two test sections crash with "command not found" under set -euo pipefail
  rather than reporting a clean test failure. M128 did not introduce this issue; it is carried
  forward from M127. By contrast, tests/build_fix_loop_fixtures.sh correctly stubs
  _safe_read_file for the new test_build_fix_loop.sh, so the M128 tests do not have this gap.
- Severity: MEDIUM
- Action: Add a one-line stub in test_m127_buildfix_routing.sh after the prompts.sh source
  line (line 25): _safe_read_file() { [[ -f "$1" ]] && cat "$1"; } — matches the fixture
  stub in build_fix_loop_fixtures.sh:33 and makes the test environment-independent.

#### COVERAGE: mixed_uncertain routing arm not exercised by test_build_fix_loop.sh
- File: tests/test_build_fix_loop.sh (all T3–T10)
- Issue: reset_state() in build_fix_loop_fixtures.sh:121 always restores
  STUB_ROUTING="code_dominant". No test sets STUB_ROUTING="mixed_uncertain", so the
  if [[ "$decision" == "mixed_uncertain" ]] branch in run_build_fix_loop
  (coder_buildfix.sh:143-145) and the _bf_emit_routing_diagnosis call site are never
  reached. The BUILD_ROUTING_DIAGNOSIS_FILE is never written during any test run.
  The loop behavior after that branch is identical to code_dominant, but the branch
  itself and the diagnosis file emission go unexercised.
- Severity: MEDIUM
- Action: Add a sub-case (e.g., T11) that sets STUB_ROUTING="mixed_uncertain", calls
  reset_state + run_loop_capture, and asserts: (1) OUTCOME is a valid token, and (2)
  BUILD_ROUTING_DIAGNOSIS_FILE exists. classify_build_errors_with_stats is already
  stubbed to : so the file will be created with the header and empty diagnoses —
  sufficient to verify the write path.

#### COVERAGE: unknown_only routing arm not exercised
- File: tests/test_build_fix_loop.sh (all T3–T10)
- Issue: No test sets STUB_ROUTING="unknown_only". The _bf_extra_context_for_decision("unknown_only")
  branch (coder_buildfix_helpers.sh:214-218) returns a non-empty low-confidence note string;
  the code_dominant path returns empty. The branching goes unexercised, though since run_agent
  is stubbed the extra_context difference does not affect loop termination outcomes.
- Severity: LOW
- Action: A STUB_ROUTING="unknown_only" sub-case alongside T11 is sufficient. Assert loop
  completes with a valid OUTCOME.

#### NAMING: T9d-ext uses a non-standard capture pattern without explanation
- File: tests/test_build_fix_loop.sh:241-261
- Issue: T9d-ext creates a hand-rolled subshell with a custom write_pipeline_state stub
  rather than the standard reset_state -> run_loop_capture -> field pattern used by all
  other sub-tests. It does not call reset_state() before the subshell. This is correct
  (the export BUILD_FIX_ENABLED=false inside the subshell is authoritative, and the
  environment inherited from T9d is already clean), but the asymmetry is unexplained.
- Severity: LOW
- Action: Add a one-line comment before the subshell explaining why run_loop_capture is
  not used: run_loop_capture captures only the NOTES field (5th positional arg via
  WROTE_STATE_NOTES), but T9d-ext asserts individual arg positions (arg1="coder",
  arg2="build_failure") — the direct printf approach is the right tool here.

### Rubric Notes

Assertion Honesty — CLEAR: Sentinel strings in _bf_read_raw_errors tests are written
by the test itself; assertions verify real function outputs. T3–T10 outcome assertions derive
from real execution through run_build_fix_loop, _compute_build_fix_budget,
_build_fix_progress_signal, and _append_build_fix_report. No hard-coded values that
bypass implementation logic were found. Budget math for T6 was independently verified: with
EFFECTIVE_CODER_MAX_TURNS=80 and BUILD_FIX_TOTAL_TURN_CAP=40, attempt 1 budget=26,
attempt 2 budget=min(39, remaining=14)=14, attempt 3 returns 0 from _compute_build_fix_budget
(cumulative cap reached), yielding ATTEMPTS=2 and USED=40 — within the asserted bounds.

Test Weakening — CLEAR: The only modification to test_m127_buildfix_routing.sh was
renaming _run_buildfix_routing -> run_build_fix_loop per CODER_SUMMARY.md. All
behavioral assertions are preserved. No removed assertions, broadened checks, or removed
edge-case tests detected.

Implementation Exercise — CLEAR: The noncode_dominant test exercises the real
classify_routing_decision (loaded via lib/error_patterns.sh:25 -> error_patterns_classify.sh:180).
The literal input "ECONNREFUSED 127.0.0.1:5432" genuinely triggers the noncode_dominant path
per the 60% noncode threshold rule. For test_build_fix_loop.sh, stubs are minimal and
targeted — only side-effectful helpers (run_agent, run_build_gate, write_pipeline_state,
append_human_action) are replaced; all loop logic, budget arithmetic, progress signaling,
and report writing execute through real implementation code.

Scope Alignment — CLEAR: All function references in both test files resolve to current
symbols in stages/coder_buildfix.sh and stages/coder_buildfix_helpers.sh. The old name
_run_buildfix_routing does not appear in either file. No orphaned, stale, or dead references.

Test Isolation — CLEAR: Both files use mktemp -d for all I/O. No live pipeline artifacts,
.tekhton/ state files, .claude/logs/*, or run-time reports are read without fixture setup.
reset_state() properly clears all relevant state and removes artifact files between sub-tests.
The state_log.txt accumulation from the write_pipeline_state stub is benign — no assertion
reads it.
