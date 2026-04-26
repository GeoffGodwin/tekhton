# M133 - Diagnose Rule Enrichment for Resilience Arc Failure Modes

<!-- milestone-meta
id: "133"
status: "pending"
-->
<!-- PM-tweaked: 2026-04-25 -->

## Overview

Milestones m126–m132 make Tekhton materially better at detecting and
classifying resilience-arc failures, but `tekhton --diagnose` still mostly
reports the old coarse classes:

| Failure mode | Arc source | Current diagnose result | Desired result |
|---|---|---|---|
| Interactive Playwright reporter timeout | m126 + m131 | `BUILD_FAILURE` or `MAX_TURNS_EXHAUSTED` | `UI_GATE_INTERACTIVE_REPORTER` |
| Build-fix loop exhausted / no progress | m128 | generic `BUILD_FAILURE` | `BUILD_FIX_EXHAUSTED` |
| Preflight detected interactive reporter config before the gate ran | m131 + m132 | generic `BUILD_FAILURE` / `UNKNOWN` | `PREFLIGHT_INTERACTIVE_CONFIG` |
| Mixed-uncertain build classification | m127 + m130 | generic build or unknown guidance | `MIXED_UNCERTAIN_CLASSIFICATION` |
| Max-turns was only the symptom; root cause was env/test infra | m129 + m130 | `MAX_TURNS_EXHAUSTED` with "task too large" advice | `MAX_TURNS_ENV_ROOT` |

This milestone is intentionally diagnose-only. It must not change gate
behaviour, preflight behaviour, failure-context writing, or recovery routing.
It consumes the artifacts/contracts already established by m126–m132 and turns
them into more specific user guidance.

## Scope Boundary

M133 adds four new diagnose rules and upgrades one existing rule:

1. `_rule_ui_gate_interactive_reporter`
2. `_rule_build_fix_exhausted`
3. `_rule_preflight_interactive_config`
4. `_rule_mixed_classification`
5. Upgrade `_rule_max_turns` so it can emit `MAX_TURNS_ENV_ROOT`

M133 does **not** add new config vars, new runtime artifacts, or new causal-log
events. If a needed signal is absent from the contracts frozen by m128–m132,
that is a problem for the earlier milestone, not a reason to widen M133.

## Design

### Goal 1 - Keep the implementation local to the diagnose layer

Primary rule changes belong in `lib/diagnose_rules.sh`.
Secondary / long-tail rule changes belong in `lib/diagnose_rules_extra.sh`.

Do **not** widen `lib/diagnose.sh` just to cache more JSON fields unless the
implementation becomes unreadable without it. The current diagnose contract is
already sufficient:

- `_read_diagnostic_context` populates pipeline stage, task, outcome,
  review-cycle count, `_DIAG_LAST_CLASSIFICATION`, and `_DIAG_EXIT_REASON`.
- Rules are already allowed to parse `LAST_FAILURE_CONTEXT.json` and
  `RUN_SUMMARY.json` directly.

That keeps M133 reviewable and avoids a cross-file refactor whose only benefit
would be minor grep deduplication.

### Goal 2 - New primary rule: `_rule_ui_gate_interactive_reporter`

**Location:** `lib/diagnose_rules.sh`

**Order:** first in `DIAGNOSE_RULES`, before `_rule_build_failure` and before
`_rule_max_turns`. This rule is the most specific diagnose outcome in the arc.

**Purpose:** identify the case where the UI gate timed out because Playwright
opened an interactive HTML reporter (`reporter: 'html'`) or equivalent.

**Detection sources** (highest-confidence first):

1. `LAST_FAILURE_CONTEXT.json` schema v2:
   `primary_cause.signal = ui_timeout_interactive_report`
2. `LAST_FAILURE_CONTEXT.json` schema v1/v2:
   `classification = UI_INTERACTIVE_REPORTER`
