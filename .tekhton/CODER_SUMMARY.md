# Coder Summary — M133 Diagnose Rule Enrichment for Resilience Arc Failure Modes

## Status: COMPLETE

## What Was Implemented

All eight goals from the milestone spec, plus the mandatory doc surface and
CLAUDE.md layout updates. M133 is diagnose-only — no gate, preflight,
failure-context-writer, or recovery-routing code was modified.

1. **Goal 1 — Implementation kept local to the diagnose layer.** Primary
   rules added to `lib/diagnose_rules.sh` (registry + `_rule_max_turns`
   upgrade), with the three new resilience-arc rule bodies extracted into a
   new sibling file `lib/diagnose_rules_resilience.sh` to honor the
   300-line ceiling. The secondary `_rule_mixed_classification` lives in
   `lib/diagnose_rules_extra.sh` per the spec, and the existing
   migration/version rules were extracted to a new
   `lib/diagnose_rules_migration.sh` so `_extra.sh` had headroom for the
   new rule. No new `_DIAG_*` globals added — all rules parse
   `LAST_FAILURE_CONTEXT.json` and `RUN_SUMMARY.json` directly per the
   existing diagnose contract.

2. **Goal 2 — `_rule_ui_gate_interactive_reporter`** (new, primary).
   Detection sources in priority: (1) `LAST_FAILURE_CONTEXT.json` schema v2
   `primary_cause.signal = ui_timeout_interactive_report` → `high`,
   (2) classification `UI_INTERACTIVE_REPORTER` → `high`,
   (3) raw-log evidence in `BUILD_RAW_ERRORS_FILE` or `.claude/logs/`
   matching `Serving HTML report at` / `Press Ctrl+C to quit` → `medium`,
   (4) `RUN_SUMMARY.json` `causal_context.primary_signal` +
   `recovery_routing.route_taken=retry_ui_gate_env` correlation → `medium`.
   Emits `UI_GATE_INTERACTIVE_REPORTER`. Auto-detects existing
   CI-guarded forms in playwright config and adapts the suggestion text.
   Probes `playwright.config.{ts,js,mjs,cjs}` in priority order.

3. **Goal 3 — `_rule_build_fix_exhausted`** (new, primary). Sources:
   (1) `BUILD_FIX_REPORT_FILE` exists with multi-attempt evidence + last
   `Progress signal` line discriminates `no_progress` vs `exhausted`,
   (2) `RUN_SUMMARY.json` `build_fix_stats.outcome` ∈ {exhausted,
   no_progress} with `attempts >= 2`, (3) `LAST_FAILURE_CONTEXT.json`
   `secondary_cause.signal = build_fix_budget_exhausted`. Required guard:
   at least one of `BUILD_ERRORS_FILE` / `BUILD_RAW_ERRORS_FILE` must be
   non-empty in the current run, so a stale historical report cannot
   produce a false positive. Emits `BUILD_FIX_EXHAUSTED`. Suggestions
   include `BUILD_FIX_REPORT_FILE`, `BUILD_ERRORS_FILE`,
   `BUILD_FIX_MAX_ATTEMPTS`, and `BUILD_FIX_TOTAL_TURN_CAP` knobs.

4. **Goal 4 — `_rule_preflight_interactive_config`** (new, primary).
   Fallback for the case where preflight already saw the issue but the
   gate-level evidence isn't strong enough for the UI-gate rule.
   Sources: (1) `RUN_SUMMARY.json` `preflight_ui.interactive_config_detected
   = true` AND `reporter_auto_patched = false`,
   (2) `PREFLIGHT_REPORT.md` containing the m131-frozen
   `UI Config (Playwright) — html reporter` heading with a fail entry,
   (3) `LAST_FAILURE_CONTEXT.json` classification
   `PREFLIGHT_INTERACTIVE_CONFIG` or primary signal
   `ui_interactive_config_preflight`. Emits
   `PREFLIGHT_INTERACTIVE_CONFIG`. Suggestions include the manual config
   change and `PREFLIGHT_UI_CONFIG_AUTO_FIX=true` knob.

5. **Goal 5 — `_rule_mixed_classification`** (new, secondary, low
   confidence). Sources: classification `MIXED_UNCERTAIN` or signal
   `mixed_uncertain_classification` in either `LAST_FAILURE_CONTEXT.json`
   or `RUN_SUMMARY.json`. Suggestions bias toward inspection (look at
   first causal error in `${BUILD_RAW_ERRORS_FILE}`, re-run preflight
   if environmental) rather than automation. Emits
   `MIXED_UNCERTAIN_CLASSIFICATION` at `low` confidence.

