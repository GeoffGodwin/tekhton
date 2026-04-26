# M132 - RUN_SUMMARY Causal Fidelity Enrichment

<!-- milestone-meta
id: "132"
status: "pending"
-->

## Overview

The m126–m131 arc generates substantially richer failure intelligence at
runtime:

| Milestone | Runtime signal produced |
|-----------|------------------------|
| m128 | `BUILD_FIX_ATTEMPTS`, `BUILD_FIX_OUTCOME`, `BUILD_FIX_REPORT.md` |
| m129 | `LAST_FAILURE_CONTEXT.json` schema v2 with `primary_cause` / `secondary_cause` objects |
| m130 | `_ORCH_RECOVERY_ROUTE_TAKEN`, `_ORCH_ENV_GATE_RETRIED`, `_ORCH_MIXED_BUILD_RETRIED` |
| m131 | `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED`, `PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE`, preflight fail/warn counts |

None of this reaches `RUN_SUMMARY.json`. The current writer in
`lib/finalize_summary.sh` emits a flat
`"error_classes_encountered": ["AGENT_SCOPE/max_turns"]` and a boolean
`recovery_actions_taken` list. Watchtower, the historical dashboard, and
any external tooling consuming the summary log see only the symptom, not
the root cause.

Two concrete failure modes that result:

1. **Dashboard shows "AGENT_SCOPE/max_turns" for every UI-gate-triggered
   failure** even after m129 has correctly tagged it as
   `ENVIRONMENT/test_infra (primary)`. The accuracy metric for the error
   classification system looks worse than it actually is.

2. **Build-fix loop statistics are lost.** Whether the pipeline burned
   3 build-fix attempts or 0 before exiting is invisible in the
   historical record. The only way to know is to open the raw log.

M132 adds four new top-level fields to `RUN_SUMMARY.json` on failure
runs, enriches the existing `error_classes_encountered` and
`recovery_actions_taken` fields, and updates the Watchtower dashboard
parser to surface the new data in the run detail view.

## Where the relevant code lives (verified at write time)

- `_hook_emit_run_summary` lives in `lib/finalize_summary.sh` (currently
  **282 lines**). The single multi-field `printf` that writes
  `RUN_SUMMARY.json` is at line 240; the format string is one logical
  line. New fields are inserted between `"remediations"` and
  `"timestamp"`. **Adding ~80–100 LOC of helpers will push the file
  over the 300-line CLAUDE.md ceiling — plan helper extraction to a
  sibling file from the start (see "Files Modified").**
- The summary file path is `${LOG_DIR:-${PROJECT_DIR}/.claude/logs}/RUN_SUMMARY.json`
  (`lib/finalize_summary.sh:21-23`) — **`.claude/logs/`, not `.claude/`**.
  Helpers do not need to know this; they return JSON fragments that the
  writer composes.
- `LAST_FAILURE_CONTEXT.json` is at `${PROJECT_DIR}/.claude/LAST_FAILURE_CONTEXT.json`,
  written by `write_last_failure_context` (`lib/diagnose_output.sh:209`).
  m132 helpers read from the same path.
- `_classify_failure` lives in `lib/orchestrate_recovery.sh:114`. Its
  single call site is `_handle_pipeline_failure` in
  `lib/orchestrate_loop.sh:199` — **not** `run_complete_loop` in
  `lib/orchestrate.sh`. The `_ORCH_RECOVERY_ROUTE_TAKEN` capture wrap
  (Goal 8) goes in `orchestrate_loop.sh` around the existing
  `recovery=$(_classify_failure)` line.
- `_ORCH_RECOVERY_ROUTE_TAKEN` is **declared by m130** (m130 Goal 5,
  alongside `_ORCH_ENV_GATE_RETRIED` etc.) and reset by
  `_reset_orch_recovery_state`. m130 sets it on the `retry_ui_gate_env)`
  branch only. m130 is a hard dependency in MANIFEST.cfg, so the
  declaration is in place when m132 lands; **do not re-declare** —
  m132's contribution is to capture the value for *every* recovery
  route, not only `retry_ui_gate_env` (see Goal 8).
- `_load_failure_cause_context` is added by m130 (also a hard
  dependency). It populates `_ORCH_PRIMARY_CAT/SUB/SIGNAL` and
  `_ORCH_SECONDARY_CAT/SUB/SIGNAL` from `LAST_FAILURE_CONTEXT.json`
  using a line-state-machine parser. m132's `_collect_causal_context_json`
  should **call this loader and read the `_ORCH_*` vars** rather than
  re-implementing the parser — collapses the helper to ~15 lines and
  enforces m129's pretty-print contract in one place. (See
  "Implementation Notes" for the fallback if m130 has not yet shipped.)
- The dashboard parser is `lib/dashboard_parsers_runs_files.sh`
  (currently **92 lines**). The canonical path uses
  `python3 -c 'import json; ...'`; the fallback uses `sed -n` with
  bracket-expression patterns. **Neither uses `grep -oP`** — the
  pseudocode in Goal 9 must be adapted to the existing style (extend
  the python `print(json.dumps({...}))` dictionary; add matching
  `sed -n` fallbacks).
- No `_build_run_badge*` function exists anywhere in `lib/` or
  `tools/`. The badge rendering work in Goal 9 is therefore
  scope-bounded — the parser changes are required; the renderer hooks
  are best-effort and may be deferred to a follow-up Watchtower polish
  milestone.