3. Current-run raw log evidence in either `${BUILD_RAW_ERRORS_FILE}` or a file
   under `.claude/logs/` containing either:
   - `Serving HTML report at`
   - `Press Ctrl+C to quit`
4. `RUN_SUMMARY.json` showing both:
   - `causal_context.primary_signal = "ui_timeout_interactive_report"`
   - `recovery_routing.route_taken = "retry_ui_gate_env"`

**Confidence:**

- `high` for failure-context signal or classification
- `medium` for raw-log-only or summary-only matches

**Suggestions must include:**

- the concrete Playwright config fix when a config file exists
- a no-source-edit workaround (`CI=1`)
- a normal rerun path (`tekhton --complete --milestone ...`)

**Implementation notes:**

- Detect config files in this order:
  `playwright.config.ts`, `playwright.config.js`, `playwright.config.mjs`,
  `playwright.config.cjs`
- If the config is already CI-guarded (`process.env.CI ? 'dot' : 'html'`), do
  not tell the user to make the same edit again; say the config already looks
  patched and the failure may have come from stale artifacts or an alternate
  config surface.
- This rule should preempt both generic build failure and generic max-turns.

### Goal 3 - New primary rule: `_rule_build_fix_exhausted`

**Location:** `lib/diagnose_rules.sh`

**Order:** before `_rule_build_failure`. The exhausted build-fix loop is a more
specific explanation of a build failure, so it cannot sit after the generic
rule.

**Purpose:** distinguish "build failed and Tekhton already spent its build-fix
budget" from ordinary build failures.

**Detection sources:**

1. `${BUILD_FIX_REPORT_FILE}` exists and reports `outcome: exhausted` or
   `outcome: no_progress`
2. `RUN_SUMMARY.json` has:
   - `build_fix_stats.outcome = "exhausted"` or `"no_progress"`
   - `build_fix_stats.attempts >= 2`
3. `LAST_FAILURE_CONTEXT.json` secondary signal is
   `build_fix_budget_exhausted`

**Required guard:** only fire if the run still has actual build-failure
artifacts, meaning at least one of these is non-empty:

- `${BUILD_ERRORS_FILE}`
- `${BUILD_RAW_ERRORS_FILE}`

That guard prevents false positives when a historical report exists but the
current run passed.

**Suggestions must include:**

- where to read the report: `${BUILD_FIX_REPORT_FILE}`
- where to read the build errors: `${BUILD_ERRORS_FILE}`
- the two knobs that materially change behaviour:
  `BUILD_FIX_MAX_ATTEMPTS` and `BUILD_FIX_MAX_TURNS_PER_ATTEMPT`

**Contract note:** use `${BUILD_FIX_REPORT_FILE}` from the artifact defaults.
Do not hardcode `.tekhton/BUILD_FIX_REPORT.md`; m128 explicitly froze the
artifact-path variable for this reason.

### Goal 4 - New primary rule: `_rule_preflight_interactive_config`

**Location:** `lib/diagnose_rules.sh`

**Order:** after `_rule_ui_gate_interactive_reporter`, before
`_rule_build_failure`.

**Purpose:** diagnose the case where preflight already found an interactive
Playwright reporter configuration, but there is not enough gate-level evidence
for `_rule_ui_gate_interactive_reporter` to fire.

This is the fallback, not the preferred match.

**Detection sources:**

1. `RUN_SUMMARY.json` has:
   - `preflight_ui.interactive_config_detected = true`
   - `preflight_ui.reporter_auto_patched = false`
2. `${TEKHTON_DIR}/PREFLIGHT_REPORT.md` contains the m131-frozen heading text
   for the fail entry:
   `UI Config (Playwright) — html reporter`
3. `LAST_FAILURE_CONTEXT.json` classification or signal explicitly marks the
   preflight interactive-config path, if such a signal is present

**Suggestions must include:**

