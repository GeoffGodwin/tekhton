# Coder Summary

## Status: COMPLETE

## What Was Implemented

Milestone 127 — Mixed-Log Classification Hardening & Confidence-Based Routing.

The pre-M127 build-fix pipeline had a single binary decision
(`has_only_noncode_errors`) and treated every unmatched line in the build
output as a `code` classification. Real UI logs are noisy: a single npm
warning, ANSI bar, or progress line could force the bypass to fail and route
the run into a build-fix coder pass even when the dominant failure was test
infrastructure or environment. M127 replaces that with a four-token
confidence model.

Implementation summary:

1. **New library `lib/error_patterns_classify.sh`** (234 lines, sourced from
   `lib/error_patterns.sh`):
   - `_is_non_diagnostic_line` — allow-list-first noise filter. The allow-list
     keeps lines containing failure terms (`error|failed|timeout|ECONNREFUSED|TS[0-9]+`)
     even when they would match a deny-list noise pattern; only after the
     allow-list passes do we apply the deny-list (npm warnings, progress
     counters like `[1/8]`, `Serving HTML report at`, ANSI/whitespace-only).
     Acceptance criterion test_filter_does_not_drop_failure_lines and its
     inversion variants are covered.
   - `classify_build_errors_with_stats` — multi-line stats classifier with
     explicit unknown semantics. Unmatched lines are counted under
     `UNMATCHED_LINES`, never silently coerced to `code`. Each emitted record
     carries its own count plus the run-wide `TOTAL_MATCHED|TOTAL_LINES|
     UNMATCHED_LINES` summary so any single record gives a downstream
     consumer the full shape (8 fields per record).
   - `has_explicit_code_errors` — true only when a line matches a
     `category=code` pattern. Used by the refactored
     `has_only_noncode_errors` and indirectly by the routing decision.
   - `classify_routing_decision` — emits one of `code_dominant |
     noncode_dominant | mixed_uncertain | unknown_only` and exports
     `LAST_BUILD_CLASSIFICATION`. Decision rules ordered per the milestone
     Watch For (Rule 1 fires before Rule 3); the 60% noncode threshold uses
     pure integer arithmetic (no `bc` dependency).

2. **`lib/error_patterns.sh`**: sources the new classifier; refactors
   `has_only_noncode_errors` to delegate to the new helpers (semantic shift
   documented inline). Legacy `classify_build_error`,
   `classify_build_errors_all`, and `annotate_build_errors` are intentionally
   unchanged per Watch For.

3. **`lib/artifact_defaults.sh`**: adds `BUILD_ROUTING_DIAGNOSIS_FILE` default
   (`${TEKHTON_DIR}/BUILD_ROUTING_DIAGNOSIS.md`).

4. **New sub-stage `stages/coder_buildfix.sh`** (180 lines, sourced from
   `stages/coder.sh`):
   - `_run_buildfix_routing` — orchestrator. Reads raw errors from
     `BUILD_RAW_ERRORS_FILE` (preserving the existing precedence:
     `stages/coder.sh:1110-1115` pre-extraction), calls
     `classify_routing_decision`, then dispatches per token:
     - `noncode_dominant` → skip build-fix, route to
       `HUMAN_ACTION_REQUIRED.md`, save `env_failure` state and exit.
     - `code_dominant` → run build-fix coder with code-filtered errors
       (legacy path).
     - `mixed_uncertain` → emit `BUILD_ROUTING_DIAGNOSIS.md`, then run
       build-fix with code-filtered errors plus a non-code context block.
     - `unknown_only` → run bounded build-fix with low-confidence guidance,
       preserving pre-M127 fallback semantics.
   - `_bf_emit_routing_diagnosis` — writes `BUILD_ROUTING_DIAGNOSIS.md` with
     a simple schema (header, line stats, top three diagnoses) for downstream
     parsers.
   - `_bf_invoke_build_fix` — shared build-fix invocation helper, accepts an
     `extra_context` block appended to `BUILD_ERRORS_CONTENT`.
   - The orchestrator re-exports `LAST_BUILD_CLASSIFICATION` after capturing
     the routing token via command substitution; the function-internal
     export is bound to the cmd-sub subshell, so the explicit re-export is
     required for downstream M128/M130 consumers running later in the
     parent shell.

5. **`stages/coder.sh`**: build-fix branch reduced to a single
   `_run_buildfix_routing` call (~60 lines removed; net file size
   1180 → 1125). Coder.sh remains over the 300-line ceiling — that is
   pre-existing tech debt out of scope for M127, but my net contribution
   reduces it.