## Design

### Goal 1 — Collect causal context at finalize time

Add a new helper in `lib/finalize_summary.sh` that reads
`LAST_FAILURE_CONTEXT.json` (schema v1 or v2) and returns a populated
JSON fragment:

```bash
# _collect_causal_context_json
# Returns a JSON object for embedding in RUN_SUMMARY.json.
# Reads LAST_FAILURE_CONTEXT.json if present; returns null object on absence.
#
# Output shape (schema_version=2):
# {
#   "schema_version": 2,
#   "primary_category": "ENVIRONMENT",
#   "primary_subcategory": "test_infra",
#   "primary_signal": "ui_timeout_interactive_report",
#   "secondary_category": "AGENT_SCOPE",
#   "secondary_subcategory": "max_turns",
#   "secondary_signal": "build_fix_budget_exhausted"
# }
#
# Output shape (schema_version=1 or absent):
# {
#   "schema_version": 1,
#   "primary_category": "",
#   "primary_subcategory": "",
#   "primary_signal": "",
#   "secondary_category": "ENVIRONMENT",
#   "secondary_subcategory": "test_infra",
#   "secondary_signal": ""
# }
#
# When file absent:
# {"schema_version": 0}
_collect_causal_context_json() { ... }
```

**Preferred implementation: reuse m130's loader.** m130 (a hard
dependency) defines `_load_failure_cause_context` in
`lib/orchestrate_recovery.sh`, which already populates the cause vars
from `LAST_FAILURE_CONTEXT.json` using a line-state-machine parser.
`_collect_causal_context_json` should call it and read the `_ORCH_*`
vars rather than duplicate the parser:

```bash
_collect_causal_context_json() {
    local ctx_file="${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json"
    if [[ ! -f "$ctx_file" ]]; then
        printf '{"schema_version":0}'
        return
    fi
    # Refresh from disk via m130's loader (idempotent — re-reads the file)
    _load_failure_cause_context
    printf '{"schema_version":%d,"primary_category":"%s","primary_subcategory":"%s","primary_signal":"%s","secondary_category":"%s","secondary_subcategory":"%s","secondary_signal":"%s"}' \
        "${_ORCH_SCHEMA_VERSION:-0}" \
        "${_ORCH_PRIMARY_CAT:-}" "${_ORCH_PRIMARY_SUB:-}" "${_ORCH_PRIMARY_SIGNAL:-}" \
        "${_ORCH_SECONDARY_CAT:-}" "${_ORCH_SECONDARY_SUB:-}" "${_ORCH_SECONDARY_SIGNAL:-}"
}
```

This is ~15 lines, leverages a single canonical parser, and inherits
m129's pretty-print contract enforcement automatically.

**Fallback (if m130 has not yet shipped — should not happen given the
MANIFEST.cfg dependency):** duplicate m130's line-state-machine parser
inline. m130's "Implementation Notes" describes the shape; copy
verbatim and consolidate later when m130 lands.

### Goal 2 — Collect build-fix loop stats at finalize time

Add a second helper:

```bash
# _collect_build_fix_stats_json
# Reads exported vars from the m128 build-fix loop and returns a JSON object.
#
# Output:
# {
#   "enabled": true,
#   "attempts": 2,
#   "max_attempts": 3,
#   "outcome": "exhausted",
#   "turn_budget_used": 60,
#   "progress_gate_failures": 1
# }
#
# "outcome" values: "passed" | "exhausted" | "no_progress" | "not_run"
# "not_run" when BUILD_FIX_ATTEMPTS=0 or env var absent.
_collect_build_fix_stats_json() {
    local attempts="${BUILD_FIX_ATTEMPTS:-0}"
    local max_attempts="${BUILD_FIX_MAX_ATTEMPTS:-3}"
    local outcome="${BUILD_FIX_OUTCOME:-not_run}"
    local turn_budget_used="${BUILD_FIX_TURN_BUDGET_USED:-0}"
    local pg_failures="${BUILD_FIX_PROGRESS_GATE_FAILURES:-0}"
    local enabled="true"

    if [[ "$attempts" -eq 0 ]]; then
        outcome="not_run"
        enabled="false"
    fi

    printf '{"enabled":%s,"attempts":%d,"max_attempts":%d,"outcome":"%s","turn_budget_used":%d,"progress_gate_failures":%d}' \
        "$enabled" "$attempts" "$max_attempts" "$outcome" "$turn_budget_used" "$pg_failures"
}
```

The exported vars (`BUILD_FIX_ATTEMPTS`, `BUILD_FIX_OUTCOME`,
`BUILD_FIX_TURN_BUDGET_USED`, `BUILD_FIX_PROGRESS_GATE_FAILURES`) are
populated by the m128 build-fix loop in `stages/coder.sh`. When m128 is
not yet deployed, all four vars are absent; the helper defaults to
`"not_run"` and emits a `"enabled": false` object.

### Goal 3 — Collect recovery routing stats

Add a third helper:

