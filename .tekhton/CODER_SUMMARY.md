# Coder Summary — M130 Causal-Context-Aware Recovery Routing

## Status: COMPLETE

## What Was Implemented

All six milestone goals plus mandatory extras:

1. **Goal 1 — Failure-context loader** (`lib/orchestrate_recovery_causal.sh`):
   `_load_failure_cause_context` reads `LAST_FAILURE_CONTEXT.json` (v1 or v2),
   populates `_ORCH_PRIMARY_*` / `_ORCH_SECONDARY_*` vars, and degrades
   gracefully when the file is absent or v1 (legacy fallback). Honors
   `ORCH_CONTEXT_FILE_OVERRIDE` for tests. Uses a bash-only line-state-machine
   parser keyed on the M129 pretty-print contract — no `jq` dependency.

2. **Goal 2 — Amendments A-D in `_classify_failure`**:
   - Amendment D: `_load_failure_cause_context` is the first call in the function.
   - Amendment A: `ENVIRONMENT/test_infra` primary cause routes `retry_ui_gate_env`.
   - Amendment B: `AGENT_SCOPE/max_turns` with env primary routes `retry_ui_gate_env`
     instead of `split` (env can't be fixed by giving more turns).
   - Amendment C: build-gate routing now consults `LAST_BUILD_CLASSIFICATION`
     (M127) — `code_dominant`/`unknown_only` → retry, `mixed_uncertain` → retry once
     then save_exit, `noncode_dominant` → save_exit. Kill-switch
     `BUILD_FIX_CLASSIFICATION_REQUIRED=false` reverts to pre-M130 behavior.
   - Both env-retry guards (`_ORCH_ENV_GATE_RETRIED`) and the explicit
     `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0` opt-out are honored.

3. **Goal 3 — `retry_ui_gate_env` dispatcher branch** (`stages_loop.sh`):
   Inserted in `_handle_pipeline_failure` immediately above `retry_coder_build`.
   Sets `_ORCH_ENV_GATE_RETRIED=1`, exports `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1`,
   resets `START_AT="coder"`, and re-loops. Does NOT call any gate function inline.

4. **Goal 4 — `_print_recovery_block` 5th-arg `cause_summary`**
   (`lib/orchestrate_recovery_print.sh`): optional plain-text root-cause line
   inserted into the WHAT HAPPENED block. Existing 4-arg call sites unaffected.
   The cause_summary is assembled in `_save_orchestration_state` from the
   primary/secondary cause vars.

5. **Goal 5 — Module-level state + reset**: declared in
   `orchestrate_recovery_causal.sh`. Lifetime A vars (cause vars) reset by the
   loader on every call. Lifetime B vars (retry guards + route slot) reset
   once at the top of `run_complete_loop` via `_reset_orch_recovery_state`,
   never per-iteration.

6. **Goal 6 — Tests** (`tests/test_orchestrate_recovery.sh`): T1-T11 plus
   T2b (opt-out), T8b (unknown_only), T8c (kill-switch). All 25 assertions pass.

### Mandatory extras
- **Priority 0 hook** added at `lib/gates_ui_helpers.sh:_ui_detect_framework`:
  `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1` short-circuits to `playwright`,
  forcing the hardened env profile on the retry's gate run.
- **`docs/troubleshooting/recovery-routing.md`** documents the routing table,
  retry-once guards, and configuration knobs.

### File-size ceiling
Three extractions were necessary to keep all `.sh` files under 300 lines:
- `lib/orchestrate_recovery_causal.sh` (M130 state + loader)
- `lib/orchestrate_recovery_print.sh` (M94/M130 recovery-block printer)
- `lib/orchestrate_state_save.sh` (`_save_orchestration_state` + glue)

Final sizes (all under 300):
```
278 lib/orchestrate.sh
234 lib/orchestrate_helpers.sh
281 lib/orchestrate_loop.sh
244 lib/orchestrate_recovery.sh
158 lib/orchestrate_recovery_causal.sh
 80 lib/orchestrate_recovery_print.sh
 96 lib/orchestrate_state_save.sh
```

## Root Cause (bugs only)
Not a bug — feature work per milestone spec.

## Architecture Change Proposals

### Subshell-state-mutation correction in `_classify_failure`

- **Current constraint**: The M130 milestone spec instructs `_classify_failure`
  to mutate persistent retry guards (`_ORCH_ENV_GATE_RETRIED`,
  `_ORCH_MIXED_BUILD_RETRIED`) and the `_ORCH_RECOVERY_ROUTE_TAKEN` slot
  directly inside the function body.
- **What triggered this**: `_classify_failure` is invoked by the dispatcher as
  `recovery=$(_classify_failure)` (`lib/orchestrate_loop.sh:199`). Command
  substitution forks a subshell, so any state mutations inside the function
  vanish when it returns. The spec's intended retry-once semantics would
  silently break: a second iteration's call would see the guard reset to 0
  and infinite-loop on `retry_ui_gate_env`.
- **Proposed change**: `_classify_failure` is read-only. The dispatcher
  (`_handle_pipeline_failure`, parent shell) writes the guards in its case
  branches — same pattern already used by `_ORCH_BUILD_RETRIED`. The
  `LAST_BUILD_CLASSIFICATION` is also read in the dispatcher's
  `retry_coder_build` branch to set `_ORCH_MIXED_BUILD_RETRIED` when the
  classification is `mixed_uncertain`.
- **Backward compatible**: Yes — call signature and return values unchanged.
  The published action vocabulary (`retry_coder_build`, `retry_ui_gate_env`,
  `bump_review`, `split`, `save_exit`) is preserved exactly so M132/M133
  consumers see no change.
- **ARCHITECTURE.md update needed**: No — neither
  `_classify_failure` nor `_handle_pipeline_failure` was previously
  documented in ARCHITECTURE.md.

## Files Modified

| File | Change |
|------|--------|
| `lib/orchestrate_recovery.sh` | Source new helpers; apply Amendments A-D to `_classify_failure`; remove `_print_recovery_block` (extracted) |
| `lib/orchestrate_recovery_causal.sh` (NEW) | Module state, `_load_failure_cause_context`, `_reset_orch_recovery_state`, `_causal_env_retry_allowed` |
| `lib/orchestrate_recovery_print.sh` (NEW) | Extracted `_print_recovery_block` with optional 5th `cause_summary` arg |
| `lib/orchestrate_state_save.sh` (NEW) | Extracted `_save_orchestration_state`; assembles cause_summary from cause vars and passes to `_print_recovery_block` |
| `lib/orchestrate_helpers.sh` | Source `orchestrate_state_save.sh` |
| `lib/orchestrate_loop.sh` | Add `retry_ui_gate_env` case branch; write retry guards + `_ORCH_RECOVERY_ROUTE_TAKEN` in case branches (parent shell) |
| `lib/orchestrate.sh` | Call `_reset_orch_recovery_state` once at the top of `run_complete_loop` |
| `lib/gates_ui_helpers.sh` | Priority 0 hook in `_ui_detect_framework` for `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1` |
| `tests/test_orchestrate_recovery.sh` (NEW) | T1-T11 plus T2b/T8b/T8c — 25 assertions, all pass |
| `docs/troubleshooting/recovery-routing.md` (NEW) | Routing-table and retry-guard documentation |
| `CLAUDE.md` | Add new lib files to repository layout listing |

## Docs Updated
- `docs/troubleshooting/recovery-routing.md` (NEW) — public surface: documents
  `BUILD_FIX_CLASSIFICATION_REQUIRED` and `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE`
  configuration knobs introduced/extended by M130, plus the new
  `retry_ui_gate_env` recovery action.
- `CLAUDE.md` — repository-layout listing updated to include the three new
  `lib/orchestrate_*` files. Template Variables section updated (lines 474–475)
  to document `BUILD_FIX_CLASSIFICATION_REQUIRED` and `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE`
  configuration variables.

## Human Notes Status
None — milestone-driven work, no human notes specified.

## Verification
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` → clean.
- `bash tests/test_orchestrate_recovery.sh` → 25/25 pass.
- `bash tests/run_tests.sh` → 460/460 shell tests pass, 247 Python tests pass.
- Self-check: every `lib/` file modified or created is under 300 lines
  (verified via `wc -l`). No stale references to renamed functions or
  removed code paths in comments/messages.
