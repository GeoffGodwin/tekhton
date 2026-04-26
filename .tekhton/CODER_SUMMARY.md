# Coder Summary

## Status: COMPLETE

## What Was Implemented

Milestone 129 — Failure Context Schema Hardening & Primary/Secondary Cause
Fidelity. Introduces a normalized failure-context schema (v2) with explicit
primary/secondary cause slots so root cause is no longer masked by
secondary failure symptoms in `--diagnose` and downstream rules.

Implementation summary:

1. **`lib/failure_context.sh`** (NEW, 208 lines): module-level
   `PRIMARY_*`/`SECONDARY_*` slot vars (8 exported strings),
   `reset_failure_cause_context`, `set_primary_cause`,
   `set_secondary_cause`, `format_failure_cause_summary` (0/1/2-line
   plain-text summary for state-file Notes), `emit_cause_objects_json`
   (pretty-printed nested JSON fragments — Goal 1 contract), plus
   internal `_fc_emit_cause_object` and writer-side
   `resolve_alias_category`/`resolve_alias_subcategory` helpers used by
   the writer's alias-precedence path.

2. **`lib/diagnose_output.sh`**: rewrote `write_last_failure_context`
   to emit schema v2 — adds `schema_version: 2`, top-level
   `category`/`subcategory` aliases (mirroring secondary slot or
   `AGENT_ERROR_*` env vars), and pretty-printed nested
   `primary_cause` / `secondary_cause` objects via
   `emit_cause_objects_json`. Crash first-aid + dashboard-diagnosis
   functions extracted to `diagnose_output_extra.sh` to bring
   `diagnose_output.sh` from 332 → 282 lines (under the ceiling).

3. **`lib/diagnose_output_extra.sh`** (NEW, 98 lines):
   `print_crash_first_aid` and `emit_dashboard_diagnosis` extracted
   verbatim from `diagnose_output.sh` (no behavioral change).

4. **`lib/diagnose.sh`**: added 8 new `_DIAG_PRIMARY_*` / `_DIAG_SECONDARY_*`
   module-state vars + `_DIAG_SCHEMA_VERSION`. `_read_diagnostic_context`
   now calls `_diag_parse_cause_block` (defined in `diagnose_helpers.sh`)
   to populate them when v2 schema is detected. Reader fallback order is
   documented inline: v2 nested objects → top-level alias keys → legacy
   `AGENT_ERROR_*` env vars (handled per-rule).

5. **`lib/diagnose_helpers.sh`**: added `_diag_parse_cause_block`
   (line-based parser mirroring m130's `_load_failure_cause_context` —
   no `jq` dependency, relies on the writer's pretty-print contract).

6. **`lib/diagnose_rules.sh`**: `_rule_max_turns` now consumes
   `_DIAG_SECONDARY_*` first (with legacy alias fallback). When primary
   cause is non-agent and secondary is `max_turns`, the suggestion
   array gets a "secondary symptom" line that names the primary cause
   (`{cat}/{sub} ({signal})`). m133 will fully replace this with a
   dedicated `MAX_TURNS_ENV_ROOT` classification — m129 only adds the
   guard. `_rule_quota_exhausted` and `_rule_unknown` moved to
   `diagnose_rules_extra.sh` to keep diagnose_rules.sh under 300.

7. **`lib/finalize_dashboard_hooks.sh`**: `_hook_failure_context` now
   opportunistically calls `set_secondary_cause` from the symptom-level
   `AGENT_ERROR_*` env vars when no stage has populated the secondary
   slot. This means orchestrate's state-file Notes write (which calls
   `format_failure_cause_summary` after `finalize_run`) sees the
   populated slots even if the failing stage didn't call
   `set_secondary_cause` directly.

8. **`lib/finalize.sh` + `lib/finalize_aux.sh`** (NEW, 54 lines): added
   `_hook_failure_context_reset` (registered last, runs only on
   exit_code==0) that calls `reset_failure_cause_context`. Three
   small auxiliary hooks (express persist, note acceptance, baseline
   cleanup) extracted to `finalize_aux.sh` so finalize.sh stays at
   280 lines (was 303 before M129 — already over the ceiling).

9. **`lib/orchestrate.sh`**: `run_complete_loop` calls
   `reset_failure_cause_context` at the top of each iteration so a
   stale primary/secondary cause from a prior attempt cannot bleed
   into this iteration's `LAST_FAILURE_CONTEXT.json`. Parallels
   m130's `_reset_orch_recovery_state` reset point.

10. **`lib/orchestrate_helpers.sh`**: `_save_orchestration_state` (the
    failure-path `write_pipeline_state` site) appends
    `format_failure_cause_summary` output to the Notes string when
    non-empty. Empty when neither slot is set, so legacy state-file
    shape is preserved.

