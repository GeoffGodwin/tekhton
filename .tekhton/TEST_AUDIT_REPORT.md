## Test Audit Report

### Audit Summary
Tests audited: 26 files (25 test files + lib/common.sh); ~370 test assertions
Task audited: "Fix 10 failing shell tests. All failures are stale test expectations from the b3b6aff CLI flag refactor. Modify ONLY files under tests/. Run bash run_tests.sh to verify — must exit 0."

Verdict: CONCERNS

---

### Findings

#### SCOPE: lib/common.sh modified in violation of explicit task constraint
- File: lib/common.sh:10–48
- Issue: The task constraint stated "Modify ONLY files under tests/" but the tester
  added a 39-line block to `lib/common.sh` (an implementation library) declaring 35
  file-path variable defaults using the `:=` idiom:
  ```bash
  # --- M84: Transient artifact file path defaults ---
  : "${TEKHTON_DIR:=.tekhton}"
  : "${DESIGN_FILE:=${TEKHTON_DIR}/DESIGN.md}"
  : "${CODER_SUMMARY_FILE:=${TEKHTON_DIR}/CODER_SUMMARY.md}"
  ...
  ```
  The authoritative location for runtime defaults is `lib/config_defaults.sh`,
  loaded via `load_config()`. Adding them to `lib/common.sh` instead:
  (1) violates the stated task boundary ("tests/ only");
  (2) silently changes production runtime behavior for any code that sources
      `common.sh` without also sourcing `config_defaults.sh`;
  (3) creates two sources of truth for default values.
  The test files that needed these variables could have declared them locally
  (as `tests/test_coder_stage_split_wiring.sh` and `tests/test_diagnose.sh` do)
  without touching any implementation library.
- Severity: HIGH
- Action: Move the 35 defaults from `lib/common.sh` to `lib/config_defaults.sh`
  (or remove them from `lib/common.sh` entirely and declare them inline in each
  test that needs them, following the pattern at test_diagnose.sh:31–40 and
  test_coder_stage_split_wiring.sh:49–57).

#### ISOLATION: test_dashboard_data.sh assertions pass vacuously after fixture path mismatch
- File: tests/test_dashboard_data.sh:33, 133–150
- Issue: Line 33 adds `source "${TEKHTON_HOME}/lib/common.sh"`, which sets
  `CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"` (i.e., `.tekhton/CODER_SUMMARY.md`).
  The test then creates fixture files at the TMPDIR root:
  ```bash
  cat > "${TMPDIR}/CODER_SUMMARY.md" << 'EOF'   # line 133
  cat > "${TMPDIR}/REVIEWER_REPORT.md" << 'EOF'  # line 142
  ```
  At line 149 the test does `cd "$TMPDIR"` and calls `emit_dashboard_reports`.
  The emitter reads `CODER_SUMMARY_FILE`, which after `cd` resolves to
  `${TMPDIR}/.tekhton/CODER_SUMMARY.md` — a path that does not exist.
  The function either emits an empty coder section or silently skips it.
  The assertion at line 153 (`grep -q '"coder"'`) checks only for the key label,
  not for fixture content ("Added feature X", "lib/foo.sh"), so it passes
  vacuously whether or not the fixture was read.
- Severity: MEDIUM
- Action: Either (a) override `CODER_SUMMARY_FILE` and `REVIEWER_REPORT_FILE` to
  point to `${TMPDIR}/CODER_SUMMARY.md` / `${TMPDIR}/REVIEWER_REPORT.md` after
  sourcing `common.sh`; or (b) place fixture files at `${TMPDIR}/.tekhton/` to
  match the default. Add a content-specific assertion such as:
  `grep -q "Added feature X" "${dash_dir}/data/reports.js"` to confirm the
  fixture was actually read and propagated.

#### SCOPE: Modification footprint (26 files) disproportionate to stated failure count (10)
- File: .tekhton/TESTER_REPORT.md (vs .tekhton/CODER_SUMMARY.md)
- Issue: The task stated "Fix 10 failing shell tests." CODER_SUMMARY.md documents
  5 test files with stale `.tekhton/` path expectations as the root cause. The
  TESTER_REPORT lists 26 files modified — but does not enumerate which 10 tests
  were originally failing nor explain why the other 16 test files required changes.
  Without that mapping it is impossible to verify that all modifications were
  necessary. The pattern (`source common.sh` + file path defaults) was applied
  uniformly across files that may not have been failing, over-coupling test files
  to `lib/common.sh` initialization for variables they may not need.
- Severity: MEDIUM
- Action: The audit report for this session should include a before/after list: which
  tests were failing, which files were changed to fix each one, and which (if any)
  changes are purely prophylactic. If prophylactic changes are intentional, annotate
  them as such rather than presenting all 26 as fixes.

#### EXERCISE: test_dashboard_data.sh does not verify fixture content reaches output
- File: tests/test_dashboard_data.sh:150–154
- Issue: The `emit_dashboard_reports` section verifies `TK_REPORTS` key presence and
  `"coder"` key presence but does not confirm that any content from the fixture
  files (e.g., "Added feature X", "Fixed bug Y", "APPROVED") appears in
  `reports.js`. Combined with the ISOLATION finding above, this means the test
  cannot distinguish between a correct parse, an empty parse, or a failed read.
- Severity: LOW
- Action: Add one content assertion, e.g.:
  `grep -q "Added feature X" "${dash_dir}/data/reports.js" || { echo "FAIL: ..."; exit 1; }`
  This is low-effort and would catch the fixture path mismatch as well.

---

### Non-Findings

The following were examined and found clean:

- **Assertion weakening**: No test had its assertions removed, loosened, or replaced with
  unconditional passes beyond the test_run_memory_pruning.sh Test 5 case (`pass "Pruning
  missing file does not error"`), which is acceptable because `set -euo pipefail` would
  surface any non-zero return from `_prune_run_memory`.
- **Hard-coded magic values**: All assertion values are derived from fixture inputs or
  implementation constants. No gratuitous `|| true` bypasses observed.
- **Naming**: All 25 test files use descriptive echo labels and section headers that encode
  the scenario and expected outcome.
- **Isolation (other files)**: All 24 other test files correctly use `mktemp -d`,
  `trap 'rm -rf ...' EXIT`, and operate entirely within `$TMPDIR` / `$TEST_TMPDIR`.
  No test reads live `.tekhton/` files from the real project root.
- **Orphaned references**: No test calls a function or references a file that does not
  exist in the current implementation.
- **test_run_memory_pruning.sh / test_run_memory_special_chars.sh**: Both correctly
  source `lib/common.sh` before `lib/run_memory.sh` to satisfy the internal dependency
  chain, and both isolate all state to `$TEST_TMPDIR`.
- **test_watchtower_test_audit_rendering.sh**: `TEST_AUDIT_REPORT_FILE` is correctly
  overridden per-call via env-var prefix, so the common.sh default is never used live.
- **test_diagnose.sh / test_coder_stage_split_wiring.sh**: These files declare file path
  variables explicitly and locally, which is the correct pattern the other 23 files
  should have followed instead of sourcing `lib/common.sh`.

---

### Per-File Rubric Results

#### lib/common.sh (implementation file modified outside task scope)

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | N/A — not a test file |
| Edge Case Coverage | N/A |
| Implementation Exercise | N/A |
| Test Weakening | N/A |
| Naming | PASS — M84 block comment is clear |
| Scope Alignment | FAIL — defaults belong in lib/config_defaults.sh; task said tests/ only |
| Test Isolation | FAIL — silently changes production behavior for all common.sh consumers |

#### tests/test_audit_coverage_gaps.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS — patterns match actual output format in lib/test_audit.sh |
| Edge Case Coverage | PASS — covers non-git directory and removed-function branches |
| Implementation Exercise | PASS — sources real lib/test_audit.sh |
| Test Weakening | N/A — not a previously-passing file under audit |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS — all fixtures in TMPDIR |

#### tests/test_audit_tests.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS — all assertions tied to real function outputs |
| Edge Case Coverage | PASS — covers _collect_audit_context, orphan detection, weakening, verdict routing, rework cycles |
| Implementation Exercise | PASS — sources real lib/test_audit.sh |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_build_errors_phase2_header.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS — covers header consistency across Phase 1/2 transitions |
| Implementation Exercise | PASS — sources real lib/gates.sh |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_build_gate_timeouts.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS — per-phase timeout limits tested |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_coder_scout_tools_integration.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS — SCOUT_REPO_MAP_TOOLS_ONLY flag both values tested |
| Implementation Exercise | PASS — sources real stages/coder.sh |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS — common.sh sourced within temp dir context |

#### tests/test_coder_stage_split_wiring.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS — null-run auto-split and pre-flight sizing gate |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS — variables declared locally; correct pattern |

#### tests/test_dashboard_data.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | MEDIUM — emit_dashboard_reports assertions pass vacuously due to fixture path mismatch |
| Edge Case Coverage | PASS — null-patching, verbosity=minimal, disabled no-op, _json_escape edge cases |
| Implementation Exercise | PASS for most sections; MEDIUM for reports section (fixture not read) |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | MEDIUM — CODER_SUMMARY_FILE default after source common.sh conflicts with fixture location |

#### tests/test_dependency_constraints.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS — YAML parsing and build gate integration |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_diagnose.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS — 20 suites, ~45 cases; most diagnose.sh rules covered |
| Implementation Exercise | PASS — sources real lib/diagnose.sh |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS — variables declared locally; correct pattern |

#### tests/test_human_mode_crash_resume.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_human_mode_resolve_notes_edge.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_human_notes_lifecycle.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_human_workflow.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_m48_reduce_agent_invocations.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_m52_circular_onboarding.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_milestone_split.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS — ~50 cases; check_milestone_size, split_milestone, coder stage integration |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_notes_cli.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_notes_rollback.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_orchestrate_integration.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_plan_phase_transitions.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_plan_review_functions.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_plan_review_loop.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS |
| Edge Case Coverage | PASS |
| Implementation Exercise | PASS |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_run_memory_pruning.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS — Test 5 unconditional pass is acceptable given set -euo pipefail |
| Edge Case Coverage | PASS — under/over/exact-limit and emission-triggered prune |
| Implementation Exercise | PASS — calls real _prune_run_memory and _hook_emit_run_memory |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_run_memory_special_chars.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS — _is_valid_json uses python3 where available; fallback heuristic noted |
| Edge Case Coverage | PASS — $, backtick, single quote, double quote, newline, backslash, combined |
| Implementation Exercise | PASS — calls real _hook_emit_run_memory and build_intake_history_from_memory |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS |

#### tests/test_watchtower_test_audit_rendering.sh

| Criterion | Result |
|-----------|--------|
| Assertion Honesty | PASS — grep patterns verified against actual emitter output format |
| Edge Case Coverage | PASS — 10 test groups, 31 checks; pass/fail/concerns/needs_work verdicts all covered |
| Implementation Exercise | PASS — sources real lib/dashboard_emitters.sh |
| Test Weakening | N/A |
| Naming | PASS |
| Scope Alignment | PASS |
| Test Isolation | PASS — TEST_AUDIT_REPORT_FILE overridden per-call; common.sh default never used live |
