# M129 - Failure Context Schema Hardening & Primary/Secondary Cause Fidelity

<!-- milestone-meta
id: "129"
status: "pending"
-->

## Overview

M126-M128 improve execution determinism and recovery depth, but a
diagnostic fidelity gap remains in state persistence:

1. `PIPELINE_STATE.md` can end with a downstream agent failure
   (`AGENT_SCOPE/max_turns`) even when the primary trigger was a gate
   failure class (for example non-code dominant UI timeout).
2. `LAST_FAILURE_CONTEXT.json` currently stores only coarse fields
   (`classification`, `stage`, `outcome`, `task`, `consecutive_count`).
3. Diagnose rules (`_rule_max_turns`) attempt to read
   `category`/`subcategory` from that JSON, but current writer does not
   persist those keys, creating inconsistent behavior between tests and
   production runs.

Result: root cause can be masked by secondary failure symptoms, and
`--diagnose` confidence is lower than it should be.

M129 introduces a normalized failure-context schema with explicit
primary/secondary cause slots and ensures all writers/readers use the
same contract.

## Design

### Goal 1 - Version and normalize LAST_FAILURE_CONTEXT schema

Upgrade `write_last_failure_context` in `lib/diagnose_output.sh` to
emit schema versioned JSON:

```json
{
  "schema_version": 2,
  "classification": "MAX_TURNS_EXHAUSTED",
  "stage": "coder",
  "outcome": "failure",
  "task": "M03",
  "consecutive_count": 1,
  "timestamp": "...",
  "category": "AGENT_SCOPE",
  "subcategory": "max_turns",
  "primary_cause": {
    "category": "ENVIRONMENT",
    "subcategory": "test_infra",
    "signal": "ui_timeout_interactive_report",
    "source": "build_gate"
  },
  "secondary_cause": {
    "category": "AGENT_SCOPE",
    "subcategory": "max_turns",
    "signal": "build_fix_budget_exhausted",
    "source": "coder_build_fix"
  }
}
```

#### Pretty-print contract (NON-NEGOTIABLE — downstream parsers depend on it)

Downstream rules in m130, m132, and m133 parse this file with
`grep -oP` line scans, **not** with `jq`. To keep those parsers
working, the writer must emit:

- One top-level key per line.
- `primary_cause` and `secondary_cause` as multi-line nested objects,
  one inner key per line, terminated by a closing `}` on its own line
  (or with a trailing `,` after the brace if more keys follow).
- No minified / single-line variants.

Reference shape m130's `_load_failure_cause_context` line-state-machine
expects (each block opens after a `"primary_cause"` / `"secondary_cause"`
key line and closes on the first `}` line):

```
{
  "schema_version": 2,
  "classification": "...",
  ...
  "category": "AGENT_SCOPE",
  "subcategory": "max_turns",
  "primary_cause": {
    "category": "ENVIRONMENT",
    "subcategory": "test_infra",
    "signal": "ui_timeout_interactive_report",
    "source": "build_gate"
  },
  "secondary_cause": {
    "category": "AGENT_SCOPE",
    "subcategory": "max_turns",
    "signal": "build_fix_budget_exhausted",
    "source": "coder_build_fix"
  }
}
```

Use a multi-line `printf` with explicit `\n` between every key, or
build the JSON with a small `python3 -c 'import json; print(json.dumps(d, indent=2))'`
helper — both are acceptable and produce identical-shape output. **Do
not** collapse the cause objects onto one line for any reason.

#### Backward compatibility

- Continue writing top-level `classification`, `stage`, `outcome`,
  `task`, `consecutive_count`, `timestamp`.
- **Latent-bug fix:** The current writer (lines 237-244 of
  `diagnose_output.sh` as of v3.125.x) emits **no** top-level `category`
  or `subcategory` keys. `lib/diagnose_rules.sh:_rule_max_turns` reads
  those keys from the file (line 85-86), so the JSON-driven match path
  silently never fires — the rule only matches today via the
  `_exit_reason` and state-notes fallbacks. Adding top-level
  `category`/`subcategory` as aliases of `secondary_cause` (or, when
  no secondary is set, of the symptom-level `AGENT_ERROR_*` env vars)
  closes that gap for v1 readers and any third-party tooling already
  written against those keys.