```bash
# _collect_recovery_routing_json
# Reads m130 module-level recovery vars and returns a JSON object.
#
# Output:
# {
#   "route_taken": "retry_ui_gate_env",
#   "env_gate_retried": true,
#   "mixed_build_retried": false,
#   "causal_schema_version": 2
# }
_collect_recovery_routing_json() {
    local route="${_ORCH_RECOVERY_ROUTE_TAKEN:-save_exit}"
    local env_retried="${_ORCH_ENV_GATE_RETRIED:-0}"
    local mixed_retried="${_ORCH_MIXED_BUILD_RETRIED:-0}"
    local schema_ver="${_ORCH_SCHEMA_VERSION:-0}"

    local env_bool="false"
    [[ "$env_retried" -eq 1 ]] && env_bool="true"
    local mixed_bool="false"
    [[ "$mixed_retried" -eq 1 ]] && mixed_bool="true"

    printf '{"route_taken":"%s","env_gate_retried":%s,"mixed_build_retried":%s,"causal_schema_version":%d}' \
        "$route" "$env_bool" "$mixed_bool" "$schema_ver"
}
```

`_ORCH_RECOVERY_ROUTE_TAKEN` is a new module var in
`lib/orchestrate_recovery.sh` (added by this milestone — see Goal 5).
It is set at the point where `_classify_failure` returns its action
string, so the finalize hook captures the final routing decision.

### Goal 4 — Collect preflight UI finding stats

Add a fourth helper:

```bash
# _collect_preflight_ui_json
# Reads m131 env vars and returns a JSON object.
#
# Output:
# {
#   "interactive_config_detected": true,
#   "interactive_config_rule": "PW-1",
#   "interactive_config_file": "playwright.config.ts",
#   "reporter_auto_patched": true,
#   "fail_count": 1,
#   "warn_count": 2
# }
_collect_preflight_ui_json() {
    local detected="${PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED:-0}"
    local rule="${PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE:-}"
    local file="${PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE:-}"
    local patched="${PREFLIGHT_UI_REPORTER_PATCHED:-0}"
    local pf_fail="${_PF_FAIL:-0}"
    local pf_warn="${_PF_WARN:-0}"

    local det_bool="false"
    [[ "$detected" -eq 1 ]] && det_bool="true"
    local pat_bool="false"
    [[ "$patched" -eq 1 ]] && pat_bool="true"

    # Escape rule/file for JSON
    rule=$(printf '%s' "$rule" | sed 's/\\/\\\\/g; s/"/\\"/g')
    file=$(printf '%s' "$file" | sed 's/\\/\\\\/g; s/"/\\"/g')

    printf '{"interactive_config_detected":%s,"interactive_config_rule":"%s","interactive_config_file":"%s","reporter_auto_patched":%s,"fail_count":%d,"warn_count":%d}' \
        "$det_bool" "$rule" "$file" "$pat_bool" "$pf_fail" "$pf_warn"
}
```

### Goal 5 — Enrich `error_classes_encountered` with causal labels

Currently this field is written as:

```bash
if [[ -n "${AGENT_ERROR_CATEGORY:-}" ]]; then
    error_classes="[\"${AGENT_ERROR_CATEGORY}/${AGENT_ERROR_SUBCATEGORY:-unknown}\"]"
fi
```

Replace with a two-element array that includes both the surface symptom
and the primary root cause when available:

```bash
local ec_items=()
# Symptom (always present when classification fired)
if [[ -n "${AGENT_ERROR_CATEGORY:-}" ]]; then
    local symptom_class="${AGENT_ERROR_CATEGORY}/${AGENT_ERROR_SUBCATEGORY:-unknown}"
    ec_items+=("\"${symptom_class}\"")
fi
# Primary cause (from m129/m130 context loader — populate via _load_failure_cause_context)
# _ORCH_PRIMARY_CAT and _ORCH_PRIMARY_SUB are already set if m130 ran.
# If not, refresh them via _load_failure_cause_context. Do not grep for
# "primary_cause" and "category" on the same line — m129's pretty-print
# contract puts them on separate lines.
local _fc_primary_cat="${_ORCH_PRIMARY_CAT:-}"
local _fc_primary_sub="${_ORCH_PRIMARY_SUB:-}"
if [[ -z "$_fc_primary_cat" ]] && declare -F _load_failure_cause_context >/dev/null 2>&1; then
  _load_failure_cause_context
  _fc_primary_cat="${_ORCH_PRIMARY_CAT:-}"
  _fc_primary_sub="${_ORCH_PRIMARY_SUB:-}"
fi
if [[ -n "$_fc_primary_cat" ]] && [[ "${_fc_primary_cat}/${_fc_primary_sub:-unknown}" != "${symptom_class:-}" ]]; then
    ec_items+=("\"root:${_fc_primary_cat}/${_fc_primary_sub:-unknown}\"")
fi
# Assemble
if [[ ${#ec_items[@]} -gt 0 ]]; then
    local joined_ec
    joined_ec=$(printf ',%s' "${ec_items[@]}")
    error_classes="[${joined_ec:1}]"
fi
```

The `root:` prefix on the second element distinguishes root cause from
surface classification and makes dashboard queries unambiguous.

### Goal 6 — Enrich `recovery_actions_taken` with routing detail

The existing `recovery_actions` array appends string labels. Extend it
with the m130 route when non-default:

```bash
# After the existing ra_items build block:
local _route="${_ORCH_RECOVERY_ROUTE_TAKEN:-save_exit}"
if [[ "$_route" != "save_exit" ]] && [[ -n "$_route" ]]; then
    ra_items+=("\"${_route}\"")
fi
```