6. **Tests**:
   - `tests/fixtures/ui_timeout_noisy_output.txt` — realistic noisy UI
     timeout fixture (npm warnings, progress lines, multiple Playwright
     timeouts, report-serving banners, plus deliberate unmatched lines).
     Sized so noncode matches (4) hit ≥60% of considered lines (4 / 6 =
     66.6%) → routes `noncode_dominant`.
   - `tests/test_m127_routing.sh` — 288 lines, 41 assertions covering all
     four routing tokens, allow-list-before-deny-list precedence,
     `has_explicit_code_errors`, `classify_build_errors_with_stats` field
     count and unmatched-counter invariants, the bifl-tracker bypass shape,
     `BUILD_ROUTING_DIAGNOSIS.md` emission, and the
     `LAST_BUILD_CLASSIFICATION` export contract.
   - `tests/test_gates_bypass_flow.sh` — Test 2 assertion updated to
     reflect the bifl-tracker class behavior change with an inline pointer
     to this milestone (per Watch For: "if any case now flips, update the
     assertion").
   - `tests/test_error_patterns.sh` — unchanged (M127 portions extracted to
     the dedicated file above to keep my net contribution off the
     already-oversize legacy file).

7. **Docs**:
   - `docs/concepts/auto-remediation.md` — new "Confidence-Based Routing for
     Mixed Logs (M127)" section documenting the four-token model and the
     allow-list-before-deny-list rule.
   - `docs/troubleshooting/common-errors.md` — new "Build errors classified
     as unknown_only" entry with manual-triage guidance and a mention of the
     `noncode_dominant` skip path.
   - `ARCHITECTURE.md` — adds entries for `error_patterns_classify.sh` and
     `coder_buildfix.sh` plus the LAST_BUILD_CLASSIFICATION cross-milestone
     contract.
   - `CLAUDE.md` — repository layout entries added for the two new files.

## Root Cause (bugs only)

N/A — feature milestone, not a bug fix.

## Files Modified

- `lib/error_patterns_classify.sh` (NEW, 234 lines) — confidence classifier.
- `lib/error_patterns.sh` — sources new classifier; refactors
  `has_only_noncode_errors`.
- `lib/artifact_defaults.sh` — adds `BUILD_ROUTING_DIAGNOSIS_FILE` default.
- `stages/coder_buildfix.sh` (NEW, 180 lines) — confidence-based routing
  sub-stage.
- `stages/coder.sh` — replaces the legacy bypass block with
  `_run_buildfix_routing` invocation; sources new sub-stage.
- `tests/fixtures/ui_timeout_noisy_output.txt` (NEW) — realistic noisy
  fixture.
- `tests/test_m127_routing.sh` (NEW, 288 lines) — M127 test coverage.
- `tests/test_gates_bypass_flow.sh` — Test 2 assertion updated for
  bifl-tracker class flip; M127-specific tests extracted to the dedicated
  file.
- `tests/test_error_patterns.sh` — M127 tests extracted to dedicated file
  (no net new content here).
- `docs/concepts/auto-remediation.md` — new M127 routing section.
- `docs/troubleshooting/common-errors.md` — new unknown_only / non-code
  diagnosis entry.
- `ARCHITECTURE.md` — new file entries + cross-milestone contract note.
- `CLAUDE.md` — repository layout updates.

## Human Notes Status

No unchecked human notes were attached to this task.

## Docs Updated

- `docs/concepts/auto-remediation.md` — new "Confidence-Based Routing for
  Mixed Logs (M127)" section.
- `docs/troubleshooting/common-errors.md` — new "Build errors classified as
  unknown_only" entry.
- `ARCHITECTURE.md` — new layer-3 entries for `error_patterns_classify.sh`
  and `coder_buildfix.sh` plus the LAST_BUILD_CLASSIFICATION
  cross-milestone contract documentation.
- `CLAUDE.md` — repository layout updated for the two new lib/stages files.

## Architecture Decisions

- **`LAST_BUILD_CLASSIFICATION` re-export pattern.** The function exports
  the variable internally, but command-substitution callers receive only
  stdout — the export is bound to the subshell. The orchestrator
  (`_run_buildfix_routing`) explicitly re-exports after capturing the
  token. Documented inline so future call sites understand the requirement.
- **M127 tests in a dedicated file.** Both `test_error_patterns.sh` and
  `test_gates_bypass_flow.sh` were already oversize before M127. Rather
  than swelling them further, the M127 unit + integration coverage was
  consolidated in `tests/test_m127_routing.sh`. The discovery loop in
  `tests/run_tests.sh` (`for test_file in "${TESTS_DIR}"/test_*.sh`) picks
  it up automatically.
- **Sub-stage extraction (`stages/coder_buildfix.sh`).** Following the
  established pattern of `stages/coder_prerun.sh`, the M127 routing logic
  lives in its own sub-stage. This keeps `stages/coder.sh` from growing
  further and isolates the M127 contract behind a single
  `_run_buildfix_routing` call site.

## Observed Issues (out of scope)

- `stages/coder.sh` is 1125 lines (was 1180) — well over the 300-line
  ceiling. M127 reduces it but does not bring it under. A dedicated
  refactor splitting `run_stage_coder` into discrete sub-stage
  orchestrators would pay this debt down.
- `tests/test_error_patterns.sh` (855 lines) and several other test files
  exceed the ceiling. Would benefit from per-feature splits similar to
  what M127 did with `test_m127_routing.sh`.