- v1 callers that read only `classification`/`stage`/`outcome`/`task`
  remain unchanged.

### Goal 2 - Introduce explicit primary vs secondary error context at write sites

Add exported context variables (set opportunistically where known):

- `PRIMARY_ERROR_CATEGORY`, `PRIMARY_ERROR_SUBCATEGORY`,
  `PRIMARY_ERROR_SIGNAL`, `PRIMARY_ERROR_SOURCE`
- `SECONDARY_ERROR_CATEGORY`, `SECONDARY_ERROR_SUBCATEGORY`,
  `SECONDARY_ERROR_SIGNAL`, `SECONDARY_ERROR_SOURCE`

Writer precedence in `write_last_failure_context`:

1. If primary/secondary variables are present, persist them.
2. Else infer secondary from `AGENT_ERROR_CATEGORY/SUBCATEGORY`.
3. Else infer from classification fallback.

M129 does not require every stage to populate primary context yet;
stages can opt in incrementally. Immediate mandatory integration:

- coder build-gate/build-fix exit path (`stages/coder.sh`)
- finalize failure hook (`lib/finalize_dashboard_hooks.sh`)

### Goal 3 - Ensure diagnose readers consume new schema first

Update `_read_diagnostic_context` in `lib/diagnose.sh`:

1. Parse `primary_cause` and `secondary_cause` when present.
2. Populate module state variables:
   - `_DIAG_PRIMARY_CATEGORY`, `_DIAG_PRIMARY_SUBCATEGORY`
   - `_DIAG_SECONDARY_CATEGORY`, `_DIAG_SECONDARY_SUBCATEGORY`
3. Fall back to top-level `category/subcategory`, then legacy behavior.

Update rules in `lib/diagnose_rules.sh`:

- `_rule_max_turns` should prefer secondary cause category/subcategory,
  but include guard: if primary is non-agent and secondary is max_turns,
  add suggestion line indicating max_turns is secondary symptom.

### Goal 4 - Persist causal summary into PIPELINE_STATE notes block

Add a small helper (in the new `lib/failure_context.sh` from Goal 5)
that returns a 1- or 2-line plain-text summary of the current cause
slots — `format_failure_cause_summary` — emitting:

```text
Primary cause: ENVIRONMENT/test_infra (ui_timeout_interactive_report)
Secondary cause: AGENT_SCOPE/max_turns (build_fix_budget_exhausted)
```

The function must:

- Return empty string when both primary and secondary slots are unset
  (so the Notes block is unchanged on stages that haven't opted in).
- Emit only the primary line when secondary is unset.
- Emit only the secondary line when primary is unset (legacy fallback).

Wire the summary into pipeline-state writes at these specific call
sites (do **not** change `lib/state.sh:write_pipeline_state` itself —
the contract remains "caller supplies Notes"):

| Call site (file:function) | What to add |
|---|---|
| `lib/orchestrate_recovery.sh` — wherever `_save_orchestration_state` (or equivalent) builds the Notes block before `write_pipeline_state` | Append `format_failure_cause_summary` output to the Notes string when non-empty. |
| `lib/finalize_dashboard_hooks.sh:_hook_failure_context` | After `write_last_failure_context`, also append the summary to any state-file Notes write happening in the failure path. |

This keeps `PIPELINE_STATE.md` human-readable and aligns with JSON
failure context. The Notes block format itself is untouched —
`format_failure_cause_summary` returns lines that drop into the
existing free-form Notes section.

### Goal 5 - Add helper for causal-slot initialization/reset

Create a **new** file: `lib/failure_context.sh`.

Why a new file (not appended to `lib/diagnose_output.sh`):
`diagnose_output.sh` is currently **332 lines** — already over the
300-line ceiling from CLAUDE.md. Adding the writer changes from Goal 1
plus these helpers would push it further over budget. The 300-line
rule kicks in when modifying the file, so this milestone must also
shrink `diagnose_output.sh` in the process — see "Watch For" below.
The cleanest split is to extract all primary/secondary cause logic
(slot vars, setters, reset, summary formatter, JSON-fragment builder)
into `lib/failure_context.sh`, leaving `diagnose_output.sh` focused
on report rendering + the writer entrypoint.

`lib/failure_context.sh` exports:

```bash
# State (module-level vars, exported for cross-stage visibility):
PRIMARY_ERROR_CATEGORY=""
PRIMARY_ERROR_SUBCATEGORY=""
PRIMARY_ERROR_SIGNAL=""
PRIMARY_ERROR_SOURCE=""
SECONDARY_ERROR_CATEGORY=""
SECONDARY_ERROR_SUBCATEGORY=""
SECONDARY_ERROR_SIGNAL=""
SECONDARY_ERROR_SOURCE=""

# API:
reset_failure_cause_context              # zeroes all eight vars
set_primary_cause   CAT SUB SIGNAL SRC   # populates PRIMARY_*
set_secondary_cause CAT SUB SIGNAL SRC   # populates SECONDARY_*
format_failure_cause_summary             # plain-text 1-2 line summary (Goal 4)
emit_cause_objects_json                  # builds the two nested JSON
                                         # objects, pretty-printed per the
                                         # Goal 1 contract; called by writer
```

Source `lib/failure_context.sh` from `tekhton.sh` early (before
`lib/diagnose_output.sh`) so the slot vars exist by the time any
stage tries to populate them.

Call `reset_failure_cause_context`:

- At run start (in `tekhton.sh` after argument parsing, before the
  pipeline begins).
- At the top of each `run_complete_loop` iteration in `lib/orchestrate.sh`
  (parallels m130's `_reset_orch_recovery_state` reset point).
- After a successful finalize (in `lib/finalize.sh` success path) to
  prevent stale carry-over into a subsequent same-shell run.

### Goal 6 - Add fixture-backed schema tests and compatibility tests

Add new test file:

- `tests/test_failure_context_schema.sh`

Use this exact fixture shape for v2 tests (matches m134's integration
fixtures verbatim — keep them aligned so neither set drifts):

```json
{
  "schema_version": 2,
  "classification": "UI_INTERACTIVE_REPORTER",
  "stage": "coder",
  "outcome": "failure",
  "task": "M03",
  "consecutive_count": 1,
  "category": "AGENT_SCOPE",
  "subcategory": "max_turns",
  "primary_cause": {
    "category": "ENVIRONMENT",
    "subcategory": "test_infra",
    "signal": "ui_timeout_interactive_report",
    "source": "build_gate"
  },
  "secondary_cause": {
    "category": "AGENT_SCOPE",
    "subcategory": "max_turns",
    "signal": "build_fix_budget_exhausted",
    "source": "coder_build_fix"
  }
}
```

Test cases:

1. `writes_schema_v2_with_primary_secondary`
   - set primary/secondary vars via `set_primary_cause` /
     `set_secondary_cause`, call writer, assert JSON keys present.

2. `writes_legacy_aliases_for_compat`
   - assert top-level `category`/`subcategory` exist and equal
     secondary-cause values when secondary is set; equal symptom-level
     `AGENT_ERROR_*` values when only secondary is unset.

3. `writes_pretty_printed_one_key_per_line`
   - assert the rendered file contains
     `\n  "primary_cause": {` AND
     `\n    "category": "ENVIRONMENT"` on separate lines (line-format
     contract from Goal 1). Failing this test means downstream m130/m132/m133
     parsers will silently mis-classify.

4. `diagnose_reads_v2_primary_secondary`
   - feed fixture JSON, assert `_DIAG_PRIMARY_*` and `_DIAG_SECONDARY_*`
     populated correctly.

5. `diagnose_falls_back_to_legacy_fields`
   - fixture with only legacy keys, assert no crash and expected values.

6. `max_turns_rule_marks_secondary_symptom`
   - primary non-agent + secondary max_turns fixture, assert suggestion
     contains secondary-symptom note.

7. `reset_clears_all_eight_vars`
   - set primary + secondary, call `reset_failure_cause_context`,
     assert all eight `PRIMARY_*`/`SECONDARY_*` vars are empty.

8. `format_summary_handles_partial_population`
   - primary-only → single line; secondary-only → single line; both
     unset → empty string.

Also extend `tests/test_diagnose.sh` to use real v2 fixture shape
instead of test-only keys that the production writer never emitted.

## Signal Vocabulary (contract for upstream stages)

m129 owns the **slot shape**, not the signal names. Other milestones
in the resilience arc populate specific signal/source values that
downstream rules in m132/m133 will match on. Pin these strings now so
that m126/m127/m128 emit the same vocabulary m133 reads:

| Slot | Signal | Source | Set by | Read by |
|------|--------|--------|--------|---------|
| primary | `ui_timeout_interactive_report` | `build_gate` | m126 (UI gate fast-fail path) | m130 (`retry_ui_gate_env`), m133 (`_rule_ui_gate_interactive_reporter`) |
| primary | `mixed_uncertain_classification` | `build_gate` | m127 (low-confidence classifier) | m133 (`_rule_mixed_classification`) |
| primary | `ui_interactive_config_preflight` | `preflight` | m131 (config audit fail) | m133 (`_rule_preflight_interactive_config`) |
| secondary | `build_fix_budget_exhausted` | `coder_build_fix` | m128 (continuation loop give-up) | m132 (`build_fix_stats`), m133 (`_rule_build_fix_exhausted`) |
| secondary | `max_turns` (subcategory) | `<stage>_agent` | any stage hitting `AGENT_SCOPE/max_turns` | m130, m133 |

m129 itself only **sets** these for the two integrations called out
in Goal 2 (coder build-fix exit path; finalize failure hook). m126,
m127, m128, and m131 each take ownership of their respective primary
signals when they land — m129's job is to make the slots available
and document the vocabulary so those milestones don't drift.

## Files Modified

| File | Change |
|------|--------|
| `lib/failure_context.sh` | **New file.** Module state vars (`PRIMARY_*`/`SECONDARY_*`), `reset_failure_cause_context`, `set_primary_cause`, `set_secondary_cause`, `format_failure_cause_summary`, `emit_cause_objects_json`. Must stay ≤ 300 lines. |
| `lib/diagnose_output.sh` | Upgrade `write_last_failure_context` to schema v2 with primary/secondary cause objects (consuming `emit_cause_objects_json` from `failure_context.sh`) and compatibility aliases. **Must finish ≤ 300 lines** — currently 332; extracting Goal 5 helpers covers the shrink budget. |
| `lib/diagnose.sh` | Parse primary/secondary cause fields into `_DIAG_PRIMARY_*` / `_DIAG_SECONDARY_*` state, with fallback order for legacy schema. |
| `lib/diagnose_rules.sh` | Update `_rule_max_turns` to consume secondary cause and surface primary-vs-secondary messaging in suggestions. **Currently 299 lines — keep under 300; if the patch grows, extract the rule helper to `diagnose_rules_extra.sh`.** |
| `lib/finalize_dashboard_hooks.sh` | Populate cause slots before calling `write_last_failure_context` on failure path; append `format_failure_cause_summary` output to state-file Notes write. |
| `lib/finalize.sh` | Call `reset_failure_cause_context` in success path post-finalize. |
| `lib/orchestrate.sh` | Call `reset_failure_cause_context` at the top of each `run_complete_loop` iteration. |
| `lib/orchestrate_recovery.sh` | At the call site that builds the failure-state Notes block, append `format_failure_cause_summary` output when non-empty. |
| `stages/coder.sh` | Set primary/secondary cause context on build-gate and build-fix terminal branches via `set_primary_cause` / `set_secondary_cause`. |
| `tekhton.sh` | Source `lib/failure_context.sh` early (before `lib/diagnose_output.sh`); call `reset_failure_cause_context` after argument parsing. Bump `TEKHTON_VERSION`. |
| `tests/test_failure_context_schema.sh` | **New file.** Schema writer/reader compatibility tests T1–T8. |
| `tests/test_diagnose.sh` | Update fixtures/assertions to validate v2 schema handling and secondary-symptom max-turns messaging. |
| `tests/run_tests.sh` | Register `test_failure_context_schema.sh`. |
| `docs/troubleshooting/diagnose.md` | Document failure-context schema v2 and interpretation of primary vs secondary causes. |
| `.claude/milestones/MANIFEST.cfg` | Mark m129 `done` (during finalize). |

## Acceptance Criteria

- [ ] `LAST_FAILURE_CONTEXT.json` writes `schema_version: 2` and includes `primary_cause` and `secondary_cause` objects when context is available.
- [ ] Writer preserves top-level compatibility keys (`classification`, `stage`, `outcome`, `task`, `consecutive_count`, `timestamp`, plus alias `category`/`subcategory`).
- [ ] **Pretty-print contract held**: rendered file has `primary_cause` and `secondary_cause` as multi-line nested objects, one inner key per line. Verified by `writes_pretty_printed_one_key_per_line` test.
- [ ] `lib/failure_context.sh` exists with `reset_failure_cause_context`, `set_primary_cause`, `set_secondary_cause`, `format_failure_cause_summary`, `emit_cause_objects_json` and is sourced from `tekhton.sh` before `lib/diagnose_output.sh`.
- [ ] `reset_failure_cause_context` is called at run start, at each `run_complete_loop` iteration, and post-success-finalize.
- [ ] `--diagnose` reads v2 schema fields first and falls back safely to legacy keys.
- [ ] `_rule_max_turns` can still match, but when primary cause is non-agent and secondary is max_turns, suggestions explicitly label max_turns as secondary symptom. (M133 will fully replace this with `MAX_TURNS_ENV_ROOT` — m129 only adds the suggestion-line guard.)
- [ ] `PIPELINE_STATE.md` failure notes include both primary and secondary causal summary lines when known.
- [ ] New schema tests pass and existing diagnose tests remain green.
- [ ] No regression when context fields are absent (all logic degrades gracefully).
- [ ] All modified `.sh` files end ≤ 300 lines (CLAUDE.md hygiene rule). Specifically `lib/diagnose_output.sh` (currently 332) is brought under via the Goal 5 extraction.
- [ ] `shellcheck` clean for all modified shell files.
- [ ] Signal vocabulary table from this milestone appears in `docs/troubleshooting/diagnose.md` so m126/m127/m128/m131 implementers reference the same contract.

## Watch For

- **Pretty-print is load-bearing.** m130's `_load_failure_cause_context`,
  m132's `_collect_causal_context_json`, and m133's rules all parse this
  file with `grep -oP` line scans, not `jq`. If the writer emits
  minified or single-line JSON, every downstream consumer silently
  mis-classifies. The `writes_pretty_printed_one_key_per_line` test
  is the canary — do not weaken or skip it.
- **300-line ceiling — `diagnose_output.sh` is already 332 lines.**
  Modifying it triggers CLAUDE.md's hygiene rule. The Goal 5 extraction
  to `lib/failure_context.sh` is mandatory, not optional, just to land
  this milestone cleanly. Run `wc -l lib/diagnose_output.sh
  lib/failure_context.sh lib/diagnose_rules.sh` before committing.
- **Latent bug in current `_rule_max_turns`.** The current writer
  emits no `category`/`subcategory` keys, so the rule's JSON-driven
  match path (lines 85-86 of `diagnose_rules.sh`) never fires today.
  The only reason `_rule_max_turns` triggers in production is the
  fallback paths (`_exit_reason`, state-notes scan). After m129 lands
  the JSON path will start firing — make sure the existing
  `_exit_reason` path still works for runs where the JSON file is
  absent or stale.
- **Don't conflate primary and secondary semantics.** Primary = root
  cause, the thing that started the failure. Secondary = symptom
  observed on the way out. Stages should always set primary when they
  *know* the upstream cause (e.g., m126's UI gate detecting the
  interactive reporter), and secondary when they only see the
  downstream effect (e.g., a max_turns timeout in the build-fix
  loop). Don't write the same value to both slots — leave primary
  empty rather than guess.
- **Reset semantics matter.** Cause slots are exported env vars.
  Without explicit reset between attempts, a stale primary from a
  previous loop iteration will get persisted into the next iteration's
  failure file. The three reset call sites in Goal 5 are all required;
  removing any one of them creates a hard-to-trace cross-attempt
  contamination bug. (m134 has an integration test that catches this —
  see scenario S4.x — but failing locally first is cheaper.)
- **Top-level alias precedence.** When `secondary_cause` is set, the
  top-level `category`/`subcategory` aliases must mirror it. When only
  `AGENT_ERROR_*` env vars are set (no slot population yet from a
  given stage), the aliases mirror those instead. Never emit empty
  string aliases — omit the keys entirely if no source is available.
- **Reader fallback order in `_DIAG_*` state.** Primary > secondary >
  legacy top-level > legacy env vars. Document this order at the top
  of `_read_diagnostic_context` so future readers don't reinvent it.
- **Don't define new signal names locally.** The signal vocabulary
  table in this file is the authority. If a stage needs a new signal
  string, add it to that table in this milestone or its successor —
  do not coin a new string ad-hoc, because m133's rules grep for exact
  matches.

## Seeds Forward

This milestone is the **schema substrate** for the rest of the
resilience arc. Downstream milestones consume the slots without
re-defining them:

- **m130 — Causal-Context-Aware Recovery Routing** (depends on m129).
  Adds `_load_failure_cause_context` (line-based parser) that reads
  the v2 file written by this milestone. Requires the pretty-print
  contract from Goal 1 verbatim. New routing actions
  (`retry_ui_gate_env`) gated on `_ORCH_PRIMARY_CAT=ENVIRONMENT`.
  → Keep the JSON shape stable; m130 will not use `jq`.

- **m131 — Preflight UI Config Audit** (depends on m126; sibling to
  m129). Sets `primary_cause.signal=ui_interactive_config_preflight`
  with source `preflight` when its config audit detects the
  Playwright issue **before** the gate runs. → Reserve that signal
  string in the vocabulary table.

- **m132 — RUN_SUMMARY Causal Fidelity Enrichment** (depends on m129).
  Adds `causal_context` top-level field to `RUN_SUMMARY.json` whose
  shape mirrors the v2 schema. Re-uses (or duplicates) the line-based
  parser. Adds `error_classes_encountered` `root:` prefix that requires
  `_ORCH_PRIMARY_CAT` (downstream of m129's slot population).
  → Don't break the slot variable names — they are the public
  interface.

- **m133 — Diagnose Rule Enrichment** (depends on m129, m131, m132).
  Adds `_rule_ui_gate_interactive_reporter`,
  `_rule_preflight_interactive_config`, `_rule_build_fix_exhausted`,
  `_rule_mixed_classification`. Each greps `LAST_FAILURE_CONTEXT.json`
  for **exact signal strings** from the vocabulary table:
  `ui_timeout_interactive_report`, `ui_interactive_config_preflight`,
  `build_fix_budget_exhausted`, `mixed_uncertain_classification`.
  Also fully replaces the m129 `_rule_max_turns` "secondary symptom"
  hint with a dedicated `MAX_TURNS_ENV_ROOT` classification when
  primary is non-agent. → Do not rename the signals after this
  milestone lands; m133 will be merged with the strings hard-coded.

- **m134 — Resilience Arc Integration Test Suite** (depends on
  m126–m133). Hard-codes the v2 fixture shape (lines 484-505 of m134).
  → Keep the m129 `tests/test_failure_context_schema.sh` v2 fixture
  byte-for-byte aligned with m134's fixture so neither set drifts out
  from under the other. Specifically the field order, indentation
  (2-space), and `source` key inclusion all matter.