This means a run where m130 fired `retry_ui_gate_env` will emit:
`"recovery_actions_taken": ["retry_ui_gate_env"]`
instead of the previous `[]`.

### Goal 7 — Add four new top-level fields to the JSON output

In the `printf` call that writes `RUN_SUMMARY.json`, add four new fields
after `"remediations"`:

```
"causal_context": %s,
"build_fix_stats": %s,
"recovery_routing": %s,
"preflight_ui": %s,
```

Collect them before the printf:

```bash
# M132 enrichment fields
local causal_ctx_json
causal_ctx_json=$(_collect_causal_context_json)
local build_fix_json
build_fix_json=$(_collect_build_fix_stats_json)
local recovery_routing_json
recovery_routing_json=$(_collect_recovery_routing_json)
local preflight_ui_json
preflight_ui_json=$(_collect_preflight_ui_json)
```

The `printf` format string gains four additional `%s` slots and four
additional arguments. The fields are always present; on success runs
they emit the zero/null variants of each object (schema_version=0,
attempts=0/not_run, etc.). This keeps the JSON shape stable across run
outcomes.

### Goal 8 — Capture `_ORCH_RECOVERY_ROUTE_TAKEN` for every recovery route

`_ORCH_RECOVERY_ROUTE_TAKEN` is **declared and reset by m130** (m130
Goal 5, alongside the other Lifetime-B retry guards in
`lib/orchestrate_recovery.sh`). m130 also sets it inside the
`retry_ui_gate_env)` case branch in `_handle_pipeline_failure`. m132
must **not re-declare** the var.

m132's contribution is to capture the route for **every** recovery
action (not only `retry_ui_gate_env`) so `_collect_recovery_routing_json`
sees the actual action chosen each run. Since `_classify_failure` uses
`echo`-and-return, the cleanest place to capture is at the call site
in `lib/orchestrate_loop.sh:199`:

```bash
# In _handle_pipeline_failure (lib/orchestrate_loop.sh:187), the existing line is:
recovery=$(_classify_failure)
# Add immediately after:
_ORCH_RECOVERY_ROUTE_TAKEN="$recovery"
```

This single addition captures the route once per failure iteration. The
m130 case-branch assignment for `retry_ui_gate_env` becomes redundant
but is harmless — the wrap above runs first and writes the same value.
Do not remove m130's case-branch assignment in this milestone; it's
m130's contract and may be coordinated separately.

**Coordination if order inverts (should not happen — m130 is a hard
dependency in MANIFEST.cfg):** if m132 lands before m130, also add the
declaration `_ORCH_RECOVERY_ROUTE_TAKEN=""` at module scope of
`lib/orchestrate_recovery.sh` and zero it in `_reset_orch_recovery_state`.
m130 then verifies and proceeds.

### Goal 9 — Update Watchtower dashboard parser for new fields

**This goal has two layers; the data layer is required, the renderer
layer is best-effort.**

**Data layer (required).** `lib/dashboard_parsers_runs_files.sh`
(currently 92 lines) reads `RUN_SUMMARY.json` to populate per-run rows.
The canonical extraction path uses `python3 -c 'import json; ...'` and
the fallback uses `sed -n` — **neither uses `grep -oP`**. Extend the
existing dict comprehension and add matching `sed -n` lines:

```python
# In the python3 -c block (around line 38), extend the print(json.dumps({...})) dict:
'causal_primary_category': d.get('causal_context', {}).get('primary_category', ''),
'causal_primary_subcategory': d.get('causal_context', {}).get('primary_subcategory', ''),
'build_fix_outcome': d.get('build_fix_stats', {}).get('outcome', 'not_run'),
'build_fix_attempts': d.get('build_fix_stats', {}).get('attempts', 0),
'recovery_route': d.get('recovery_routing', {}).get('route_taken', 'save_exit'),
'preflight_ui_detected': d.get('preflight_ui', {}).get('interactive_config_detected', False),
'preflight_ui_patched':  d.get('preflight_ui', {}).get('reporter_auto_patched', False),
```

```bash
# In the sed -n fallback block (around lines 56–74), add matching extractions
# using the existing bracket-expression pattern (no -P required for portability):
local recovery_route
recovery_route=$(sed -n 's/.*"route_taken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$summary_file" 2>/dev/null | head -1)
: "${recovery_route:=save_exit}"
local build_fix_outcome
build_fix_outcome=$(sed -n 's/.*"build_fix_stats".*"outcome"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$summary_file" 2>/dev/null | head -1)
: "${build_fix_outcome:=not_run}"
# Append to json_content alongside the existing fields.
```

Match the existing style: `: "${VAR:=default}"` for defaults,
`bracket-expression` not PCRE. The python path is preferred when
`python3` is available; the sed fallback handles environments without
python.

**Renderer layer (best-effort).** `grep -r "_build_run_badge\|run.*badge"
lib/ tools/ tests/` returns zero matches at write time — there is no
existing badge helper to extend. Two options for the implementing
agent:

1. **Defer badges to a follow-up.** Land the data-layer changes only;
   note in the milestone close-out that Watchtower badge rendering for
   `[env-gate-retry]` and `[preflight-patch]` is queued for a future
   Watchtower polish milestone. m134 S5.1 validates the JSON fields
   directly — badges are not on its acceptance path.
