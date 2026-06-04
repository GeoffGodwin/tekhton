# Reviewer Report — m42

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `internal/preflight/orchestrator_test.go:39` — `TestNewOrchestrator_BuildsAllFiveChecks` function name and its inline comment ("production constructor registers exactly five checks") are stale; the check count is now 7. A future contributor landing another check will read the name as a test contract and be confused.
- `lib/hooks_final_checks.sh:3` — pre-existing `set -euo pipefail` in a sourced library; CLAUDE.md Rule 2 specifies sourced files in `lib/` do **not** set this (they inherit from the entry point). This predates m42 and is not introduced here, but it crossed the 300-line extraction trip and is worth noting for the next cleanup pass.

## Coverage Gaps
- `tests/test_init_test_cmd_detection.sh` does not cover the `requirements.txt`-only Python project path. The function returns `pytest` for `requirements.txt` presence, but the test exercises only `pyproject.toml` and `setup.py`. Edge-case false-positives (a `requirements.txt` in a non-test project) are uncaught.
- `lib/milestone_acceptance.sh` changes (the no-op short-circuit at lines 37–108) have no corresponding integration test. `test_preflight_noop_test_cmd.sh` exercises the helpers in isolation; the acceptance path that calls them is not exercised end-to-end.

## Drift Observations
- `internal/preflight/test_cmd.go:95` — `appendHumanActionForNoopTestCmd` appends a `HUMAN_ACTION_REQUIRED.md` entry unconditionally on every preflight invocation. Multi-milestone runs with a persistent no-op `TEST_CMD` accumulate duplicate action items for the same issue. Other preflight checks in the orchestrator share this pattern (no dedup at the write layer), so this is a systemic rather than m42-specific gap, but worth tracking.
- `lib/init_config_test_cmd.sh:73` — `_m42_test_cmd_fallback_source` does not apply the `scripts.test` / placeholder guard that `_m42_test_cmd_fallback` applies for `package.json`. The two functions are logically coupled (source is only meaningful when command is non-empty) and the caller in `init_config.sh` guards correctly with `if [[ -n "$_fallback" ]]; then`. The pairing is fragile if `_m42_test_cmd_fallback_source` is ever called independently.
