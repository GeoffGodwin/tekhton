## Test Audit Report

### Audit Summary
Tests audited: 2 files, ~19 shell test sections + 4 Go test functions
Verdict: PASS

### Findings

#### COVERAGE: Archive retention assertion is one count too lenient
- File: tests/test_causal_log.sh:148
- Issue: Test seeds 5 stale archives, sets `CAUSAL_LOG_RETENTION_RUNS=2`, calls `archive_causal_log`, then asserts `remaining -le 3`. With retention=2 the implementation prunes to exactly 2 files, so the assertion passes — but an off-by-one bug that retained 3 archives would also pass silently. The bound should track the config variable.
- Severity: MEDIUM
- Action: Change `[[ "$remaining" -le 3 ]]` to `[[ "$remaining" -le "$CAUSAL_LOG_RETENTION_RUNS" ]]`.

#### COVERAGE: Go test file covers only the `init` subcommand
- File: cmd/tekhton/causal_test.go
- Issue: Four tests cover `newCausalInitCmd()` thoroughly (creates dirs, no-truncate, missing-path error, runs/ subdir). The `newCausalEmitCmd()`, `newCausalArchiveCmd()`, and `newCausalStatusCmd()` CLI wiring — and the `lastEventID()` helper — have no direct Go-level tests in this file. The `lastEventID()` scanner is exercised only indirectly through the bash fallback path in `tests/test_causal_log.sh`.
- Severity: MEDIUM
- Action: Add Go tests for `newCausalEmitCmd` (emits to a temp file, prints assigned ID on stdout), `newCausalArchiveCmd` (archive file created in runs/), and `lastEventID` (returns last id, returns empty for empty file, returns empty for missing file). These belong in `cmd/tekhton/causal_test.go`.

#### COVERAGE: Bash fallback of `_last_event_id` not tested against an empty log file
- File: tests/test_causal_log.sh:217-228
- Issue: The bash-fallback branch of the `causal status` test covers a nonexistent file (lines 224-228) but not an empty one (file present, zero bytes). The two cases take different paths: nonexistent returns early via `[[ ! -f ]]`; empty exercises the `tail | grep | sed` pipeline. The Go binary-present branch does test the empty-file case (lines 213-216). The bash fallback's empty-file behavior is unconfirmed.
- Severity: LOW
- Action: In the bash-fallback `else` block, add: create a zero-byte temp log, call `_last_event_id`, assert result is empty.

### Notes on Shell Orphan Warnings

All STALE-SYM entries in the audit context (`:`, `cd`, `dirname`, `echo`, `grep`, `head`, `ls`, `mkdir`, `mktemp`, `pwd`, `rm`, `seq`, `set`, `source`, `tail`, `trap`, `true`, `wc`) are standard shell builtins and system utilities, not missing codebase symbols. These are confirmed false positives from the orphan detector and require no action.

### Notes on Assertion Honesty

All assertions in both files test real behavior derived from actual function calls. No always-pass or hard-coded synthetic assertions were found:
- ID format assertions (`pipeline.001`, `coder.001`, `coder.002`, `st.002`) match the `%s.%03d` format produced by both the bash fallback (`_causal_fallback_next_id`) and the Go writer (`FormatEventID` via `atomic.Int64.Add(1)`).
- JSON structure assertions match the field order and escaping rules in `proto.CausalEventV1.MarshalLine()` and the bash `printf` fallback exactly.
- The `no-truncate` test in `causal_test.go` pins file content byte-for-byte before and after init, directly validating the resume-semantics constraint from the Architecture Change Proposals.
- The `events_for_milestone`, `events_by_type`, `trace_cause_chain`, `trace_effect_chain`, and `cause_chain_summary` assertions are exercised against logs built during the test run — not pre-seeded fixed files.

### Notes on Test Isolation

Both test files have clean isolation: `tests/test_causal_log.sh` uses `mktemp -d` with an EXIT trap; `cmd/tekhton/causal_test.go` uses `t.TempDir()` throughout. No mutable project files, pipeline logs, or run artifacts are read without a controlled copy. The `causal status` section explicitly writes its own two-event fixture rather than inheriting state from earlier in the script — good defensive practice.