2. **Add a minimal badge string to the parser output.** Compose a
   `badges` field in the json_content (e.g.
   `"badges":["env-gate-retry","preflight-patch"]`) so any current or
   future renderer can read it without a separate extraction pass. This
   is purely additive and does not require touching any TUI/HTML
   rendering code.

Pick option 1 if the Watchtower render path cannot be located in a
single `grep`; pick option 2 if a small, surgical addition to the
parser output keeps the contract forward-compatible. Do not invent a
badge-rendering helper from scratch in this milestone — that's outside
the resilience-arc scope.

### Goal 10 — Tests

Add test cases to `tests/test_finalize_summary.sh` (extend existing file
rather than creating new one):

#### T1 — `_collect_causal_context_json` with v2 fixture

```
Feed a v2 LAST_FAILURE_CONTEXT.json fixture.
Expect: output contains "primary_category":"ENVIRONMENT", "secondary_category":"AGENT_SCOPE"
```

#### T2 — `_collect_causal_context_json` with v1 fixture

```
Feed a v1 fixture (no schema_version, no primary_cause).
Expect: schema_version=1, primary fields empty, secondary from top-level keys.
```

#### T3 — `_collect_causal_context_json` when file absent

```
No LAST_FAILURE_CONTEXT.json in PROJECT_DIR.
Expect: {"schema_version": 0}
```

#### T4 — `_collect_build_fix_stats_json` with m128 vars set

```
BUILD_FIX_ATTEMPTS=2 BUILD_FIX_OUTCOME=exhausted BUILD_FIX_TURN_BUDGET_USED=40
Expect: "attempts":2, "outcome":"exhausted", "enabled":true
```

#### T5 — `_collect_build_fix_stats_json` with no vars (pre-m128)

```
No BUILD_FIX_* vars in env.
Expect: "attempts":0, "outcome":"not_run", "enabled":false
```

#### T6 — `error_classes_encountered` contains root: prefix on failure with primary cause

```
AGENT_ERROR_CATEGORY=AGENT_SCOPE AGENT_ERROR_SUBCATEGORY=max_turns
_ORCH_PRIMARY_CAT=ENVIRONMENT _ORCH_PRIMARY_SUB=test_infra
Expect: error_classes contains "AGENT_SCOPE/max_turns" AND "root:ENVIRONMENT/test_infra"
```

#### T7 — `error_classes_encountered` has no root: duplicate when primary matches symptom

```
AGENT_ERROR_CATEGORY=ENVIRONMENT _ORCH_PRIMARY_CAT=ENVIRONMENT (same)
Expect: error_classes has exactly one entry (no duplicate)
```

#### T8 — `recovery_actions_taken` includes route when non-default

```
_ORCH_RECOVERY_ROUTE_TAKEN=retry_ui_gate_env
Expect: "recovery_actions_taken" contains "retry_ui_gate_env"
```

#### T9 — `recovery_actions_taken` does not include save_exit (default)

```
_ORCH_RECOVERY_ROUTE_TAKEN=save_exit (or unset)
Expect: "retry" entry absent from recovery_actions array
```

#### T10 — Full RUN_SUMMARY.json emitted with all four new fields present

```
Run _hook_emit_run_summary with minimal env.
Assert: output JSON contains "causal_context", "build_fix_stats",
        "recovery_routing", "preflight_ui" top-level keys.
```

## Files Modified

| File | Change |
|------|--------|
| `lib/finalize_summary_collectors.sh` | **New file.** Houses the four collector helpers (`_collect_causal_context_json`, `_collect_build_fix_stats_json`, `_collect_recovery_routing_json`, `_collect_preflight_ui_json`). New file (rather than appending to `lib/finalize_summary.sh`) is mandatory: `finalize_summary.sh` is currently 282 lines and the additions are ~80–100 LOC, which would push it over CLAUDE.md non-negotiable rule 8 (300-line ceiling). Keep the file ≤ 300 lines. |
| `lib/finalize_summary.sh` | Source `finalize_summary_collectors.sh` near the top; add four new top-level fields to the `printf` format string at line 240 (insert between `"remediations"` and `"timestamp"`); enrich `error_classes_encountered` and `recovery_actions_taken` as described in Goals 5–6. Verify the file ends ≤ 300 lines after changes (currently 282; budget ~18 LOC for the enrichments + 4 collector calls + 4 new printf args). |
| `lib/orchestrate_loop.sh` | In `_handle_pipeline_failure` at line 199, immediately after `recovery=$(_classify_failure)`, add `_ORCH_RECOVERY_ROUTE_TAKEN="$recovery"` to capture the route for every recovery action (not just `retry_ui_gate_env`). One-line change. |
| `lib/orchestrate_recovery.sh` | **No change in m132.** `_ORCH_RECOVERY_ROUTE_TAKEN` is declared and reset by m130; `_load_failure_cause_context` is added by m130. Both are hard dependencies. (Forward-compat fallback: if m132 ships before m130, also add the declaration here — see Goal 8 coordination note.) |
| `lib/dashboard_parsers_runs_files.sh` | Extend the existing `python3 -c` JSON dict (around line 38) with `causal_primary_category`, `causal_primary_subcategory`, `build_fix_outcome`, `build_fix_attempts`, `recovery_route`, `preflight_ui_detected`, `preflight_ui_patched`. Add matching `sed -n` bracket-expression fallback lines (around lines 56–74). **Do not introduce `grep -oP`** — the file uses python3 + sed only for portability. See Goal 9 for code shape. |
| Watchtower TUI/HTML renderer | **Best-effort, may defer.** No `_build_run_badge*` helper exists at write time; `grep -r "_build_run_badge\|run.*badge" lib/ tools/ tests/` returns zero matches. Pick option 1 (defer to follow-up Watchtower polish milestone, document in close-out) or option 2 (compose a `badges` field in parser output) per Goal 9. m134 S5.1 acceptance does not require badge rendering. |
| `tests/test_finalize_summary.sh` | Extend with test cases T1–T10. |
| `docs/reference/run-summary-schema.md` | Document the four new top-level fields and updated `error_classes_encountered` format. If this file does not exist, create it (the `docs/reference/` directory exists with `agents.md`, `commands.md`, `configuration.md`, `stages.md`, `template-variables.md` already present). |