6. **Goal 6 — `_rule_max_turns` upgraded.** No new rule. The existing
   matcher gates on schema-version: when `_DIAG_SCHEMA_VERSION >= 2` AND
   primary cause is non-AGENT (typically `ENVIRONMENT/test_infra`), it
   emits `MAX_TURNS_ENV_ROOT` with a "secondary symptom" framing and
   redirects the user to the root-cause artifact instead of suggesting
   more turns. v1 fixtures (no `schema_version` or `schema_version=0`)
   and AGENT_SCOPE primaries fall through unchanged to the legacy
   `MAX_TURNS_EXHAUSTED` branch — backward-compatibility preserved by
   T10 in the new test file.

7. **Goal 7 — Registry ordering** in `lib/diagnose_rules.sh`. The
   18-element `DIAGNOSE_RULES` is now exactly the order in the spec:
   ui_gate / preflight / build_fix_exhausted / build_failure / max_turns /
   review / security / intake / quota / stuck / mixed / turn_exh /
   split / transient / test_audit / migration / version / unknown.

8. **Goal 8 — Tests** (`tests/test_diagnose_rules_resilience.sh`, NEW,
   426 lines). 26 assertions covering all 12 required scenarios:
   T1 v2 primary signal, T2 raw-log only (medium), T3 unrelated timeout,
   T4 BUILD_FIX_REPORT exhausted, T5 stale-report guard, T6 no_progress
   variant, T7 RUN_SUMMARY preflight_ui, T8 mixed low-conf, T9 env-root,
   T10 v1 backward-compat, T11/T12 priority over BUILD_FAILURE. All
   pass. Existing `tests/test_diagnose.sh` updated for the new
   18-element registry length and the first-five rule-order assertions.

### Pre-Completion Self-Check

- **File length:** every modified or created `.sh` file is under 300 lines:
  `diagnose_rules.sh` 299; `diagnose_rules_extra.sh` 268;
  `diagnose_rules_resilience.sh` 298 (NEW);
  `diagnose_rules_migration.sh` 93 (NEW); test files are not subject to
  the 300-line ceiling.
- **Stale references:** none. The `_rule_migration_crash` /
  `_rule_version_mismatch` move from `_extra.sh` to `_migration.sh` is
  internal (still sourced through the same chain via the new
  `source ${TEKHTON_HOME}/lib/diagnose_rules_migration.sh` line in
  `_extra.sh`); no callers reference the file path. Comment headers in
  both files updated to reflect the move. The legacy "fully replaced
  by m133's MAX_TURNS_ENV_ROOT classification when that lands" note in
  the old max_turns body has been replaced with the actual M133
  branching logic.
- **Dead code:** none. All four new functions appear in `DIAGNOSE_RULES`.
- **Consistency:** new files listed in `CLAUDE.md` repository layout
  (`lib/` subtree) under `diagnose_rules.sh` / `diagnose_rules_extra.sh`
  with an annotation indicating M133 ownership. No new entries to
  `ARCHITECTURE.md` because that document does not enumerate
  `diagnose_rules*.sh` siblings.

## Root Cause (bugs only)

N/A — feature work per the M133 spec.

## Files Modified

