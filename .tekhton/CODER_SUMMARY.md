# Coder Summary — M132 RUN_SUMMARY Causal Fidelity Enrichment

## Status: COMPLETE

## What Was Implemented

All ten goals from the milestone spec, plus the mandatory doc surface and
CLAUDE.md layout updates:

1. **Goal 1 — `_collect_causal_context_json`** (`lib/finalize_summary_collectors.sh`):
   reads `LAST_FAILURE_CONTEXT.json` via m130's `_load_failure_cause_context`
   loader and emits the cause object. Returns the absent-file sentinel
   `{"schema_version":0}` when the file is missing (m135 success-run cleanup
   relies on this). Honors `ORCH_CONTEXT_FILE_OVERRIDE` so tests can swap
   in fixtures without manipulating `$PROJECT_DIR`.

2. **Goal 2 — `_collect_build_fix_stats_json`**: reads the four
   `BUILD_FIX_*` exports (m128 contract). Returns `outcome=not_run /
   enabled=false` when no attempts ran. Numeric inputs are validated
   against `^[0-9]+$` before being passed to `printf '%d'` so a corrupted
   env var can't crash the finalize hook.

3. **Goal 3 — `_collect_recovery_routing_json`**: reads m130 module-level
   recovery vars (`_ORCH_RECOVERY_ROUTE_TAKEN`, `_ORCH_ENV_GATE_RETRIED`,
   `_ORCH_MIXED_BUILD_RETRIED`, `_ORCH_SCHEMA_VERSION`). Default
   `route_taken="save_exit"` keeps the success-run shape stable.

4. **Goal 4 — `_collect_preflight_ui_json`**: reads the four
   `PREFLIGHT_UI_*` env vars (m131 contract) plus `_PF_FAIL` /
   `_PF_WARN`. JSON-escapes the rule and file basename strings.

5. **Goal 5 — `error_classes_encountered` enrichment** (extracted to
   `_collect_error_classes_json` so `finalize_summary.sh` stays under
   300 lines): returns `[symptom]` when `AGENT_ERROR_CATEGORY` is set,
   appends `"root:CAT/SUB"` when m130's primary cause differs from
   the symptom, and skips the root suffix when they match (no
   duplicate). Calls `_load_failure_cause_context` to refresh
   `_ORCH_PRIMARY_*` if not already populated by the caller.

6. **Goal 6 — `recovery_actions_taken` enrichment** (extracted to
   `_collect_recovery_actions_json`): preserves the legacy event flags
   (`review_cycle_bump`, `continuation`, `transient_retry`) and appends
   `_ORCH_RECOVERY_ROUTE_TAKEN` when non-default (`save_exit` and empty
   are no-op defaults).

7. **Goal 7 — Four new top-level fields**: `causal_context`,
   `build_fix_stats`, `recovery_routing`, `preflight_ui` slotted into
   the printf format string immediately before `timestamp`. Always
   present on success and failure runs.

8. **Goal 8 — Per-iteration recovery route capture**
   (`lib/orchestrate_loop.sh`): added
   `_ORCH_RECOVERY_ROUTE_TAKEN="$recovery"` immediately after
   `recovery=$(_classify_failure)` so the route is captured for every
   recovery action, not only `retry_ui_gate_env`. m130's case-branch
   assignments (e.g., `split_escalated`) still run after this and
   specialize the value where appropriate. m130's `Lifetime B`
   declaration in `orchestrate_recovery_causal.sh` was already in place
   (per its hard-dependency status in MANIFEST.cfg) so no new declaration
   was needed here.

9. **Goal 9 — Dashboard parser extension**
   (`lib/dashboard_parsers_runs_files.sh`): extended the
   `python3 -c 'import json; ...'` dict with seven new fields
   (`causal_primary_category`, `causal_primary_subcategory`,
   `build_fix_outcome`, `build_fix_attempts`, `recovery_route`,
   `preflight_ui_detected`, `preflight_ui_patched`). Added matching
   `sed -n` bracket-expression fallback lines for `recovery_route` and
   `build_fix_outcome` (no `grep -oP` introduced — preserves BSD
   portability per the existing style). Renderer-side badge work
   deferred per Goal 9 option 1 — no `_build_run_badge*` helper exists
   in the codebase, m134 S5.1 doesn't gate on badges, and inventing one
   would scope-creep into Watchtower polish.

10. **Goal 10 — Tests** (`tests/test_m132_run_summary_enrichment.sh`):
    16 assertions covering T1–T10 as scoped in the milestone (T1 v2
    fixture, T2 v1 fixture, T3 absent-file, T4 m128 vars, T5 no vars,
    T6 root-prefix on distinct primary, T7 no-duplicate when primary
    matches symptom, T8 route appended when non-default, T9 save_exit
    excluded, T10 full RUN_SUMMARY.json emitted with all four keys +
    empty-state assertions for M134 S5.2 contract + python json
    validity check). All 16 pass.

### Test maintenance

Two existing tests had hard-coded `sed -n '165p'` line-number assertions
that broke when the M132 enrichment shifted offsets (the source line for
the collectors file moved everything down). Fixed both to locate the
guard via `grep -n` so they stay resilient to future drift:

- `tests/test_finalize_summary_tester_guard.sh` — replaced four
  brittle `sed -n '<n>p'` calls with a `grep -n` line lookup + offset
  arithmetic. Now passes 4/4.