## Implementation Notes

### Parser reuse between m130 and m132

Both `_load_failure_cause_context` (m130, in `orchestrate_recovery.sh`)
and `_collect_causal_context_json` (m132, in `finalize_summary.sh`)
parse the same JSON file with the same line-by-line grep approach. To
avoid duplication, the shared parse logic can be extracted to
`lib/diagnose_output.sh` as:

```bash
# _read_failure_cause_fields ctx_file
# Populates _FC_PRIMARY_CAT, _FC_PRIMARY_SUB, _FC_PRIMARY_SIGNAL,
#           _FC_SECONDARY_CAT, _FC_SECONDARY_SUB, _FC_SECONDARY_SIGNAL,
#           _FC_SCHEMA_VERSION
# Caller is responsible for unsetting/re-using these globals.
```

Both m130 and m132 source `diagnose_output.sh` (it's already in the
dependency chain for both `orchestrate_recovery.sh` and
`finalize_summary.sh`). The extraction is a non-breaking refactor.
If implementing m132 before m130 is fully deployed, duplicate the
parser inline first — it can be consolidated when m130 lands.

### JSON shape stability guarantee

The four new fields are **always** emitted regardless of run outcome.
On success runs:

```json
"causal_context":    {"schema_version": 0},
"build_fix_stats":   {"enabled": false, "attempts": 0, "max_attempts": 3, "outcome": "not_run", ...},
"recovery_routing":  {"route_taken": "save_exit", "env_gate_retried": false, ...},
"preflight_ui":      {"interactive_config_detected": false, ...}
```

Dashboard parsers must treat `schema_version: 0` in `causal_context`
as "no causal data available" and render nothing rather than empty
strings. This prevents future `null`-vs-missing bugs.

### Backward compatibility for existing RUN_SUMMARY consumers

Existing consumers (Watchtower TUI, HTML dashboard, `tekhton --diagnose`)
read named fields from `RUN_SUMMARY.json` by key, not by positional
index. Adding new top-level fields is backward-compatible: old consumers
ignore unknown keys. The only breaking change would be removing or
renaming an existing key — this milestone does neither.

The `error_classes_encountered` change is additive (adds a second element
to the array). Existing consumers that read `error_classes_encountered[0]`
for the surface-level error class continue to work. New consumers that
want the root cause check for a `"root:"` prefix.

## Watch For

- **300-line ceiling on `lib/finalize_summary.sh`.** Currently 282
  lines. The four new collector helpers must live in
  `lib/finalize_summary_collectors.sh` (a new file) — appending in
  place would push `finalize_summary.sh` over the CLAUDE.md non-negotiable
  rule 8 ceiling. Run `wc -l lib/finalize_summary*.sh` before committing.
- **`_ORCH_RECOVERY_ROUTE_TAKEN` is m130's variable.** m130 declares it
  at module scope of `lib/orchestrate_recovery.sh` and zeroes it in
  `_reset_orch_recovery_state`. Goal 8 of m132 is **not** to declare
  it — it is to ensure the variable captures the route for *every*
  recovery action, not only `retry_ui_gate_env`. The wrap goes around
  `recovery=$(_classify_failure)` in `lib/orchestrate_loop.sh:199`. If
  m132 lands first (it should not — m130 is a hard dependency in
  MANIFEST.cfg), add the declaration as a forward-compat measure.
- **`_classify_failure` call site lives in `orchestrate_loop.sh`, not
  `orchestrate.sh`.** Earlier drafts of this milestone pointed at
  `run_complete_loop` in `lib/orchestrate.sh`. The actual call site is
  `_handle_pipeline_failure` at `lib/orchestrate_loop.sh:199`.
  `run_complete_loop` only delegates to it via
  `_handle_pipeline_failure "$_iter_turns" "$_files_changed"` at
  `lib/orchestrate.sh:251`. Putting the wrap in the wrong file looks
  correct in isolation but never fires. (m130's "Watch For" calls out
  the same trap.)
- **`BUILD_FIX_OUTCOME` token vocabulary is frozen by m128.** The four
  values are `passed | exhausted | no_progress | not_run`.
  `_collect_build_fix_stats_json` branches on those exact strings; do
  not normalize, abbreviate, or extend. m128's "Watch For" pins this
  identically — both ends of the contract are documented.
