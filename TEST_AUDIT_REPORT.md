## Test Audit Report

### Audit Summary
Tests audited: 2 files, ~30 test assertions
Verdict: CONCERNS

Note: `CODER_SUMMARY.md` was absent at audit time (file not present in working tree).
Implementation was verified directly from `lib/common.sh` (timing helpers) and
`lib/timing.sh` (report generation), which are the files exercised by the test suites.

---

### Findings

#### INTEGRITY: Tautological assertion in unclosed-phase auto-close test
- File: tests/test_timing_report_generation.sh:209
- Issue: The assertion `[[ "$dur" -ge 0 ]]` can never be false. `_get_phase_duration`
  returns `${_PHASE_TIMINGS[name]:-0}`, which is always a non-negative integer (0 if
  not found, positive if recorded). If `_hook_emit_timing_report` fails to auto-close
  the orphan phase, `_get_phase_duration "orphan"` returns 0, and `0 -ge 0` is true —
  the test passes even when the feature is broken. The fail branch on line 211 can
  never execute. The phase was seeded with `_PHASE_STARTS[orphan]=1000000000` (epoch
  ~2001), so a successful auto-close produces a large positive duration. The correct
  assertion is `[[ "$dur" -gt 0 ]]`.
- Severity: HIGH
- Action: Change `[[ "$dur" -ge 0 ]]` to `[[ "$dur" -gt 0 ]]` on line 209.

#### COVERAGE: `grep -oP` (PCRE) portability risk in percentage sum test
- File: tests/test_timing_report_generation.sh:101
- Issue: `grep -oP '\d+(?=%)'` requires GNU grep compiled with PCRE support. On
  macOS (BSD grep) or minimal Linux containers, the `-P` flag is unavailable. The
  `|| echo ""` fallback silently suppresses the error and leaves `pct` empty for
  every line, resulting in `pct_sum=0`. The subsequent check
  `[[ "$pct_sum" -ge 90 ]] && [[ "$pct_sum" -le 110 ]]` then fails — but for the
  wrong reason, masking real failures on supported systems too.
- Severity: MEDIUM
- Action: Replace the PCRE grep with a portable POSIX alternative. E.g.:
  `pct=$(echo "$line" | grep -oE '[0-9]+%' | grep -oE '[0-9]+')`
  or extract the percentage column with `awk -F'|' '{print $4}'` on table rows.

#### COVERAGE: "missing _phase_end" test makes no state assertion
- File: tests/test_timing_helpers.sh:57-65
- Issue: After calling `_phase_end "nonexistent_phase"`, the test unconditionally
  calls `pass "Missing _phase_end handled gracefully"`. While `set -euo pipefail`
  provides implicit crash detection, no assertion verifies that `_PHASE_TIMINGS` was
  not modified and that `_PHASE_STARTS[orphan_phase]` still exists (the phase was
  started but never ended — it should remain open). The test exercises the
  non-crash property only.
- Severity: LOW
- Action: Add two state assertions: (1) verify `_get_phase_duration "nonexistent_phase" -eq 0`
  (no timing recorded for a phase that was never started), and (2)
  `[[ -n "${_PHASE_STARTS[orphan_phase]:-}" ]]` (the started-but-unclosed phase is
  still in `_PHASE_STARTS`).

#### COVERAGE: `_compute_total_phase_time` and TOTAL_TIME=0 fallback path untested
- File: tests/test_timing_report_generation.sh (gap)
- Issue: `_compute_total_phase_time` is never called directly. It is only reachable
  when `_format_timing_banner` or `_hook_emit_timing_report` is invoked with
  `TOTAL_TIME=0` or `TOTAL_TIME` unset. Both tests always set `TOTAL_TIME=388`,
  so the fallback computation path in both functions is never exercised. A bug in
  `_compute_total_phase_time` (e.g., wrong iteration over `_PHASE_TIMINGS`) would
  not be caught.
- Severity: LOW
- Action: Add one test that calls `_hook_emit_timing_report 0` with `TOTAL_TIME`
  unset (or `TOTAL_TIME=0`) and a non-empty `_PHASE_TIMINGS`. Verify the report
  is generated and that percentages are non-zero, exercising the fallback path
  through `_compute_total_phase_time`.

---

### Findings: None for the following categories

#### None (Test Weakening / WEAKENING)
Both test files are new (untracked in git status). No existing tests were modified.

#### None (Naming)
All test section names encode the scenario and expected outcome. Examples:
"_phase_end without _phase_start is graceful", "accumulation (repeated phases)",
"phases sorted by duration descending", "empty phase timings skips report".

#### None (Scope Alignment / SCOPE)
No orphaned or stale tests detected. All functions under test (`_phase_start`,
`_phase_end`, `_get_phase_duration`, `_format_duration_human`, `_get_epoch_secs`,
`_hook_emit_timing_report`, `_get_top_phases`, `_format_timing_banner`,
`_phase_display_name`) are present in `lib/common.sh` and `lib/timing.sh`.

#### None (Exercise)
Tests call the real implementations directly. `lib/common.sh` is sourced for timing
helpers; `lib/timing.sh` is sourced for report functions. No function-under-test is
replaced with a stub.
