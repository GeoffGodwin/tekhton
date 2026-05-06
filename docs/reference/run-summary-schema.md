# RUN_SUMMARY.json Schema Reference

Tekhton emits `RUN_SUMMARY.json` to `${LOG_DIR}` (default
`.claude/logs/`) on every pipeline run — both success and failure paths.
A timestamped copy `RUN_SUMMARY_<TIMESTAMP>.json` is also written so the
historical record is preserved after the next run overwrites the live file.

This reference documents the four enrichment fields added by Milestone 132
plus the related changes to `error_classes_encountered` and
`recovery_actions_taken`. For the full set of base fields see
`lib/finalize_summary.sh`.

## Top-level enrichment fields (added by M132)

All four fields are emitted on **every** run. Their empty-state variants
keep the JSON shape stable across success and failure outcomes.

### `causal_context`

Causal classification of the run's failure (when one occurred), sourced
from `LAST_FAILURE_CONTEXT.json` written by the diagnose engine.

| Field | Type | Description |
|-------|------|-------------|
| `schema_version` | int | `0` when no failure context exists. `1` for legacy single-cause records. `2` for primary/secondary cause records. |
| `primary_category` | string | Top-level cause category. Empty on schema 0/1. Examples: `ENVIRONMENT`, `AGENT_SCOPE`, `PIPELINE`, `UPSTREAM`. |
| `primary_subcategory` | string | Refinement under category. Examples: `test_infra`, `max_turns`, `null_run`. |
| `primary_signal` | string | Specific failure signal. Example: `ui_timeout_interactive_report`. |
| `secondary_category` | string | Companion cause when one is identified (e.g. the symptom when primary is the root). |
| `secondary_subcategory` | string | (same as above) |
| `secondary_signal` | string | (same as above) |

**Empty-state on success runs:** `{"schema_version":0}` — all other keys
omitted. Dashboard parsers branch on `schema_version == 0` to render
"no causal data available" rather than empty strings.

### `build_fix_stats`

Build-fix continuation loop statistics from `stages/coder_buildfix.sh`.

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | `false` when no build-fix attempts ran (success runs, pre-M128 deployments). |
| `attempts` | int | Number of build-fix attempts executed in the run. |
| `max_attempts` | int | The configured `BUILD_FIX_MAX_ATTEMPTS` cap. |
| `outcome` | string | One of `passed`, `exhausted`, `no_progress`, `not_run`. Vocabulary frozen by M128. |
| `turn_budget_used` | int | Total turns consumed across all attempts. |
| `progress_gate_failures` | int | Count of attempts (≥2) where the progress gate flagged `unchanged` or `worsened`. |

**Empty-state on success runs:** `{"enabled":false,"attempts":0,"max_attempts":3,"outcome":"not_run","turn_budget_used":0,"progress_gate_failures":0}`.

### `recovery_routing`

Final recovery decision returned by `_classify_failure` plus the
persistent retry guards in `lib/orchestrate_cause.sh`.

| Field | Type | Description |
|-------|------|-------------|
| `route_taken` | string | The action returned by `_classify_failure` for this run. Common values: `save_exit` (default — no recovery action chosen), `bump_review`, `retry_ui_gate_env`, `retry_coder_build`, `split`, `split_escalated`. |
| `env_gate_retried` | bool | True iff the M130 UI-gate hardened-env retry fired this run. |
| `mixed_build_retried` | bool | True iff the M130 mixed-uncertain build retry fired this run. |
| `causal_schema_version` | int | The schema version of `LAST_FAILURE_CONTEXT.json` at finalize time (mirrors `causal_context.schema_version`; convenient for downstream filters). |

**Empty-state on success runs:** `{"route_taken":"save_exit","env_gate_retried":false,"mixed_build_retried":false,"causal_schema_version":0}`.

### `preflight_ui`

UI test framework configuration audit findings from M131's preflight
scanner (`lib/preflight_checks_ui.sh`).

| Field | Type | Description |
|-------|------|-------------|
| `interactive_config_detected` | bool | True iff a preflight rule (e.g. PW-1, JV-1) flagged an interactive-mode config. |
| `interactive_config_rule` | string | The rule id that matched. Empty when no detection. |
| `interactive_config_file` | string | Basename of the matched config file (e.g. `playwright.config.ts`). |
| `reporter_auto_patched` | bool | True iff M131's PW-1 auto-fix successfully rewrote the reporter line. |
| `fail_count` | int | Aggregated preflight `fail`-class finding count for this run. |
| `warn_count` | int | Aggregated preflight `warn`-class finding count for this run. |

**Empty-state on success runs (no preflight UI findings):**
`{"interactive_config_detected":false,"interactive_config_rule":"","interactive_config_file":"","reporter_auto_patched":false,"fail_count":0,"warn_count":0}`.

## Updated existing fields

### `error_classes_encountered`

A 1-or-2-element JSON array.

- **Element 0** — surface symptom from `AGENT_ERROR_CATEGORY` /
  `AGENT_ERROR_SUBCATEGORY`. Example: `"AGENT_SCOPE/max_turns"`.
- **Element 1** (when present) — root cause from M130's primary cause,
  prefixed with `root:` to discriminate from the symptom. Example:
  `"root:ENVIRONMENT/test_infra"`.

The `root:` prefix is the discriminator — never assume index 1 is always
the root. The second element is omitted when the primary cause equals
the symptom (no information added).

### `recovery_actions_taken`

JSON array of strings recording in-run recovery events. M132 appends the
M130 recovery route when it is non-default (i.e. when something other than
`save_exit` fired). Example sequence:
`["transient_retry", "retry_ui_gate_env"]`.

The route is intentionally also published in
`recovery_routing.route_taken` — the array gives chronological history,
the top-level field gives the final routing decision in a single read.

## Backward compatibility

The M132 changes are strictly additive:

- New top-level keys (`causal_context`, `build_fix_stats`,
  `recovery_routing`, `preflight_ui`) are always present after M132 lands.
  Existing consumers that read keys by name ignore them.
- `error_classes_encountered` may now have two elements instead of one;
  consumers that read element 0 are unaffected.
- `recovery_actions_taken` may now contain an additional route entry;
  consumers that iterate the array are unaffected.

External dashboards consuming the file should treat unknown top-level
keys as ignorable. Removing or renaming keys is a breaking change and is
not done in M132.
