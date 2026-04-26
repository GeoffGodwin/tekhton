# Reviewer Report — M127 Mixed-Log Classification Hardening (Cycle 2 Re-Review)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/milestone_split_dag.sh:87`: security agent flagged `echo "$sub_block"` (flag-interpretation risk) as fixable LOW — pre-existing, out of M127 scope; follow-up with `printf '%s\n' "$sub_block"` as recommended.
- `stages/coder_buildfix.sh:160-163`: the `code_dominant|*` catch-all silently falls through to the legacy code-fix path for any unrecognized future token. Consider an explicit `*) warn ...; ;;` arm before the fall-through for forward-visibility in M128/M130.
- `lib/error_patterns_classify.sh:222`: 60% noncode confidence threshold is a magic literal. Naming it `_NONCODE_CONFIDENCE_THRESHOLD=60` at the top of the file would simplify tuning and documentation.

## Coverage Gaps
- `_bf_read_raw_errors` fallback path (BUILD_RAW_ERRORS_FILE absent, falls back to BUILD_ERRORS_FILE) has no dedicated test; the annotated-file skew risk is documented in comments but unverified by assertion.
- `_run_buildfix_routing` noncode_dominant arm: no test verifies that `write_pipeline_state` is called with `env_failure` and that `exit 1` fires. Routing token is covered but terminal orchestrator behavior for this path is not.

## ACP Verdicts

## Drift Observations
- `lib/error_patterns_classify.sh:69`: ANSI stripping uses `sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g'`. The `\x1b` hex escape is GNU sed-specific, not POSIX `sed -E`; silently fails on macOS BSD sed without a GNU shim. Low risk given Linux deployment target.
- `lib/error_patterns_classify.sh` — `load_error_patterns` is called redundantly across three exported functions. The `_EP_LOADED` guard prevents overhead, but the pattern is inconsistent with single-call usage elsewhere.