- `tests/test_m62_fixes_integration.sh` — replaced one `sed -n '165p'`
  with a plain `grep -q`. Now passes 10/10.

### Pre-Completion Self-Check

- **File length:** all touched lib files under 300 lines
  (`finalize_summary.sh`: 287; `finalize_summary_collectors.sh`: 171;
  `orchestrate_loop.sh`: 286; `dashboard_parsers_runs_files.sh`: 105).
- **Stale references:** none. New file added to CLAUDE.md repository
  layout. No renamed identifiers.
- **Dead code:** none. All helpers in
  `finalize_summary_collectors.sh` are called by the printf composition
  in `_hook_emit_run_summary`.
- **Consistency:** new file
  `lib/finalize_summary_collectors.sh` listed in `## Files Modified`
  with `(NEW)` annotation; CLAUDE.md repository layout updated to
  include it under the `lib/` subtree.

## Root Cause (bugs only)

N/A — feature work per the M132 spec.

## Files Modified

| File | Change |
|------|--------|
| `lib/finalize_summary_collectors.sh` (NEW) | Six collectors: `_collect_causal_context_json`, `_collect_build_fix_stats_json`, `_collect_recovery_routing_json`, `_collect_preflight_ui_json`, `_collect_error_classes_json`, `_collect_recovery_actions_json`. 171 lines. |
| `lib/finalize_summary.sh` | Sources `finalize_summary_collectors.sh`. Replaced inline `error_classes_encountered` and `recovery_actions_taken` building blocks with calls to the collectors. Added four new top-level fields (`causal_context`, `build_fix_stats`, `recovery_routing`, `preflight_ui`) to the printf format string and arg list. 287 lines (was 282 — net +5 after extraction). |
| `lib/orchestrate_loop.sh` | Added `_ORCH_RECOVERY_ROUTE_TAKEN="$recovery"` immediately after `recovery=$(_classify_failure)` in `_handle_pipeline_failure` so every recovery route (not only `retry_ui_gate_env`) is captured. One-line change plus 4 lines of comment context. |
| `lib/dashboard_parsers_runs_files.sh` | Extended the `python3 -c` JSON dict with seven new fields. Added `sed -n` fallback extractions for `recovery_route` and `build_fix_outcome` using bracket-expression patterns (no `grep -oP` introduced). |
| `tests/test_m132_run_summary_enrichment.sh` (NEW) | T1–T10 + sub-cases — 16 assertions, all pass. Auto-discovered by `tests/run_tests.sh`. |
| `tests/test_finalize_summary_tester_guard.sh` | Replaced hard-coded `sed -n '165p'` with `grep -n` lookup + offset arithmetic so the test stays resilient to file-offset shifts. 4/4 pass. |
| `tests/test_m62_fixes_integration.sh` | Replaced hard-coded `sed -n '165p'` with `grep -q`. 10/10 pass. |
| `docs/reference/run-summary-schema.md` (NEW) | Documents the four enrichment fields, updated `error_classes_encountered` / `recovery_actions_taken` contracts, empty-state variants, and backward-compatibility guarantee. |
| `CLAUDE.md` | Repository layout updated with `lib/finalize_summary_collectors.sh` entry. |

## Docs Updated

- `docs/reference/run-summary-schema.md` (NEW) — public surface: documents
  the four new top-level RUN_SUMMARY.json fields (`causal_context`,
  `build_fix_stats`, `recovery_routing`, `preflight_ui`), the updated
  `error_classes_encountered` / `recovery_actions_taken` contracts, the
  empty-state variants emitted on success runs (M134 S5.2 contract), and
  the backward-compatibility additive-only guarantee for external
  dashboard consumers.
- `CLAUDE.md` — repository layout listing updated with
  `lib/finalize_summary_collectors.sh`.

## Human Notes Status

None — milestone-driven work, no human notes specified for this run.

## Architecture Change Proposals

None. The new `lib/finalize_summary_collectors.sh` follows the existing
`finalize_*.sh` extraction pattern (e.g., `finalize_aux.sh`,
`finalize_commit.sh`, `finalize_dashboard_hooks.sh`). The `printf`
extension to `_hook_emit_run_summary` is purely additive — keys at the
end, empty-state variants emitted on success runs to keep the JSON shape
stable. The dashboard parser extension reuses the existing python3 + sed
two-track style (no new portability assumptions). The
`lib/orchestrate_loop.sh` line is a single capture-point addition that
preserves m130's case-branch specialization semantics.

## Verification

- `shellcheck tekhton.sh lib/*.sh stages/*.sh` → clean (exit 0).
- `bash tests/test_m132_run_summary_enrichment.sh` → 16/16 pass.
- `bash tests/test_finalize_summary_tester_guard.sh` → 4/4 pass.
- `bash tests/test_m62_fixes_integration.sh` → 10/10 pass.
- `bash tests/test_finalize_summary_escaping.sh` → all assertions pass
  (no regression — base RUN_SUMMARY.json shape unchanged for legacy
  consumers).
- `bash tests/run_tests.sh` → 464 shell pass / 0 fail; 247 Python pass.
- File-size ceiling: every modified `lib/` file is under 300 lines.

## Docs Updated

- `README.md` — added reference to `docs/reference/run-summary-schema.md` in the "What's in `docs/`" table, positioned after metrics documentation since RUN_SUMMARY.json is consumed by metrics dashboards and external integrations.
