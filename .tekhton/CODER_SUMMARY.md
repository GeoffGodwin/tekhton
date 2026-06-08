## Files Declared

- `internal/provider/provider.go` (created) — `Provider` interface, `ToolSchema` placeholder, `Request`, `Result`, `Outcome` type with 7 constants.
- `internal/provider/event.go` (created) — `Event` struct, `EventKind` type with 7 constants. Documents channel-close ownership contract.
- `internal/provider/provider_test.go` (created) — Interface method-count/name assertions, Outcome/EventKind constant uniqueness, assignability smoke test.
- `internal/provider/claude/claude.go` (created) — `Provider` struct wrapping `supervisorRunner` interface; `New()`, `Name()`, `RunAgent()`, `translateResult()`, `translateOutcome()`, `writePromptFile()`, `labelOrDefault()`. Compile-time assertions for both `supervisorRunner` and `provider.Provider` satisfaction.
- `internal/provider/claude/claude_test.go` (created) — Unit tests: Name, nil-request/nil-supervisor guards, streaming event sequence (TurnStart→TurnEnd→RunEnd + close), translateOutcome for NullRun/UPSTREAM/MaxTurns/Timeout, writePromptFile round-trip and cleanup, labelOrDefault.
- `internal/provider/claude/parity_test.go` (created) — `TestClaudeProvider_ParityWithDirectSupervisor` with 6 sub-tests: trivial_success, multi_turn_with_tools, upstream_error, null_run, max_turns_exhausted, context_cancelled. Fixture-backed, supervisor stubbed.
- `internal/provider/claude/testdata/trivial_success.json` (created) — exit 0, 1 turn, outcome success.
- `internal/provider/claude/testdata/multi_turn_with_tools.json` (created) — exit 0, 5 turns, outcome success.
- `internal/provider/claude/testdata/upstream_error.json` (created) — exit 1, 3 turns, UPSTREAM/api_rate_limit, transient.
- `internal/provider/claude/testdata/null_run.json` (created) — exit 1, 1 turn, AGENT_SCOPE/null_run (triggers IsNullRun).
- `internal/provider/claude/testdata/max_turns_exhausted.json` (created) — exit 0, 10 turns, turn_exhausted.
- `docs/v5-provider-seam.md` (created) — Provider interface contract, Outcome mapping table, Event contract, translation pattern, m01 non-goals. Five `##` section headings.

## Not Modified

- `internal/supervisor/` — zero changes. `git diff HEAD~ internal/supervisor/` is empty.
- `internal/stages/` — zero changes. `git diff HEAD~ internal/stages/` is empty.

## Test Results

```
ok  github.com/geoffgodwin/tekhton/internal/provider        (5 tests)
ok  github.com/geoffgodwin/tekhton/internal/provider/claude (12 tests + 6 parity sub-tests)
```

All 17 new tests pass. Pre-existing `internal/stages/intake` failure is unrelated (fails on the same base commit).

## Design Decisions

- `supervisorRunner` is an unexported interface inside the `claude` package. This lets tests inject a stub (`&Provider{Supervisor: &stubSup{}}`) without modifying the supervisor package and without exposing the internal seam.
- The Claude provider writes `req.Prompt` to a temp file before invoking the supervisor (which requires `PromptFile` path, not inline text). The file is deferred-removed before `RunAgent` returns.
- `translateOutcome` checks `IsNullRun()` before `ErrorCategory` so null-run detection (which uses exit code + turn count) is not masked by an upstream error category that may also be present.
- `RawProviderData` is populated on every successful result via `json.Marshal(v1)` — the full wire envelope for postmortem, as required by the seam contract.