- the manual config change (`reporter: 'html'` -> CI-guarded form)
- the config knob `PREFLIGHT_UI_CONFIG_AUTO_FIX=true`
- a rerun path after enabling the auto-fix

**Important:** this rule exists because m131 and m132 already froze the
preflight env-var / summary contracts. It must consume those contracts as-is.
Do not rename fields, reinterpret booleans, or require extra m131 output.

### Goal 5 - New secondary rule: `_rule_mixed_classification`

**Location:** `lib/diagnose_rules_extra.sh`

**Order:** after `_rule_stuck_loop`, before `_rule_turn_exhaustion`.

**Purpose:** give a cautious explanation when the underlying failure was tagged
`mixed_uncertain` by the resilience arc and therefore does not deserve strong,
single-cause advice.

**Detection sources:**

1. `LAST_FAILURE_CONTEXT.json` contains either:
   - `classification = MIXED_UNCERTAIN`
   - `primary_cause.signal = mixed_uncertain_classification`
2. `RUN_SUMMARY.json` `error_classes_encountered` contains either
   `mixed_uncertain` or `MIXED_UNCERTAIN`

**Confidence:** always `low`

**Suggestions should bias toward inspection, not automation:**

- inspect `${BUILD_RAW_ERRORS_FILE}` first
- look for the first causal error, not the last cascade
- re-run preflight if the first failure smells environmental

This rule must not over-claim. A mixed classification means the system itself
was uncertain.

### Goal 6 - Upgrade `_rule_max_turns` to understand env-root failures

Do **not** create a separate `_rule_max_turns_env_root` rule. The existing
`_rule_max_turns` should stay the canonical owner of max-turns detection and
branch its message based on v2 cause context when available.

**Behaviour:**

- If max-turns matched and the primary cause is absent or is `AGENT_SCOPE`,
  keep today's behaviour and emit `MAX_TURNS_EXHAUSTED`.
- If max-turns matched and `LAST_FAILURE_CONTEXT.json` schema v2 shows a
  non-agent primary cause (for this arc, typically `ENVIRONMENT/test_infra`),
  emit `MAX_TURNS_ENV_ROOT` instead.

**Env-root message requirements:**

- explicitly say max-turns was the secondary symptom
- explicitly say adding more turns or splitting scope is unlikely to help
- point the user to the root-cause artifact (`LAST_FAILURE_CONTEXT.json`,
  preflight, or the relevant config/log artifact)

**Backward compatibility:** v1 failure-context fixtures must still classify as
`MAX_TURNS_EXHAUSTED`.

### Goal 7 - Rule registry ordering

After M133, the rule order should be:

```bash
DIAGNOSE_RULES=(
    "_rule_ui_gate_interactive_reporter"
    "_rule_preflight_interactive_config"
    "_rule_build_fix_exhausted"
    "_rule_build_failure"
    "_rule_max_turns"
    "_rule_review_loop"
    "_rule_security_halt"
    "_rule_intake_clarity"
    "_rule_quota_exhausted"
    "_rule_stuck_loop"
    "_rule_mixed_classification"
    "_rule_turn_exhaustion"
    "_rule_split_depth"
    "_rule_transient_error"
    "_rule_test_audit_failure"
    "_rule_migration_crash"
    "_rule_version_mismatch"
    "_rule_unknown"
)
```

Rationale:

- the three new primary rules must beat generic build failure
- `max_turns` still beats the older turn-exhaustion fallback
- `mixed_classification` remains a secondary/low-confidence rule
- `_rule_unknown` remains last

### Goal 8 - Tests

Add a focused new test file instead of further bloating `tests/test_diagnose.sh`:

- `tests/test_diagnose_rules_resilience.sh`

That file should own the new resilience-arc fixtures. Keep
`tests/test_diagnose.sh` for baseline rule-engine invariants and ordering.

#### Required resilience tests

