# Recovery Routing (`--complete` mode)

When `--complete` mode hits a pipeline failure, the orchestrator classifies the
failure and picks one of a small set of recovery actions. M130 added
**causal-context-aware** routing on top of the existing decision tree: instead
of branching on flat `AGENT_ERROR_CATEGORY` / `AGENT_ERROR_SUBCATEGORY` alone,
the router consults the v2 `LAST_FAILURE_CONTEXT.json` schema (M129) for
`primary_cause` and `secondary_cause` objects, and the M127 build-error
classification token `LAST_BUILD_CLASSIFICATION` for build-gate failures.

## Recovery actions

| Action | When | What it does |
|--------|------|--------------|
| `retry_coder_build` | Build gate failed; classification is `code_dominant` (or `unknown_only`, or absent) | Re-run from the coder stage with `BUILD_ERRORS.md` injected. One-shot — second `retry_coder_build` in the same `--complete` invocation routes to `save_exit` via `_ORCH_BUILD_RETRIED`. |
| `retry_ui_gate_env` (M130) | Primary cause is `ENVIRONMENT/test_infra` (e.g. UI gate detected the Playwright HTML report serving) and the env-gate retry guard has not fired | Export `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1`, re-run from coder stage. M126's `_ui_detect_framework` Priority 0 hook forces the hardened env profile (`PLAYWRIGHT_HTML_OPEN=never`, `CI=1`) on the next gate run. One-shot — `_ORCH_ENV_GATE_RETRIED` prevents loops. |
| `bump_review` | Reviewer hit cycle max and is asking for more rework | Bump `MAX_REVIEW_CYCLES` by 2 (one-time), restart from review stage. |
| `split` | `AGENT_SCOPE/max_turns` or `AGENT_SCOPE/null_run` | Hand off to milestone splitter. May escalate turn budget instead (M91) before giving up. |
| `save_exit` | Anything non-recoverable: sustained upstream outage, environment errors not covered by the env-gate retry, pipeline internal errors, `REPLAN_REQUIRED`, or any retry guard exhausted | Write `PIPELINE_STATE.md`, print the recovery block, exit. |

## Decision tree (M130)

The router consults `LAST_FAILURE_CONTEXT.json` first via `_load_failure_cause_context`
(reads schema v1 or v2) and then walks the decision tree:

1. **UPSTREAM** error → `save_exit` (already retried by M13)
2. **AGENT_SCOPE/max_turns + primary cause is ENVIRONMENT/test_infra** → `retry_ui_gate_env`
   (Amendment B — splitting can't fix an env issue)
3. **AGENT_SCOPE/max_turns** (without env primary) → `split`
4. **AGENT_SCOPE/null_run** → `split`
5. **AGENT_SCOPE/activity_timeout** → `save_exit`
6. **Primary cause ENVIRONMENT/test_infra** (regardless of error_cat) → `retry_ui_gate_env`
   (Amendment A — recoverable by re-running the gate with the deterministic profile)
7. **ENVIRONMENT** error (no env-recoverable primary, or guard already fired) → `save_exit`
8. **PIPELINE** internal → `save_exit`
9. **VERDICT CHANGES_REQUIRED / review_cycle_max** → `bump_review`
10. **VERDICT REPLAN_REQUIRED** → `save_exit`
11. **Build gate failure** (`BUILD_ERRORS_FILE` non-empty, M130 Amendment C):
    - `BUILD_FIX_CLASSIFICATION_REQUIRED=false` (kill-switch) → `retry_coder_build`
      (pre-M130 behavior)
    - `LAST_BUILD_CLASSIFICATION=code_dominant` or `unknown_only` (or empty) → `retry_coder_build`
    - `LAST_BUILD_CLASSIFICATION=mixed_uncertain` (first attempt) → `retry_coder_build`;
      second attempt → `save_exit`
    - `LAST_BUILD_CLASSIFICATION=noncode_dominant` → `save_exit`
12. Anything else → `save_exit`

## Retry guards (one-shot semantics)

Retry guards prevent infinite loops. They are persistent **across iterations
within a single `run_complete_loop` call** and reset once at the top via
`_reset_orch_recovery_state`. They are **not** reset per-iteration — that
would defeat the retry-once semantic.

| Guard | Set by | Read by | Purpose |
|-------|--------|---------|---------|
| `_ORCH_BUILD_RETRIED` | `_handle_pipeline_failure` `retry_coder_build` branch | Same branch | Pre-M130 build-fix one-shot |
| `_ORCH_ENV_GATE_RETRIED` (M130) | `_handle_pipeline_failure` `retry_ui_gate_env` branch | `_classify_failure` Amendments A/B | Env-gate retry one-shot |
| `_ORCH_MIXED_BUILD_RETRIED` (M130) | `_handle_pipeline_failure` `retry_coder_build` branch (when classification is mixed) | `_classify_failure` Amendment C | Mixed-uncertain retry one-shot |
| `_ORCH_REVIEW_BUMPED` | `_handle_pipeline_failure` `bump_review` branch | Same branch | Reviewer cycle-max bump one-shot |

`_classify_failure` runs in a `recovery=$(_classify_failure)` subshell, so it
**cannot** mutate these guards itself — the dispatcher (parent shell) writes
them in the case branches.

## Configuration knobs

- `BUILD_FIX_CLASSIFICATION_REQUIRED` (default `true`)
  — Set to `false` in `pipeline.conf` to revert Amendment C to pre-M130
  behavior (always `retry_coder_build` on non-empty `BUILD_ERRORS_FILE`).
- `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE`
  — Implicitly `1` after M130 routes `retry_ui_gate_env` (set by the dispatcher
  before the next iteration). Setting this to `0` explicitly in `pipeline.conf`
  opts out of the env-gate retry entirely; Amendments A and B will then fall
  through to `save_exit` instead of scheduling the retry.

## Observability

- `_ORCH_RECOVERY_ROUTE_TAKEN` captures the action chosen on the most recent
  failure dispatch. M132 emits this into `RUN_SUMMARY.json`.
- The terminal recovery block (printed on save+exit) shows a `Root cause: ...`
  line when primary/secondary cause data is available, derived from the same
  v2 schema fields.

## See also

- `lib/orchestrate_classify.sh` — `_classify_failure` decision tree
- `lib/orchestrate_cause.sh` — failure-context loader + state vars
- `lib/orchestrate_iteration.sh:_handle_pipeline_failure` — dispatcher case branches
- `lib/failure_context.sh` — primary/secondary cause slot helpers (M129)
- `lib/error_patterns_classify.sh` — `LAST_BUILD_CLASSIFICATION` producer (M127)