- **The four `PREFLIGHT_UI_*` env vars are m131's contract.** Names:
  `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED` (`0`/`1`),
  `PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE` (`PW-1`/`JV-1`/...),
  `PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE` (basename),
  `PREFLIGHT_UI_REPORTER_PATCHED` (`0`/`1`). Read with the
  `${VAR:-default}` idiom — they may be unset on success runs and on
  pre-m131 deployments.
- **Pretty-print contract for `LAST_FAILURE_CONTEXT.json`.** m129 emits
  the file with one key per line and multi-line nested cause objects;
  m130's `_load_failure_cause_context` parser depends on this. Calling
  m130's loader (per Goal 1) keeps the parser concentrated in one
  place — do not add a second copy that could drift.
- **`schema_version: 0` is the absent-file sentinel.** When
  `LAST_FAILURE_CONTEXT.json` is missing, `_collect_causal_context_json`
  returns `{"schema_version": 0}` — not `null`, not omitted. Dashboard
  parsers branch on `schema_version == 0` to render "no causal data
  available". m134 S5.2 asserts on this convention; do not change it.
- **JSON shape is stable across all run outcomes.** All four new
  top-level fields are emitted on success runs too, with their
  zero/null-ish variants documented in "Implementation Notes". This is
  what makes m134 S5.2 pass and keeps Watchtower's per-run row layout
  consistent. Do not skip emission on success — emit the empty-state
  variants instead.
- **`error_classes_encountered` is now a 1-or-2 element array.**
  Element 0 is the symptom (existing behavior, e.g.
  `AGENT_SCOPE/max_turns`). Element 1 — when present — is `root:`
  prefixed (e.g. `root:ENVIRONMENT/test_infra`). The prefix is the
  discriminator, not the array index — never assume index 1 is always
  root cause; check for the prefix. m133's `_rule_max_turns` extension
  uses the same convention.
- **`recovery_actions_taken` adds the route only when non-default.**
  When `_ORCH_RECOVERY_ROUTE_TAKEN` is empty or `save_exit`, the route
  is NOT appended (default case has no action worth surfacing). When
  any other route fired, append it as a string element — example:
  `["transient_retry", "retry_ui_gate_env"]`. This is intentional
  duplication with `recovery_routing.route_taken` (a new top-level
  field): the array gives a chronological history; the top-level field
  gives the final routing decision.
- **`lib/dashboard_parsers_runs_files.sh` does not use `grep -oP`.**
  It uses `python3 -c 'import json; ...'` for the canonical path and
  `sed -n` with bracket-expression patterns for the fallback. Adding
  `grep -oP` here breaks the existing portability story (BSD `grep`
  does not support `-P`). The Goal 9 pseudocode follows the existing
  python3 + sed style — match it.
- **Watchtower badge rendering is best-effort scope.** No
  `_build_run_badge*` function currently exists in `lib/` or
  `tools/`. The parser-side changes (Goal 9 data layer) are required.
  The renderer-side changes (badges) may be deferred to a follow-up
  Watchtower polish milestone if the badge entry point cannot be
  located in a single grep — flag and proceed without blocking on it.
- **`grep -oP` requires GNU grep with PCRE.** macOS default `grep`
  does not support `-P`. The whole resilience arc (m126/m127/m129/m130/m132/m133)
  assumes GNU grep is present for parsing `LAST_FAILURE_CONTEXT.json`.
  m132's collector helpers inherit this assumption; the dashboard
  parser deliberately uses `sed` (not `grep -oP`) precisely to keep
  the historical-data read path BSD-portable.

## Acceptance Criteria

- [ ] `lib/finalize_summary_collectors.sh` exists, is sourced by `lib/finalize_summary.sh`, and is ≤ 300 lines.
- [ ] `lib/finalize_summary.sh` ends ≤ 300 lines after the printf and enrichment changes (currently 282; budget ~18 LOC for the changes).
- [ ] `RUN_SUMMARY.json` emitted after a failure run with m128–m131 active contains `causal_context`, `build_fix_stats`, `recovery_routing`, and `preflight_ui` top-level keys.
- [ ] `RUN_SUMMARY.json` emitted on a *success* run also contains all four new keys with their empty-state variants (`causal_context.schema_version=0`, `build_fix_stats.outcome="not_run"`, `recovery_routing.route_taken="save_exit"`, `preflight_ui.interactive_config_detected=false`). Shape stability is non-negotiable.
- [ ] `causal_context.primary_category` correctly reflects the primary cause from `LAST_FAILURE_CONTEXT.json` schema v2 (not the symptom).
- [ ] `causal_context.schema_version` = 0 when `LAST_FAILURE_CONTEXT.json` is absent.
- [ ] `build_fix_stats.outcome` = `"not_run"` / `"enabled": false` when no `BUILD_FIX_*` vars are set.
- [ ] `error_classes_encountered` contains a `"root:"` prefixed entry distinct from the symptom entry when primary cause differs from surface classification.
- [ ] `error_classes_encountered` does not duplicate entries when primary cause equals symptom category.
- [ ] `recovery_routing.route_taken` reflects the actual action returned by `_classify_failure` at run end (verified via the call-site wrap in `lib/orchestrate_loop.sh:199`, not only the m130 `retry_ui_gate_env)` case branch).
- [ ] `preflight_ui.interactive_config_detected` = `true` when PW-1 fired during preflight.
- [ ] `lib/dashboard_parsers_runs_files.sh` extracts the new fields via the existing `python3 -c` dict (canonical) and matching `sed -n` lines (fallback). No `grep -oP` introduced.
- [ ] Watchtower run list renders `[env-gate-retry]` badge when `recovery_routing.route_taken` = `retry_ui_gate_env` **OR** the close-out note documents that badge rendering is deferred and the data is available in the parser output for a future renderer.
- [ ] All 10 test cases in `test_finalize_summary.sh` pass.
- [ ] Existing `RUN_SUMMARY.json` test cases remain green (backward-compatible shape — additive only).
- [ ] `shellcheck` clean for `lib/finalize_summary.sh`, `lib/finalize_summary_collectors.sh`, `lib/orchestrate_loop.sh`, `lib/dashboard_parsers_runs_files.sh`.

