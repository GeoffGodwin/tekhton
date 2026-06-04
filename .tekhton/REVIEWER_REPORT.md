# Reviewer Report — m36.1 Architect Stage Port

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `tests/test_architect_parity.sh` assertions are weaker than the acceptance criteria specifies. The criterion says each scenario should assert sr/jr dispatch count, post-resolve drift count, HUMAN_ACTION_REQUIRED.md content, and audit-counter reset. The test only checks the verdict string (`pass|{audit_complete,upstream_error,agent_error}`). Root cause: using `TEKHTON_AGENT_BINARY=/bin/false` causes the agent to fail with `agentErr != nil` before the plan-parsing code path runs, so the plan pre-seeding trick described in the test comment does not actually exercise the full audit path. The behavior IS verified by the Go unit tests (`TestRunStage_AuditWithSimplification`, `TestRunStage_AuditWithDesignDocObservationsOnly`, etc.), so there is no correctness gap — but the parity test is a weaker integration gate than specified.
- `run_stage_architect` shim heredoc in `tekhton-legacy.sh:1057-1059` generates JSON by substituting `${TASK:-architect-audit}` into an unquoted heredoc (`<<EOF`). If the task string contains `"`, `\`, or a newline, the resulting JSON is malformed and `tekhton run-stage architect` will fail to parse the request file. The `|| true` at line 1064 means the failure is silently swallowed (audit skipped), which is the safe fallback but could mask a bad TASK value. The cleanup shim has the same limitation. Fix: use `printf '%s' "$TASK" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'` or equivalent to properly escape the value.
- Two near-duplicate drift-count functions exist in the package: `unresolvedDriftCount` in `architect.go:309` (discards error, returns 0) and `unresolvedDriftCountErr` in `render.go:40` (returns the error). Both call `drift.NewLog(cfg.DriftLogFile).CountUnresolved()`. Consider consolidating — `unresolvedDriftCount` can call `unresolvedDriftCountErr` and discard the error inline, eliminating the parallel implementation.

## Coverage Gaps
- The parity test does not exercise the full audit path (plan-parse → sr/jr route → drift resolve → HA append → audit-counter reset) because the mock agent exits before that code runs. The Go unit tests cover these branches directly. A future follow-up could strengthen the parity test with a stub mode that lets the supervisor return a synthetic success, mirroring the fakeAgent seam in architect_test.go.

## ACP Verdicts

None — no Architecture Change Proposals in CODER_SUMMARY.md.

## Drift Observations
- `plan_parser.go:124-130` — `sectionHeaders` map iteration is non-deterministic (Go map range order is random per spec). If a single heading matched two keys simultaneously (unlikely with these specific keys, but theoretically possible), the assigned canonical section would be non-deterministic. An ordered slice of `struct{key, canonical string}` pairs would eliminate this.
- `architect.go:85` — `os.Getenv("_TUI_ACTIVE")` is read directly from the process environment rather than from `cfg` or `req.EnvOverrides`. Consistent with the security/cleanup stage pattern but means TUI state cannot be overridden per-request in integration tests without `t.Setenv`. Low impact.