| File | Change |
|------|--------|
| `lib/diagnose_rules.sh` | Upgraded `_rule_max_turns` to branch on schema-v2 primary cause and emit `MAX_TURNS_ENV_ROOT` for non-agent roots. Reordered `DIAGNOSE_RULES` to put the three M133 primary rules ahead of `_rule_build_failure`/`_rule_max_turns`, with `_rule_mixed_classification` slotted between `_rule_stuck_loop` and `_rule_turn_exhaustion`. Added `source ...diagnose_rules_resilience.sh` after `_extra.sh`. Trimmed comment header to fit 300-line ceiling. 299 lines. |
| `lib/diagnose_rules_resilience.sh` (NEW) | Three M133 primary rules: `_rule_ui_gate_interactive_reporter`, `_rule_build_fix_exhausted`, `_rule_preflight_interactive_config`. Reads `LAST_FAILURE_CONTEXT.json`, `RUN_SUMMARY.json`, raw-log evidence, and the m131-frozen preflight report heading. Honors the BUILD_FIX_REPORT_FILE / BUILD_ERRORS_FILE / BUILD_RAW_ERRORS_FILE artifact contract. 298 lines. |
| `lib/diagnose_rules_extra.sh` | Added `_rule_mixed_classification` after `_rule_stuck_loop` per spec. Extracted `_rule_migration_crash` and `_rule_version_mismatch` into `lib/diagnose_rules_migration.sh` to make room under the 300-line ceiling; sources the new file inline. Updated header comment. 268 lines. |
| `lib/diagnose_rules_migration.sh` (NEW) | Holds `_rule_migration_crash` and `_rule_version_mismatch` extracted from `_extra.sh`. Sourced by `_extra.sh`. 93 lines. |
| `tests/test_diagnose_rules_resilience.sh` (NEW) | 26 assertions across 12 scenarios (T1–T12) covering all four new rules + the upgraded `_rule_max_turns`. Auto-discovered by `tests/run_tests.sh`. 426 lines. |
| `tests/test_diagnose.sh` | Updated Suite 1 rule-count assertion from 14 to 18 entries; updated rule-order assertions for positions 0–4 and 17 to match the new ordering. 667 lines. |
| `docs/troubleshooting/diagnose.md` | Added a new "Resilience-Arc Classifications (M133)" section before "Build Gate Failure" documenting the five M133 outcomes (`UI_GATE_INTERACTIVE_REPORTER`, `BUILD_FIX_EXHAUSTED`, `PREFLIGHT_INTERACTIVE_CONFIG`, `MIXED_UNCERTAIN_CLASSIFICATION`, `MAX_TURNS_ENV_ROOT`) — symptoms, fires-on conditions, and recovery for each. |
| `CLAUDE.md` | Repository layout updated with `lib/diagnose_rules_migration.sh` and `lib/diagnose_rules_resilience.sh` entries under the existing `diagnose_rules*` cluster. |

## Docs Updated

- `docs/troubleshooting/diagnose.md` — public surface: documents the five
  resilience-arc diagnose vocabulary tokens that are now part of the
  diagnose contract, including detection sources, confidence levels, and
  recovery suggestions per the spec's Seeds Forward declaration that
  these tokens are public diagnose vocabulary.
- `CLAUDE.md` — repository layout updated to list the two new lib
  files.

## Human Notes Status

None — milestone-driven work, no human notes specified for this run.

## Architecture Change Proposals

None. The new `lib/diagnose_rules_resilience.sh` and
`lib/diagnose_rules_migration.sh` follow the existing
`diagnose_rules_extra.sh` extraction pattern (companion-file split for the
300-line ceiling). The diagnose contract itself was not widened — the new
rules consume `LAST_FAILURE_CONTEXT.json` and `RUN_SUMMARY.json` directly,
exactly as the existing rules do, and reuse the existing `_DIAG_PRIMARY_*`
/ `_DIAG_SECONDARY_*` / `_DIAG_LAST_CLASSIFICATION` / `_DIAG_SCHEMA_VERSION`
context. No new `_DIAG_*` globals were added, no module state was reset,
and no caller-visible function signatures changed. The
`_rule_max_turns` upgrade preserves backward compatibility with v1
fixtures (validated by T10).

## Verification

- `shellcheck tekhton.sh lib/*.sh stages/*.sh` → clean (exit 0).
- `bash tests/test_diagnose_rules_resilience.sh` → 26/26 pass.
- `bash tests/run_tests.sh` → Shell 465/465 pass; Python 247/247 pass
  (14 skipped).
- `tests/test_diagnose.sh` reports 4 failures (17.1, 19.1–3) when run
  directly without the run_tests.sh harness. These were already failing
  before M133 (verified via `git stash` baseline: 72 pass / 4 fail
  before; 74 pass / 4 fail after). They are environment-dependent and
  pass under `run_tests.sh`. Out of scope for M133.
- File-size ceiling: every modified or new `lib/` file is under 300
  lines.

## Observed Issues (out of scope)

- `tests/test_diagnose.sh:507,541-558` — Suites 17 and 19 fail when the
  test is run directly because they depend on environment exports the
  `tests/run_tests.sh` harness provides. The four failures are present on
  `main` before M133 and pass via the harness. Not introduced by this
  milestone; appropriate fix is to make those suites self-contained.