## Seeds Forward

This milestone is the **finalize-layer publication point** for the
resilience arc's runtime intelligence. Every downstream milestone reads
the four new top-level fields by name; pin the names and shapes here.

- **m133 — Diagnose Rule Enrichment.** Hard contract:
  - `_rule_ui_gate_interactive_reporter` reads
    `recovery_routing.route_taken` (`== "retry_ui_gate_env"`) and
    `causal_context.primary_subcategory` (`== "test_infra"`).
  - `_rule_build_fix_exhausted` reads `build_fix_stats.outcome`
    (`exhausted` / `no_progress`) and `build_fix_stats.attempts` (≥ 2).
  - `_rule_preflight_interactive_config` reads
    `preflight_ui.interactive_config_detected` (`true`),
    `preflight_ui.reporter_auto_patched` (`true`/`false`),
    `preflight_ui.interactive_config_rule`, and
    `preflight_ui.interactive_config_file`.
  - `_rule_mixed_classification` reads
    `causal_context.primary_signal == "mixed_uncertain_classification"`
    and may use any `root:` entry in `error_classes_encountered` as
    supplemental context when present.
  → Do not rename or restructure any of the four new top-level keys
  after this milestone lands. m133 will be merged with byte-exact key
  names hard-coded.

- **m134 — Resilience Arc Integration Test Suite.** Scenario S5.1
  ("RUN_SUMMARY enrichment — full chain") drives `_hook_emit_run_summary`
  end-to-end and asserts:
  - `causal_context` key present with `primary_category="ENVIRONMENT"`.
  - `build_fix_stats` key present with `outcome="exhausted"` and
    `attempts=2`.
  - `recovery_routing` key present with `route_taken="retry_ui_gate_env"`.
  - `preflight_ui` key present with `interactive_config_detected=true`.

  Scenario S5.2 ("RUN_SUMMARY shape on success") asserts the
  empty-state variants documented in this milestone:
  - `causal_context.schema_version=0`
  - `build_fix_stats.outcome="not_run"`, `enabled=false`
  - `recovery_routing.route_taken="save_exit"` (default)
  - `preflight_ui.interactive_config_detected=false`

  → Keep these contract values stable; m134 hard-codes them. The
  empty-state variants in particular are easy to overlook; the JSON
  shape stability acceptance criterion above is the canary.

- **m135 — Resilience Arc Artifact Lifecycle.** m135 adds
  `_clear_arc_artifacts_on_success` which removes
  `LAST_FAILURE_CONTEXT.json` on outcome=success.
  `_collect_causal_context_json` must degrade gracefully when the file
  is absent (return `{"schema_version": 0}`). m135 explicitly relies
  on this degrade path so success runs don't carry stale failure
  context into `RUN_SUMMARY.json`.
  → Keep the absent-file degrade path working; m135 depends on it.

- **m136 — Resilience Arc Config Defaults & Validation.** No direct
  contract with m132 — m136 declares the m126/m128/m130/m131 config
  knobs but does not affect `RUN_SUMMARY.json` shape. Listed for
  completeness; m132 has no work to defer.

- **m137 — V3.2 Migration Script.** No direct contract — m137 migrates
  `pipeline.conf` and `.gitignore` for the new arc config and artifact
  paths. `RUN_SUMMARY.json` shape is consumer-side, not config-side,
  so m137 does not touch m132's output.

- **m138 — Runtime CI Environment Auto-Detection.** Lists m132 in its
  prior-arc context table as "RUN_SUMMARY causal fidelity". No direct
  contract; m138's CI-detection logic doesn't read `RUN_SUMMARY.json`.

- **Watchtower run-detail badges (future polish).** Goal 9 introduces
  `[env-gate-retry]` and `[preflight-patch]` badges driven off
  `recovery_routing.route_taken == "retry_ui_gate_env"` and
  `preflight_ui.reporter_auto_patched == true`. The strings are m132's
  call; the underlying tokens are m130's and m131's respectively.
  → If a future redesign collapses or renames `retry_ui_gate_env` or
  the `PREFLIGHT_UI_*` vocabulary, update the badge mapping here at
  the same time.

- **External dashboard consumers.** Tools outside Tekhton (CI
  dashboards, custom analytics) that ingest `RUN_SUMMARY.json` get the
  four new top-level fields automatically. The additive-only guarantee
  documented in "Implementation Notes" (existing keys unchanged, only
  new keys added) is the contract for those consumers.
  → Don't ever remove or rename existing `RUN_SUMMARY.json` keys; only
  add new ones.
