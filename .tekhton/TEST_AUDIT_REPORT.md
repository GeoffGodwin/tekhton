## Test Audit Report

### Audit Summary
Tests audited: 2 files, 12 test scenarios (S3.4–S3.7 in test_resilience_arc_loop.sh;
S8.T3–S8.T10 in test_resilience_arc_integration.sh)
Verdict: PASS

---

### Findings

#### NAMING: Tester report undersells integration coverage scope
- File: .tekhton/TESTER_REPORT.md (planned-tests section)
- Issue: The tester report entry for `test_resilience_arc_integration.sh` names only
  "S8.T10: full integration." The file actually received eight new scenarios (T3–T10).
  T3–T9 are the core M135 acceptance tests: artifact removal on success (T3, T4),
  retention on failure (T5), over-limit trim (T6), under-limit no-op (T7), retain=0
  disable (T8), and missing-dir no-op (T9). T10 is the integration capstone. Listing
  only T10 obscures which acceptance criteria were verified and makes pre-accept review
  harder.
- Severity: LOW
- Action: Update the planned-tests entry to enumerate S8.T3–S8.T10 individually. No
  test code changes required.

#### NAMING: Tester pass count scope is ambiguous
- File: .tekhton/TESTER_REPORT.md (Test Run Results section)
- Issue: "Passed: 18  Failed: 0" appears to count only new assertions added this run,
  not the full file totals. The coder's verification records 71 passed for the full
  integration file and 467 + 247 for the full suite. The ambiguity makes it impossible
  to tell from the report whether the count means "18 new scenarios passed" or
  "18 total assertions in the modified files."
