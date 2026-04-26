# M127 - Mixed-Log Classification Hardening & Confidence-Based Routing

<!-- milestone-meta
id: "127"
status: "done"
-->

## Overview

M126 makes UI gate execution deterministic; M127 fixes the next weak
link: mixed-output classification still over-escalates to code fixes.

Today, `classify_build_errors_all` classifies per line and defaults
every unmatched line to `code|code||Unclassified build error`.
Large test outputs contain many unmatched lines (npm warnings, runner
status lines, ANSI fragments, report banners), so the presence of
even one unmatched line can force `has_only_noncode_errors` to fail,
which drives the pipeline into build-fix coder routing even when the
dominant failure is test infrastructure or environment.

The bifl-tracker incident is a canonical example: timeout-dominated UI
output with noisy unmatched lines produced a code-escalation path,
consuming build-fix turns and ending in `build_failure` without
improving root cause signal.

M127 introduces a confidence-based mixed-log classifier that:

1. Separates matched signal from unmatched noise,
2. Preserves conservative safety (real code errors still route to coder),
3. Prevents unknown/noise lines from automatically becoming code,
4. Adds deterministic routing policy based on category confidence.

This milestone depends on M53 and M54 and should run after M126 so UI
gate output is already deterministic and easier to classify.

## Design

### Goal 1 - Introduce explicit unknown classification (no implicit code fallback)

Current behavior in `lib/error_patterns.sh`:

- `classify_build_error` unmatched -> `code|code||Unclassified build error`
- `classify_build_errors_all` unmatched line -> same code fallback

Replace this with explicit unknown-class semantics for multi-line
classification while keeping single-line API backward compatibility.

Implementation detail:

1. Keep `classify_build_error` fallback as-is for backward compatibility
   with tests and legacy call sites.
2. Add new function:

```bash
# classify_build_errors_with_stats RAW_OUTPUT
# Emits machine-readable records:
# CAT|SAFETY|REMED|DIAG|MATCH_COUNT|TOTAL_MATCHED|TOTAL_LINES|UNMATCHED_LINES
```

3. In this new function, unmatched lines are counted as unknown/noise,
   not emitted as code.
4. Add helper:

```bash
# has_explicit_code_errors RAW_OUTPUT
# Returns 0 only when a line matched an explicit code-category pattern.
```

This separates true code evidence from unknown lines.

### Goal 2 - Add line pre-filtering for non-diagnostic noise

Before pattern matching, normalize and filter high-noise lines that do
not represent actionable failures.

Create helper in `lib/error_patterns.sh`:

```bash
# _is_non_diagnostic_line LINE
# returns 0 when line should be ignored for classification statistics
```

Initial filter set (regex-based, case-insensitive):

- npm/pnpm/yarn warnings unrelated to failure root cause
  (for example `npm warn`, progress counters, audit hints)
- test runner progress lines (`[1/8]`, spinner/progress updates)
- ANSI-only or whitespace-only lines
- report-serving status lines already diagnosed in M126
  (`Serving HTML report at`, `Press Ctrl+C to quit`)

Important constraint:

- Filters must not drop lines that include known failure signatures
  such as `timeout`, `error`, `failed`, `ECONNREFUSED`, `TSxxxx`.
- For safety, apply deny-list filter only after quick allow-list check
  for obvious failure terms.

### Goal 3 - Add confidence scoring for routing decisions

Add a routing helper in `lib/error_patterns.sh`:

```bash
# classify_routing_decision RAW_OUTPUT
# Outputs one token:
# code_dominant | noncode_dominant | mixed_uncertain | unknown_only
```

Scoring model (simple and deterministic):

- `matched_code_lines`: lines matching `category=code`
- `matched_noncode_lines`: lines matching env_setup/service_dep/toolchain/resource/test_infra
- `unmatched_lines`: non-filtered lines with no match
- `total_considered = matched_code_lines + matched_noncode_lines + unmatched_lines`

Decision rules:

1. If `matched_code_lines > 0` and
   `matched_code_lines >= matched_noncode_lines` -> `code_dominant`
2. If `matched_noncode_lines > 0` and
   `matched_code_lines == 0` and
   `matched_noncode_lines / total_considered >= 0.6` -> `noncode_dominant`
3. If `matched_code_lines > 0` and `matched_noncode_lines > 0` -> `mixed_uncertain`
4. If no matched lines after filtering -> `unknown_only`

These thresholds intentionally bias toward safety: any explicit code
evidence keeps code routing possible, but unknown noise alone cannot
force code routing.

Implementation note — bash has no native floating-point math. Implement
the 0.6 threshold as integer arithmetic:

```bash
(( matched_noncode_lines * 100 / total_considered >= 60 ))
```

Do not introduce a `bc` dependency in orchestration code paths.

#### Output and export contract

`classify_routing_decision` must do two things, not one:

1. Echo the routing token to stdout:
   `code_dominant | noncode_dominant | mixed_uncertain | unknown_only`.
2. Export `LAST_BUILD_CLASSIFICATION=<token>` so downstream consumers
   (M128 build-fix continuation loop, M130 causal-context recovery
   routing) can read the most recent classification without re-parsing
   build artifacts.

The export is a cross-milestone integration point. M130's
`_classify_failure` reads `${LAST_BUILD_CLASSIFICATION:-code_dominant}`
and branches on the exact four tokens above (see
`m130-causal-context-aware-recovery-routing.md`, "LAST_BUILD_CLASSIFICATION
export contract" section). Renaming the variable, changing the token
vocabulary, or skipping the export on early-return paths silently breaks
M130 — the default `code_dominant` makes M130's amendments invisible
rather than producing a loud error.

### Goal 4 - Wire confidence routing into coder build-fix branch

Update `stages/coder.sh` build-fix branch to use confidence decision,
not `has_only_noncode_errors` alone.

Proposed routing policy:

- `noncode_dominant`:
  - Skip build-fix coder
  - Write env/test-infra failure state with diagnosis summary
  - Append human action guidance

- `code_dominant`:
  - Existing behavior: run build-fix coder with filtered code errors

- `mixed_uncertain`:
  - New lightweight diagnosis step before build-fix:
    write `BUILD_ROUTING_DIAGNOSIS.md` with category counts and top
    matched diagnoses.
  - Then run build-fix coder with code-only content plus a short
    context section listing non-code categories found.

- `unknown_only`:
  - Preserve `LAST_BUILD_CLASSIFICATION=unknown_only` for downstream
    consumers and diagnostics.
  - Route through the existing bounded build-fix path so the
    pre-M127 "one retry on unresolved build errors" behavior is
    preserved.
  - Attach low-confidence guidance noting that no recognized error
    signatures were detected and manual triage may still be required if
    the retry fails.

This prevents blind code-repair attempts on clearly non-code failures
while preserving a bounded fallback when the classifier has no
recognized signal.

#### Input contract

The new routing path in `stages/coder.sh` must feed
`classify_routing_decision` the **raw** error stream — the same content
currently passed to `has_only_noncode_errors` at `stages/coder.sh:1117-1119`.
Use `BUILD_RAW_ERRORS_FILE` when present and fall back to
`BUILD_ERRORS_FILE` only when the raw file is absent (preserve the
existing precedence at `stages/coder.sh:1110-1115`).

Feeding the annotated `BUILD_ERRORS.md` to the new classifier instead
would let its own markdown headers (`## Classified as Code Error`,
`## Already Handled`, etc.) match the `code` patterns and skew the
decision toward `code_dominant` — the opposite of the M127 fix.

### Goal 5 - Keep backward compatibility for M53/M54 interfaces

Do not remove existing exported functions in M127:

- `classify_build_error`
- `classify_build_errors_all`
- `has_only_noncode_errors`

Instead:

1. Mark `has_only_noncode_errors` as legacy behavior in comments.
2. Refactor it to call the new stats helper but preserve return values
   for existing tests where practical.
3. New routing in `stages/coder.sh` uses only
   `classify_routing_decision`.

This allows incremental migration without breaking older test fixtures.

### Goal 6 - Expand test harness with real noisy fixtures

Add new fixture file derived from real incident shape:

- `tests/fixtures/ui_timeout_noisy_output.txt`

Content should include:

- Progress lines,
- npm warnings,
- Playwright timeout lines,
- report-serving lines,
- at least one unmatched non-diagnostic line.

Add tests:

1. `test_classify_routing_noncode_dominant_noisy_timeout`
   - Input fixture above
   - Expect `noncode_dominant`

2. `test_classify_routing_code_dominant_mixed`
   - Fixture with TS errors plus noise
   - Expect `code_dominant`

3. `test_classify_routing_mixed_uncertain`
   - Fixture with explicit code + explicit service_dep
   - Expect `mixed_uncertain`

4. `test_classify_routing_unknown_only`
   - Fixture with only unknown/noise lines
   - Expect `unknown_only`

5. `test_coder_stage_skips_build_fix_on_noncode_dominant`
   - Extend `tests/test_gates_bypass_flow.sh` or new integration test
   - Assert no build-fix invocation.

6. `test_coder_stage_runs_build_fix_on_code_dominant`
   - Assert build-fix invocation preserved.

7. `test_coder_stage_runs_build_fix_on_unknown_only`
  - Fixture with only unknown/noise lines
  - Assert build-fix invocation still occurs and
    `LAST_BUILD_CLASSIFICATION=unknown_only` is preserved for
    downstream consumers.

8. `test_filter_does_not_drop_failure_lines`
   - Ensure `_is_non_diagnostic_line` never suppresses lines containing
     `error`, `failed`, `timeout`, `TS[0-9]+`, `ECONNREFUSED`.

## Files Modified

| File | Change |
|------|--------|
| `lib/error_patterns.sh` | Add stats-based classifier, noise-line filter helper, explicit code-evidence helper, and confidence routing decision function. Preserve legacy APIs. **Currently 271 lines; estimated +120-160 LOC will exceed the 300-line ceiling (CLAUDE.md non-negotiable rule 8).** Plan from the start to extract the new symbols (`classify_build_errors_with_stats`, `_is_non_diagnostic_line`, `has_explicit_code_errors`, `classify_routing_decision`, plus the noise-line denylist) into a new `lib/error_patterns_classify.sh`, mirroring the existing `error_patterns_registry.sh` / `error_patterns_remediation.sh` split, and source it from `error_patterns.sh`. |
| `stages/coder.sh` | Replace binary `has_only_noncode_errors` decision with confidence-based routing policy (`code_dominant`, `noncode_dominant`, `mixed_uncertain`, `unknown_only`). |
| `tests/test_error_patterns.sh` | Add unit tests for new stats classifier, routing decisions, and filter safety constraints. |
| `tests/test_gates_bypass_flow.sh` | Extend integration assertions to validate new routing semantics in noisy mixed-output scenarios. |
| `tests/fixtures/ui_timeout_noisy_output.txt` | **New file.** Realistic noisy timeout fixture for classification/routing tests. |
| `docs/concepts/auto-remediation.md` | Update routing description to explain confidence-based mixed-log handling and unknown-only outcomes. |
| `docs/troubleshooting/common-errors.md` | Add diagnosis path for `unknown_only` classification and low-confidence fallback / manual triage workflow. |

## Acceptance Criteria

- [ ] Mixed noisy UI timeout output (including report-serving lines and npm warnings) classifies as `noncode_dominant`, not implicit code.
- [ ] Unknown/unmatched lines no longer automatically become code evidence in multi-line routing logic.
- [ ] Explicit code-pattern matches still route to `code_dominant` and invoke build-fix coder.
- [ ] `mixed_uncertain` path writes `BUILD_ROUTING_DIAGNOSIS.md` and includes both code and non-code context in build-fix prompt input.
- [ ] `unknown_only` path preserves the `unknown_only` export token and still takes the existing bounded build-fix path, with guidance that manual triage may still be required if the retry fails.
- [ ] Existing M53/M54 exported functions remain available; no call-site breakage in current pipeline.
- [ ] New fixture-driven tests pass for all four routing outcomes (`code_dominant`, `noncode_dominant`, `mixed_uncertain`, `unknown_only`).
- [ ] Existing classification tests continue to pass after migration (or, where a fixture exercised the bifl-tracker class of input that M127 explicitly fixes, the assertion has been updated to reflect the corrected behavior with a comment pointing at this milestone).
- [ ] `classify_routing_decision` exports `LAST_BUILD_CLASSIFICATION=<token>` in addition to echoing the token, with values restricted to the four-token vocabulary (`code_dominant | noncode_dominant | mixed_uncertain | unknown_only`).
- [ ] New routing in `stages/coder.sh` reads the raw error stream from `BUILD_RAW_ERRORS_FILE` (falling back to `BUILD_ERRORS_FILE` only when absent), matching the existing precedence at `stages/coder.sh:1110-1115`.
- [ ] `_is_non_diagnostic_line` applies its allow-list check (failure terms: `error`, `failed`, `timeout`, `ECONNREFUSED`, `TS[0-9]+`) **before** its deny-list check, and `test_filter_does_not_drop_failure_lines` covers the inversion case.
- [ ] If `lib/error_patterns.sh` exceeds 300 lines after the additions, the new symbols have been extracted into `lib/error_patterns_classify.sh` and sourced from `error_patterns.sh`.
- [ ] `shellcheck` clean for modified shell files.

## Watch For

- **`LAST_BUILD_CLASSIFICATION` export is a cross-milestone contract.**
  M130's `_classify_failure` (Amendment C) reads
  `${LAST_BUILD_CLASSIFICATION:-code_dominant}` and routes
  `noncode_dominant` to `save_exit`, `mixed_uncertain` to one retry then
  `save_exit`, and `code_dominant`/empty to `retry_coder_build`. Do not
  rename the variable, do not change the token vocabulary, and do not
  skip the export on early-return paths. The default-to-`code_dominant`
  fallback in M130 is for the pre-deployment window — it is not a
  silent OK to omit the export.
- **Use integer arithmetic for the 0.6 threshold.** Bash does not do
  floating-point math; write the ratio check as
  `(( matched_noncode_lines * 100 / total_considered >= 60 ))`. Do not
  introduce a `bc` dependency for orchestration code.
- **Feed the classifier the raw error stream, not the annotated
  markdown.** `BUILD_ERRORS.md` contains classification headers that
  themselves match `code` patterns. Routing must read
  `BUILD_RAW_ERRORS_FILE` (see existing precedence at
  `stages/coder.sh:1110-1115`).
- **`annotate_build_errors` is intentionally unchanged in M127.** It
  will continue to write `code` rows for unmatched lines into
  `BUILD_ERRORS.md`. Routing decisions read the new classifier, not the
  markdown. Do not refactor `annotate_build_errors` to consume the new
  stats helper as part of M127 — that is a follow-up cleanup with its
  own test exposure.
- **`has_only_noncode_errors` semantics shift.** After M127, the helper
  is driven by the stats helper rather than per-line code-fallback. The
  bifl-tracker class of input (env-only failure plus unmatched noise)
  will newly return 0 (bypass), which is the M127 fix. Some existing
  fixtures in `tests/test_gates_bypass_flow.sh` exercise this exact
  pathway — re-run that test file early; if any case now flips, update
  the assertion to reflect the corrected behavior, do not patch the
  helper to preserve the bug.
- **Allow-list before deny-list in `_is_non_diagnostic_line`.** The
  deny-list filter must run only after a quick allow-list check for
  failure terms. Inverting the order silently drops real failure signal.
- **`classify_build_error` (single-line API) is not migrated.** Its
  `code|code||Unclassified build error` fallback must remain for legacy
  callers (`filter_code_errors`, `annotate_build_errors`, M53 single-line
  tests). Only the multi-line stats path gets the new unknown semantics.
- **Decision-rule order matters.** Rule 1 (`code_dominant`) must fire
  before Rule 3 (`mixed_uncertain`) — once a line matches an explicit
  code pattern, code routing is preserved unless non-code clearly
  dominates. Inverting yields the opposite of the M127 design.
- **300-line ceiling.** `lib/error_patterns.sh` is 271 lines today;
  adding four helpers plus the noise-line denylist will exceed the
  ceiling. Plan the split into `lib/error_patterns_classify.sh` from
  the start; do not let line count creep close to the limit before
  splitting.
- **`BUILD_ROUTING_DIAGNOSIS.md` placement.** Goal 4 introduces this
  artifact on the `mixed_uncertain` path. Place it under `${TEKHTON_DIR}/`
  (alongside `BUILD_ERRORS.md`) and add a default in
  `lib/artifact_defaults.sh` so its path is configurable, not hardcoded.

## Seeds Forward

- **M128 — Build-fix continuation loop.** Reads M127's routing
  decision twice: (1) Goal 6 stops the build-fix loop early when
  routing remains `noncode_dominant` for two consecutive attempts;
  (2) per-attempt diagnostics in `BUILD_FIX_REPORT.md` are expected to
  record the routing token. Keep the token strings stable.
- **M129 — Failure context schema v2.** Will populate `primary_cause`
  and `secondary_cause` slots in `LAST_FAILURE_CONTEXT.json` from the
  M127 routing decision plus matched diagnoses. The token vocabulary
  chosen here becomes the primary-cause subcategory shorthand (for
  example `noncode_dominant` -> `ENVIRONMENT/test_infra`). Keep
  per-pattern diagnoses descriptive enough to feed an
  `LAST_FAILURE_CONTEXT.primary_cause.signal` field (e.g.
  `ui_timeout_interactive_report`, `econnrefused_dev_server`).
- **M130 — Causal-context-aware recovery routing.** Hard contract:
  M130 reads `LAST_BUILD_CLASSIFICATION` directly. Amendment C in M130
  hinges on the four-token vocabulary. Keep the export, do not rename,
  do not collapse `unknown_only` into `code_dominant` at the export
  site — M130 explicitly chose to treat `unknown_only` as
  `code_dominant` *inside* its router; that decision belongs to the
  consumer, not the producer.
- **`BUILD_ROUTING_DIAGNOSIS.md` (mixed_uncertain path).** New artifact
  introduced by Goal 4. Future milestones (notes pipeline, watchtower)
  may want to surface this; keep the schema simple — header + category
  counts + top three diagnoses — so downstream parsers stay trivial.