1. Interactive reporter fires from `primary_cause.signal=ui_timeout_interactive_report`
2. Interactive reporter fires from raw log evidence only
3. Interactive reporter does not fire on unrelated timeout text
4. Build-fix exhausted fires from `${BUILD_FIX_REPORT_FILE}`
5. Build-fix exhausted does not fire when both build-error artifacts are empty
6. Build-fix exhausted `no_progress` variant includes the no-progress guidance
7. Preflight interactive config fires from `RUN_SUMMARY.json preflight_ui.*`
8. Mixed classification fires at low confidence
9. Max-turns env-root emits `MAX_TURNS_ENV_ROOT`
10. Max-turns v1 fixture remains `MAX_TURNS_EXHAUSTED`
11. Full-chain priority test: interactive reporter beats build failure
12. Full-chain priority test: build-fix exhausted beats build failure

#### Existing test updates

`tests/test_diagnose.sh` must be updated for:

- the new `DIAGNOSE_RULES` length
- the first few rule-order assertions

Do not try to cram all new fixtures into the legacy file.

## Files Modified

| File | Change |
|---|---|
| `lib/diagnose_rules.sh` | Add `_rule_ui_gate_interactive_reporter`, `_rule_build_fix_exhausted`, `_rule_preflight_interactive_config`; upgrade `_rule_max_turns`; update registry ordering. |
| `lib/diagnose_rules_extra.sh` | Add `_rule_mixed_classification` after `_rule_stuck_loop`. |
| `tests/test_diagnose.sh` | Update rule-count and rule-order assertions only. |
| `tests/test_diagnose_rules_resilience.sh` | New focused resilience diagnose fixtures and assertions. |
| `docs/troubleshooting/diagnose.md` | Document the five resilience-arc diagnose outcomes and when each one fires. |

## Acceptance Criteria

- [ ] `--diagnose` on a v2 failure-context fixture with
      `primary_cause.signal = ui_timeout_interactive_report` produces
      `UI_GATE_INTERACTIVE_REPORTER`.
- [ ] `--diagnose` on a raw-log-only fixture containing `Serving HTML report at`
      or `Press Ctrl+C to quit` produces `UI_GATE_INTERACTIVE_REPORTER` at
      `medium` confidence.
- [ ] `--diagnose` on a build-fix exhausted fixture produces
      `BUILD_FIX_EXHAUSTED`, not `BUILD_FAILURE`.
- [ ] `--diagnose` on a preflight-only interactive-config fixture produces
      `PREFLIGHT_INTERACTIVE_CONFIG`.
- [ ] `--diagnose` on a mixed-uncertain fixture produces
      `MIXED_UNCERTAIN_CLASSIFICATION` at `low` confidence.
- [ ] `--diagnose` on a max-turns fixture whose schema-v2 primary cause is
      `ENVIRONMENT/test_infra` produces `MAX_TURNS_ENV_ROOT`, not
      `MAX_TURNS_EXHAUSTED`.
- [ ] A v1 `LAST_FAILURE_CONTEXT.json` fixture with flat
      `category=AGENT_SCOPE`, `subcategory=max_turns` still produces
      `MAX_TURNS_EXHAUSTED`.
- [ ] `_rule_build_fix_exhausted` is ordered before `_rule_build_failure`.
- [ ] `_rule_ui_gate_interactive_reporter` is ordered before
      `_rule_build_failure` and `_rule_max_turns`.
- [ ] `tests/test_diagnose_rules_resilience.sh` passes all required cases.
- [ ] Existing `tests/test_diagnose.sh` remains green after its rule-order
      assertions are updated.
- [ ] `shellcheck` is clean for the modified shell files.

## Watch For

- **Use the frozen artifact vars, not hardcoded paths.** m128 and the artifact
  defaults already define `BUILD_FIX_REPORT_FILE`, `BUILD_ERRORS_FILE`, and
  `BUILD_RAW_ERRORS_FILE`. Hardcoding `.tekhton/...` here creates silent drift
  on any project whose artifact paths moved with `TEKHTON_DIR`.