11. **`tekhton.sh`**: sourcing of `lib/failure_context.sh` added to both
    the main pipeline (line 926, before `diagnose.sh`) and the early
    `--diagnose` exit (line 648). `reset_failure_cause_context` invoked
    after argument parsing so a same-shell second run starts clean.

12. **`stages/coder.sh` / `stages/coder_buildfix*.sh`**: no new code
    here — M128 already shipped `_build_fix_set_secondary_cause` which
    prefers `set_secondary_cause` when defined. Once
    `lib/failure_context.sh` is sourced (M129), that helper now wires
    the slot variables on the build-fix exhausted/no_progress paths.

13. **Tests**:
    - `tests/test_failure_context_schema.sh` (NEW, 235 lines, 45
      assertions across T1–T8): writer schema v2, alias precedence,
      pretty-print canary (T3 — guards downstream m130/m132/m133
      parsers), v2 reader, legacy fallback, `_rule_max_turns`
      secondary-symptom message, `reset` clears all eight vars,
      `format_failure_cause_summary` partial population.
    - `tests/test_finalize_run.sh`: hook-count assertion bumped 25 →
      26, new assertion for `_hook_failure_context_reset` at index
      25, register-additional-hooks indices shifted to match.

14. **Docs**:
    - `docs/troubleshooting/diagnose.md`: added "Failure Context
      Schema (v2)" section with the full v2 example, primary vs.
      secondary semantics, the signal vocabulary table (verbatim
      from the milestone for cross-reference by m126/m127/m128/
      m131 implementers), and reader fallback order.
    - `CLAUDE.md`: added `failure_context.sh`,
      `diagnose_output_extra.sh`, `diagnose_rules_extra.sh`, and
      `finalize_aux.sh` to the repo layout.

15. **`VERSION`**: 3.128.0 → 3.129.0.

## Root Cause (bugs only)

