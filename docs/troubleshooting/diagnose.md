# Using --diagnose

When a pipeline run fails, `--diagnose` analyzes the failure and suggests
recovery steps.

## Running Diagnostics

```bash
tekhton --diagnose
```

This reads the last run's logs, reports, and state files to determine:

- **What failed** — Which stage, which agent, what error
- **Why it failed** — Error classification (transient, configuration, code, quota)
- **How to fix it** — Specific recovery steps

## Diagnostic Rules

### Resilience-Arc Classifications (M133)

The diagnose layer ships five specialised classifications for the resilience-arc
failure modes (m126–m132). Each is more specific than the generic `BUILD_FAILURE`
or `MAX_TURNS_EXHAUSTED` and is matched ahead of those rules in the registry.

#### `UI_GATE_INTERACTIVE_REPORTER`

**Symptom:** The UI gate (`UI_TEST_CMD`) timed out because Playwright opened
an interactive HTML reporter (`reporter: 'html'`) that never returns.

**Fires on:** `LAST_FAILURE_CONTEXT.json` `primary_cause.signal =
ui_timeout_interactive_report` or `classification = UI_INTERACTIVE_REPORTER`
(both `high` confidence); raw-log evidence in `BUILD_RAW_ERRORS_FILE` or
`.claude/logs/` matching `Serving HTML report at` / `Press Ctrl+C to quit`
(`medium` confidence); RUN_SUMMARY.json correlation of
`primary_signal=ui_timeout_interactive_report` with
`route_taken=retry_ui_gate_env` (`medium` confidence).

**Recovery:** Patch the Playwright config to `reporter: process.env.CI ?
'dot' : 'html'`, or use `CI=1` as a no-source-edit workaround.

#### `BUILD_FIX_EXHAUSTED`

**Symptom:** The m128 build-fix continuation loop spent its budget without
recovering. Distinct from generic `BUILD_FAILURE`; ordered ahead of it.

**Fires on:** `RUN_SUMMARY.json` `build_fix_stats.outcome = exhausted` or
`no_progress` with `attempts >= 2`; `BUILD_FIX_REPORT_FILE` with multiple
`## Attempt` sections; or `LAST_FAILURE_CONTEXT.json` `secondary_cause.signal
= build_fix_budget_exhausted`. Required guard: at least one of
`BUILD_ERRORS_FILE` or `BUILD_RAW_ERRORS_FILE` must be non-empty in the
current run, so a stale historical report does not produce a false positive.

**Recovery:** Read `${BUILD_FIX_REPORT_FILE}` for the per-attempt postmortem
and `${BUILD_ERRORS_FILE}` for the underlying errors. Consider raising
`BUILD_FIX_MAX_ATTEMPTS` or `BUILD_FIX_TOTAL_TURN_CAP` for harder bugs.

#### `PREFLIGHT_INTERACTIVE_CONFIG`

**Symptom:** Preflight detected an interactive Playwright reporter
configuration but the gate-level evidence was not strong enough for
`UI_GATE_INTERACTIVE_REPORTER`. Fallback, not preferred match.

**Fires on:** `RUN_SUMMARY.json` `preflight_ui.interactive_config_detected =
true` and `reporter_auto_patched = false`; `PREFLIGHT_REPORT.md` containing
the m131-frozen heading `UI Config (Playwright) — html reporter` with a
fail entry; or `LAST_FAILURE_CONTEXT.json` `classification =
PREFLIGHT_INTERACTIVE_CONFIG` / `primary_cause.signal =
ui_interactive_config_preflight`.

**Recovery:** Apply the manual config fix or enable
`PREFLIGHT_UI_CONFIG_AUTO_FIX=true` and re-run.

#### `MIXED_UNCERTAIN_CLASSIFICATION`

**Symptom:** The build classifier could not confidently identify a single
cause — some signals looked like code errors, others looked environmental.

**Fires on:** `LAST_FAILURE_CONTEXT.json` `classification = MIXED_UNCERTAIN`
or `primary_cause.signal = mixed_uncertain_classification`; or
`RUN_SUMMARY.json` `causal_context.primary_signal =
mixed_uncertain_classification`. Always emitted at `low` confidence — when
the system itself is uncertain, advice should bias toward inspection rather
than automation.

**Recovery:** Inspect `${BUILD_RAW_ERRORS_FILE}` first. Look for the FIRST
causal error, not the last cascade. If the first failure looks
environmental, re-run preflight.

#### `MAX_TURNS_ENV_ROOT`

**Symptom:** `_rule_max_turns` matched but the m129 v2 schema shows the
primary cause is non-agent (typically `ENVIRONMENT/test_infra`). Max-turns
was the cascading symptom, not the root cause.

**Fires on:** Same triggers as `MAX_TURNS_EXHAUSTED` (`LAST_FAILURE_CONTEXT.json`
`category=AGENT_SCOPE/subcategory=max_turns`, or
`PIPELINE_STATE.md` Exit Reason / Notes max-turns markers) **plus** a
schema-v2 primary cause with category != `AGENT_SCOPE`. v1 fixtures (no
`schema_version`) and AGENT_SCOPE primaries fall through to
`MAX_TURNS_EXHAUSTED`.