- **`RUN_SUMMARY.json` field names are already frozen by m132.** The keys this
  milestone may rely on are `causal_context.primary_signal`,
  `causal_context.primary_category`, `causal_context.primary_subcategory`,
  `build_fix_stats.*`, `preflight_ui.*`, and `recovery_routing.route_taken`.
  Do not invent alternate spellings such as `primary_cause.signal` inside
  `RUN_SUMMARY.json`; that object shape belongs to `LAST_FAILURE_CONTEXT.json`.
- **Do not put `_rule_build_fix_exhausted` after `_rule_build_failure`.** That
  ordering bug would make the new rule effectively dead code whenever the build
  artifact exists, which is exactly when it is supposed to help.
- **Do not widen `lib/diagnose.sh` unless clearly necessary.** The diagnose
  reader does not need five more `_DIAG_*` globals just to land M133. Local
  parsing inside the new rules is acceptable and keeps the milestone smaller.
- **Respect the m129 pretty-print contract.** `LAST_FAILURE_CONTEXT.json`
  remains line-oriented, multi-line JSON because m130/m132/m133 all parse it
  with shell text tools. M133 is a consumer of that contract, not an excuse to
  change it.
- **The m131 preflight names are public interface.** `PREFLIGHT_UI_*` env vars,
  the `preflight_ui.*` summary fields, and the fail-entry wording for
  `UI Config (Playwright) — html reporter` are already seeded forward. Consume
  them byte-for-byte.
- **Keep confidence conservative.** Only failure-context signal/classification
  matches deserve `high`. Summary-only or raw-log-only matches should stay
  `medium`, and mixed classification must stay `low`.
- **This milestone is diagnose-only.** If the implementation starts modifying
  gate code, preflight code, failure-context writers, or routing code, it has
  drifted out of scope.

## Seeds Forward

- **m134 - Resilience Arc Integration Test Suite.** M134 should treat these
  five classifications as the diagnose-layer contract for the arc. Its diagnose
  scenarios should reuse M133's fixtures rather than invent a second vocabulary.
- **m135 - Artifact Lifecycle.** M133 is read-only with respect to artifacts,
  but it depends on stable names and retention of `${BUILD_FIX_REPORT_FILE}` and
  preflight artifacts. If m135 changes retention logic, it must not change the
  artifact names or report headings M133 matches.
- **m136 - Config Defaults & Validation.** M133 introduces no new config. Its
  suggestions may mention existing knobs such as `PREFLIGHT_UI_CONFIG_AUTO_FIX`,
  `BUILD_FIX_MAX_ATTEMPTS`, and `BUILD_FIX_MAX_TURNS_PER_ATTEMPT`, but it must
  not require new defaults or validation work from m136.
- **m137 - V3.2 Migration.** Because M133 adds diagnose-only behaviour, there
  should be no migration burden beyond documentation. If the implementation ends
  up requiring new config keys or new artifacts, it has violated scope.
- **m138 - CI Environment Auto-Detection.** CI auto-detection reduces how often
  the interactive-reporter failure occurs, but when it does occur M133's
  `UI_GATE_INTERACTIVE_REPORTER` guidance must still be correct. Keep the
  wording CI-aware: `CI=1` is both a workaround and, in later milestones, a
  likely automatically supplied condition.
- **Future diagnose/dashboard polish.** These classifications are suitable for
  future dashboard summarisation or recurring-failure aggregation. Keep the
  output tokens stable: `UI_GATE_INTERACTIVE_REPORTER`,
  `BUILD_FIX_EXHAUSTED`, `PREFLIGHT_INTERACTIVE_CONFIG`,
  `MIXED_UNCERTAIN_CLASSIFICATION`, and `MAX_TURNS_ENV_ROOT` should be treated
  as public diagnose vocabulary once this milestone lands.