- Severity: LOW
- Action: Annotate the count with scope ("18 new assertions across both files, full
  suite: 467 shell + 247 Python") or use full-file counts.

#### SCOPE: test_resilience_arc_loop.sh tests M128 loop, not M135 features
- File: tests/test_resilience_arc_loop.sh:1 (file header)
- Issue: The file header reads "M134 coverage gap" and the tester report labels S3.4–S3.7
  as covering a reviewer gap from M134. All four scenarios exercise `run_build_fix_loop`
  from `stages/coder_buildfix.sh` (M128). No M135 features (`_clear_arc_artifacts_on_success`,
  `_trim_preflight_bak_dir`, `PREFLIGHT_BAK_DIR` default) appear in this file. The tests
  are correct and beneficial, but they are deferred M134 regression tests, not M135
  acceptance tests. Mislabeling complicates traceability.
- Severity: LOW
- Action: Update the tester report to label these as "M134 coverage debt (deferred)" with
  a note that they were added during the M135 tester pass. No test code changes needed.

---

### Rubric Detail

**1. Assertion Honesty — PASS**

test_resilience_arc_loop.sh: All `assert_eq` targets are derived from the implementation.
`"passed"` / `"exhausted"` / `"no_progress"` are the exact `BUILD_FIX_OUTCOME` tokens
written by `_export_build_fix_stats` in `stages/coder_buildfix_helpers.sh`. Attempt
counts match the loop's `BUILD_FIX_ATTEMPTS` bookkeeping including the
`attempt=$(( attempt - 1 ))` decrement on turn-cap-below-floor exit (S3.7). The
report-section count (`grep -c '^## Attempt'`) is verified against the `## Attempt N`
header written by `_append_build_fix_report`. S3.4's `TURN_BUDGET_USED > 0` check is
correct: with `EFFECTIVE_CODER_MAX_TURNS=80` and default divisor 3, the attempt-1 budget
is 26 turns, which the loop accumulates before the gate.

test_resilience_arc_integration.sh S8: Artifact path construction in T3–T5 matches
`_clear_arc_artifacts_on_success`'s path resolution exactly: the function uses
`"${_p}/${BUILD_FIX_REPORT_FILE}"` with `_p="${PROJECT_DIR:-.}"` and the same
`BUILD_FIX_REPORT_FILE` variable the test creates the fixture under. File-count assertions
in T6–T10 derive from arithmetic on fixture inputs (7 files − retain 5 = 2 removed; 3 ≤ 5
so no removal; retain=0 so no removal; 7 + 1 new = 8 then retain 5 → 3 removed).
No tautological or hard-coded-for-its-own-sake assertions found.

**2. Edge Case Coverage — PASS**

test_resilience_arc_loop.sh covers four distinct behavioral paths: success on attempt 1,
max-attempts exhaustion, no-progress halt, and turn-cap-below-floor pre-loop exit. This
covers all four documented exit conditions from `run_build_fix_loop`.

test_resilience_arc_integration.sh S8 covers: success artifact removal (T3, T4), failure
retention symmetry (T5), over-limit trim (T6), under-limit no-op (T7), retain=0
disable-trimming (T8), missing-dir no-op (T9), and the full declare-f integration chain
(T10). Both success and failure branches of `_hook_emit_run_summary` are exercised.

**3. Implementation Exercise — PASS**

test_resilience_arc_loop.sh: `run_build_fix_loop` is called directly. Only four stubs are
used: `_bf_invoke_build_fix` (agent call), `run_build_gate` (gate subprocess),
`write_pipeline_state` (state I/O), `_build_resume_flag` (state string). All loop
internals run through real code: `_compute_build_fix_budget`, `_build_fix_progress_signal`,
`_bf_count_errors`, `_bf_get_error_tail`, `_append_build_fix_report`,
`_build_fix_terminal_class`, and `classify_routing_decision`. Correct minimal-stub strategy.

test_resilience_arc_integration.sh S8: `_hook_emit_run_summary` is called with real exit
codes, exercising `_clear_arc_artifacts_on_success` through its actual call site in
`finalize_summary.sh:37`. `_trim_preflight_bak_dir` is called directly in T6–T9 and
through the `declare -f` guard at `preflight_checks_ui.sh:185` in T10 — the exact
production call site that was previously untested (noted by the reviewer, verified here).

**4. Test Weakening — N/A**

Both files received only additions. No existing assertions were removed or broadened.

**5. Naming and Intent — PASS**

test_resilience_arc_loop.sh: Each scenario is labeled with `echo "=== S3.N: ... ==="` lines
that encode scenario ID and expected outcome. Per-assertion labels in `assert_eq` specify the
field under test (e.g., `"S3.5 OUTCOME=exhausted"`, `"S3.5 report has 2 attempt sections"`).

test_resilience_arc_integration.sh S8: Scenario headers encode the scenario ID, the
condition, and the expected outcome (e.g., "S8.T6: preflight_bak with 7 files, retain=5
→ 2 oldest removed"). Sub-assertions within each scenario are self-describing
(`"S8.T6 oldest 2 backups removed"`, `"S8.T6 newest 5 backups retained"`).

**6. Scope Alignment — PASS**

All function references are live in the current codebase:
- `run_build_fix_loop` exists in `stages/coder_buildfix.sh`
- `_clear_arc_artifacts_on_success` was added to `lib/finalize_summary_collectors.sh`
- `_trim_preflight_bak_dir` was added to `lib/preflight_checks.sh`
- `_hook_emit_run_summary` exists in `lib/finalize_summary.sh` and calls
  `_clear_arc_artifacts_on_success` on its success branch (verified at line 37)
- `_preflight_check_ui_test_config` exists in `lib/preflight_checks_ui.sh` and invokes
  `_trim_preflight_bak_dir` via `declare -f` guard at lines 185–186

No references to deleted or renamed symbols found. The M135 hermeticity fix
(`unset PROJECT_DIR PREFLIGHT_BAK_DIR` at the top of the integration test file) is
correctly placed and motivated by the new `:=` default in `artifact_defaults.sh:58`.

**7. Test Isolation — PASS**

Both files create `TMPDIR_TOP=$(mktemp -d)` with `trap 'rm -rf "$TMPDIR_TOP"' EXIT`.
Each scenario allocates its own subdirectory via `_arc_setup_scenario_dir` (integration)
or `_setup_loop_scenario` (loop), exporting all artifact paths as absolute paths under
that subdirectory. `_arc_reset_orch_state` and `_arc_reset_preflight_state` are called
between scenarios. No mutable workspace files (`.tekhton/`, `.claude/logs/`) are read
without first creating a fixture copy in the per-scenario temp directory.

---

### STALE-SYM Warning Disposition

All 17 STALE-SYM warnings in `test_resilience_arc_integration.sh` reference POSIX shell
builtins (`return`, `set`, `source`, `trap`, `true`) or standard external utilities
(`cat`, `cd`, `command`, `dirname`, `echo`, `find`, `grep`, `head`, `mkdir`, `mktemp`,
`pwd`, `rm`). The shell-based symbol detector cannot distinguish these from Tekhton-internal
function references. No orphaned test symbol references are present. All are detector
artifacts requiring no action.