**Recovery:** Adding more turns or splitting scope is unlikely to help
until the root cause is fixed. Read `LAST_FAILURE_CONTEXT.json`, re-run
preflight if the failure looks environmental, then resume from coder.

### Build Gate Failure

**Symptom:** Pipeline stops after coder stage with build errors.

**Recovery:**

1. Check `BUILD_ERRORS.md` for the specific errors
2. Verify `BUILD_CHECK_CMD` in `pipeline.conf` is correct
3. If the build-fix agent couldn't resolve it, fix manually and resume:
   ```bash
   tekhton --start-at review "Your task"
   ```

### Review Cycle Exhaustion

**Symptom:** Pipeline stops after max review cycles with unresolved issues.

**Recovery:**

1. Read `REVIEWER_REPORT.md` for the remaining issues
2. Fix the issues manually
3. Resume from the tester stage:
   ```bash
   tekhton --start-at tester "Your task"
   ```

### Turn Exhaustion

**Symptom:** Agent runs out of turns mid-task.

**Recovery:**

- If `CONTINUATION_ENABLED=true` (default), Tekhton auto-continues
- If continuation also exhausted, increase turn limits:
  ```bash
  # In pipeline.conf
  CODER_MAX_TURNS=80    # Up from default 50
  ```
- For milestone mode, use `MILESTONE_CODER_MAX_TURNS`

### Quota / API Errors

**Symptom:** Agent fails with API rate limit or quota errors.

**Recovery:**

- Wait for quota to refresh (Tekhton auto-pauses if configured)
- Set `USAGE_THRESHOLD_PCT` to pause proactively before hitting limits
- Resume: `tekhton` (with no arguments, it offers to resume)

### Null Run

**Symptom:** Agent completes but produces no meaningful changes.

**Recovery:**

- The task may be too vague — make it more specific
- Check if `INTAKE_REPORT.md` flagged clarity issues
- For milestones, check if acceptance criteria are clear enough

### Security Block

**Symptom:** Pipeline blocks on security findings.

**Recovery:**

1. Read `SECURITY_REPORT.md` for the findings
2. Fix the issues manually, or:
3. Add waivers to `SECURITY_WAIVER_FILE` for accepted risks
4. Resume: `tekhton --start-at review "Your task"`

## Failure Context Schema (v2)

Tekhton writes `LAST_FAILURE_CONTEXT.json` after every failed run so
`--diagnose` can analyze it without re-reading the entire causal log. Since
M129 the file uses **schema v2** with explicit primary/secondary cause slots:

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

- **Primary cause** = root cause, the thing that started the failure.
- **Secondary cause** = symptom observed on the way out (the cascading
  effect). Present only when the failing stage saw the downstream effect
  rather than the root cause.
- Top-level `category` / `subcategory` mirror the secondary slot when set,
  or the legacy `AGENT_ERROR_*` env vars when no slot is populated. They
  are never emitted as empty strings.

The writer always emits **one key per line** for nested cause objects.
Downstream parsers (m130 routing, m132 RUN_SUMMARY, m133 rules) use
`grep -oP` line scans, not `jq`, so the pretty-print contract is part of
the schema.

### Signal Vocabulary

m129 owns the slot shape; specific signal/source values are pinned by the
following table so all stages emit a stable vocabulary:

| Slot | Signal | Source | Set by | Read by |
|------|--------|--------|--------|---------|
| primary | `ui_timeout_interactive_report` | `build_gate` | m126 (UI gate fast-fail) | m130 (`retry_ui_gate_env`), m133 |
| primary | `mixed_uncertain_classification` | `build_gate` | m127 (low-confidence classifier) | m133 (`_rule_mixed_classification`) |
| primary | `ui_interactive_config_preflight` | `preflight` | m131 (config audit fail) | m133 (`_rule_preflight_interactive_config`) |
| secondary | `build_fix_budget_exhausted` | `coder_build_fix` | m128 (continuation loop give-up) | m132, m133 |
| secondary | `max_turns` (subcategory) | `<stage>_agent` | any stage hitting `AGENT_SCOPE/max_turns` | m130, m133 |

### Reading the Schema in Diagnose

`--diagnose` populates module state with this fallback order:

1. v2 `primary_cause` / `secondary_cause` nested objects, when present.
2. Top-level alias `category` / `subcategory` keys (writer compat layer).
3. Legacy `AGENT_ERROR_*` env vars (handled by individual rules).

When primary cause is non-agent (e.g. ENVIRONMENT) and secondary is
`max_turns`, `_rule_max_turns` annotates the suggestion with a "secondary
symptom" note pointing at the primary cause. M133 fully replaces this with
a dedicated `MAX_TURNS_ENV_ROOT` classification.

## When to Ask for Help

If `--diagnose` doesn't resolve the issue:

- Check the full agent log in `.claude/logs/` for the raw output
- File an issue at the [Tekhton repository](https://github.com/GeoffGodwin/tekhton/issues)
  with the diagnostic output

## What's Next?

- [Common Errors](common-errors.md) — Specific error messages and fixes
- [FAQ](faq.md) — Frequently asked questions
