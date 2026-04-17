# Drift Log

## Metadata
- Last audit: 2026-04-17
- Runs since audit: 1

## Unresolved Observations

## Resolved
- [RESOLVED 2026-04-17] `tests/test_diagnose.sh` is 666 lines — well over the 300-line soft ceiling. This was pre-existing before M94 (M94 added ~50 lines for suite 2b). Worth tracking; the fixture/helper functions could eventually be extracted into a shared test helper.
- [RESOLVED 2026-04-17] `_rule_turn_exhaustion` in `diagnose_rules_extra.sh` reads `AGENT_SCOPE/max_turns` from the pipeline state file and is now superseded by `_rule_max_turns` whenever `LAST_FAILURE_CONTEXT.json` is present (which is the normal post-M93 path). Kept for backward-compatibility per coder note, but it is effectively dead code for post-M93 runs. Worth a comment or eventual removal.
- [RESOLVED 2026-04-17] `stages/review.sh` — 355 lines, 55 lines over the 300-line soft ceiling. Pre-existing; the single-line change in this task did not cause the overage. Candidate for extraction when the file next needs significant work.