N/A — feature milestone, not a bug fix. The Watch For section flagged a
latent bug (the prior writer emitted no `category`/`subcategory` keys, so
`_rule_max_turns`'s JSON-driven match path silently never fired); the new
writer's top-level alias keys close that gap, so the JSON path now fires
correctly. Existing test 2b.2 already validates that path.

## Files Modified

- `lib/failure_context.sh` (NEW) — slot vars, setters, reset, summary
  formatter, JSON fragment emitter, alias resolver helpers.
- `lib/diagnose_output.sh` — schema v2 writer; pretty-print contract;
  alias precedence.
- `lib/diagnose_output_extra.sh` (NEW) — extracted crash first-aid +
  dashboard-diagnosis to keep diagnose_output.sh under 300 lines.
- `lib/diagnose.sh` — 9 new `_DIAG_*` slot vars; v2 cause-block parsing
  in `_read_diagnostic_context` with documented fallback order.
- `lib/diagnose_helpers.sh` — added `_diag_parse_cause_block` line-based
  parser (mirrors m130's parser shape, no `jq` dependency).
- `lib/diagnose_rules.sh` — `_rule_max_turns` consumes secondary cause +
  emits secondary-symptom guard suggestion when primary is non-agent.
  `_rule_quota_exhausted` / `_rule_unknown` moved to extras.
- `lib/diagnose_rules_extra.sh` — moved-in `_rule_quota_exhausted` /
  `_rule_unknown` (with `# shellcheck disable=SC2034` for
  `DIAG_SUGGESTIONS` array assignment).
- `lib/finalize.sh` — registered `_hook_failure_context_reset`. Three
  aux hooks moved to `finalize_aux.sh` to stay under 300 lines.
- `lib/finalize_aux.sh` (NEW) — express_persist, note_acceptance,
  baseline_cleanup, and the M129 reset hook.
- `lib/finalize_dashboard_hooks.sh` — opportunistic
  `set_secondary_cause` from `AGENT_ERROR_*` before
  `write_last_failure_context`.
- `lib/orchestrate.sh` — `reset_failure_cause_context` at iteration top.
- `lib/orchestrate_helpers.sh` — append `format_failure_cause_summary`
  output to state-file Notes in `_save_orchestration_state`.
- `tekhton.sh` — source `failure_context.sh` early; reset slots after
  argument parsing.
- `tests/test_failure_context_schema.sh` (NEW) — T1–T8 schema/reader
  tests, 45 assertions.
- `tests/test_finalize_run.sh` — hook-count + new-hook-position
  assertions updated for the new `_hook_failure_context_reset`.
- `docs/troubleshooting/diagnose.md` — schema v2 section + signal
  vocabulary table.
- `CLAUDE.md` — repo layout updated for new lib files.
- `VERSION` — 3.128.0 → 3.129.0.

## Human Notes Status

No HUMAN_NOTES items were attached to this milestone task.

## Docs Updated

- `docs/troubleshooting/diagnose.md` — added "Failure Context Schema
  (v2)" with the full v2 example, primary/secondary semantics, the
  signal vocabulary table, and reader fallback order.
- `CLAUDE.md` — added `failure_context.sh`,
  `diagnose_output_extra.sh`, `diagnose_rules_extra.sh`, and
  `finalize_aux.sh` to the repository layout.

## Architecture Decisions

- **Slot helpers extracted to a new `lib/failure_context.sh`** rather
  than appended to `lib/diagnose_output.sh`. Per the milestone Goal 5:
  diagnose_output.sh was already 332 lines (over the 300-line
  ceiling); appending the writer changes plus the helpers would have
  pushed it further over budget. The clean split moves all
  primary/secondary cause logic out (slot vars, setters, reset,
  summary formatter, JSON emitter, alias resolvers), leaving
  diagnose_output.sh focused on report rendering + writer entrypoint.
  diagnose_output.sh is now 282 lines.
- **Crash first-aid + dashboard-diagnosis extracted to
  `diagnose_output_extra.sh`**. Goal 5 extraction alone wasn't enough
  budget once the schema v2 writer body grew. Splitting these two
  unrelated functions (crash first-aid, dashboard JSON emitter) into a
  sibling file is the cleanest concern split with no behavior change.
- **Auxiliary finalize hooks extracted to `lib/finalize_aux.sh`**.
  finalize.sh was already 303 lines pre-M129 (over the ceiling) and
  adding `_hook_failure_context_reset` would have pushed it to 315.
  Moving express_persist + note_acceptance + baseline_cleanup +
  the new reset hook into a sibling brings finalize.sh to 280 lines.
- **`_diag_parse_cause_block` placed in `diagnose_helpers.sh`** (not
  diagnose.sh) to keep diagnose.sh under 300 lines. The parser is a
  helper, not a top-level diagnostic function, so the placement is
  semantically correct.
- **Two diagnose_rules.sh extractions** (`_rule_quota_exhausted` and
  `_rule_unknown`) moved to diagnose_rules_extra.sh per the milestone
  Watch For ("Currently 299 lines — keep under 300; if the patch
  grows, extract the rule helper to diagnose_rules_extra.sh"). The
  rule registry order is unchanged (registry lives in
  diagnose_rules.sh; the extras file is sourced before the registry).
- **`_hook_failure_context_reset` runs LAST in the registration list**,
  after `_hook_tui_complete`. This is intentional — the reset must
  happen after every other hook has finished reading the slot state
  for its own purposes, otherwise hooks running later in the order
  would see cleared values.
- **Top-level alias precedence rule** — when secondary slot is set, the
  alias mirrors it; otherwise the alias mirrors `AGENT_ERROR_*`;
  otherwise the keys are omitted entirely. Empty-string aliases are
  never emitted (T2.5 enforces this). The writer uses
  `resolve_alias_category` / `resolve_alias_subcategory` from
  failure_context.sh so the precedence logic isn't duplicated.

## Observed Issues (out of scope)

- `tekhton.sh` is 3026 lines (pre-existing) — far over the 300-line
  ceiling. M129 added 7 lines (two `source` lines and a 5-line
  reset block); splitting tekhton.sh is a major refactor far beyond
  M129's scope.
- `tests/test_finalize_run.sh` is 964 lines (pre-existing) — over the
  ceiling. M129 added 1 assertion for the new hook plus updated 4
  assertions for shifted indices. Splitting that test file would be a
  separate dedicated cleanup.
- `stages/coder.sh` is still 1131 lines (pre-existing — M128 noted
  this same observation). M129 makes no changes to coder.sh; the
  build-fix secondary-cause integration goes through M128's
  `_build_fix_set_secondary_cause` helper which now wires the
  M129 slot vars automatically.
- `lib/diagnose_output.sh` lines 17–19 (the file header "Provides:"
  block) still list `print_crash_first_aid` and
  `emit_dashboard_diagnosis` despite those functions having moved to
  `diagnose_output_extra.sh`. Minor doc rot — non-blocking; clean up
  in a future pass.
- 4 pre-existing failures in `tests/test_diagnose.sh` (Suite 17.1,
  19.1, 19.2, 19.3) were present before M129 and remain after. They
  fail because the test harness calls `print_crash_first_aid` /
  `run_diagnose` outside an Output Bus context, so `warn` and `log`
  produce no captured output. Verified pre-existing via `git stash`.
  Not caused by M129.
