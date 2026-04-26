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
