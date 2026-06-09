## Test Audit Report

### Audit Summary
Tests audited: 5 files, 26 test functions (22 Go, 4 bash assertions)
Verdict: CONCERNS

### Findings

#### SCOPE: Implementation package missing — all 4 Go test files fail to compile
- File: internal/provider/codex/codex_test.go, internal/provider/codex/exec_test.go, internal/provider/codex/exit_codes_test.go, internal/provider/codex/flags_test.go
- Issue: The `internal/provider/codex/` directory contains only test files. No implementation files exist (`codex.go`, `exec.go`, `exit_codes.go`, `flags.go`). All four test files reference undefined symbols: `Provider`, `New`, `NewWithBinary`, `buildExecArgs`, `runCodex`, `interpretExitCode`. Build output: `undefined: Provider`, `undefined: New`, `undefined: NewWithBinary`, `undefined: runCodex` (13 errors). Zero test functions execute. The tester acknowledges this in TESTER_REPORT as "BUG: m07 implementation package missing."
- Severity: HIGH
- Action: Create the implementation files for the codex package. This is an implementation gap, not a test gap — the tests are correctly designed for the intended interface. The tests should not be removed or modified; the implementation must be created to satisfy them.

#### EXERCISE: Incorrect stub binary in TestProvider_RunAgent_ExitZeroSuccess — test will fail with correct implementation
- File: internal/provider/codex/codex_test.go:64
- Issue: `TestProvider_RunAgent_ExitZeroSuccess` uses `NewWithBinary("/bin/sh")` and the comment claims "// /bin/sh -c 'exit 0' reliably exits 0 everywhere." This is incorrect. `RunAgent` calls `buildExecArgs(req)` internally, which (per `TestBuildExecArgs_FirstArgIsExec`) returns args with "exec" as the first element. The resulting subprocess call is `/bin/sh exec --json --sandbox workspace-write ...`. POSIX sh treats the first non-flag argument as a script filename; it tries to open a file named "exec", fails, and exits 2 — not 0. Verified: `/bin/sh exec --json ... < /dev/null` exits 2 with "cannot open exec: No such file." The happy-path assertion `res.Outcome != provider.OutcomeSuccess` will trigger. The correct stub is `/bin/true`, which exits 0 unconditionally regardless of arguments (also verified).
- Severity: HIGH
- Action: Replace `NewWithBinary("/bin/sh")` with `NewWithBinary("/bin/true")` at codex_test.go:66. Update the comment to "// /bin/true exits 0 unconditionally regardless of arguments." Also review `TestProvider_RunAgent_ResultOutcomeSet` (line 128) which has the same stub binary and will produce OutcomeUnknown (exit 2) rather than OutcomeSuccess — the assertion `res.Outcome == OutcomeUnknown && res.ExitCode == 0` accidentally passes for the wrong reason.

#### ISOLATION: Dogfood evidence document does not exist — test always fails
- File: tests/test_v5_codex_dogfood.sh:40
- Issue: The bash test guards `docs/v5-codex-dogfood-evidence.md`. The file does not exist in the working tree. Assertion A exits 1 unconditionally, skipping all remaining checks. The tester documents this as "BUG: docs/v5-codex-dogfood-evidence.md not created." A regression guard that always fails provides no protection and would block CI on every run until the document is created.
- Severity: MEDIUM
- Action: Either (a) create `docs/v5-codex-dogfood-evidence.md` as part of the m12 acceptance run and commit it before this test runs, or (b) add a skip-with-notice block: `if [[ ! -f "$EVIDENCE_DOC" ]]; then echo "SKIP: evidence doc not yet created (m12 not run)"; exit 0; fi`. Option (b) is safer for pre-completion CI runs; option (a) is required for m12 acceptance.

#### EXERCISE: Soft early-return in TestProvider_RunAgent_ExitOneUpstreamError omits outcome assertion
- File: internal/provider/codex/codex_test.go:94
- Issue: When `/bin/false` produces a process-level error (rather than just a non-zero exit code), the test logs and returns at line 113 without ever asserting `res.Outcome == provider.OutcomeUpstreamError`. The primary goal of this test — verifying that exit 1 maps to `OutcomeUpstreamError` — is not asserted on the early-return path. Since `/bin/false` is expected to exit 1 cleanly (not produce a process error), this branch is unlikely to be hit in practice, but the assertion gap means a regression could pass silently.
- Severity: LOW
- Action: Move the `OutcomeUpstreamError` assertion outside the `if err != nil` guard, or assert the outcome before the early return. The current structure treats the non-error path as the only assertion point.

### Test Quality Notes (non-findings)

The tests that compile are well-designed:
- `exit_codes_test.go`: Table-driven coverage of all 5 explicit exit code mappings plus unrecognised codes (2, 126, 255, -1). Assertions use provider.Outcome constants, not magic numbers. Good.
- `flags_test.go`: Covers defaults, model override, stdin marker, cwd injection, inline config, empty-prompt error, and key-leak prevention. `baseRequest()` pins ProviderSpecific so tests are deterministic. Good.
- `exec_test.go`: Context cancel, timeout propagation, stdout capture, stdin piping, and binary-not-found are all covered with real process invocations. No mocking of runCodex internals. Good.
- `test_v5_codex_dogfood.sh`: The content checks (grep patterns for RUN_SUMMARY, cost, commit subject, section count) are well-chosen against the m12 acceptance criteria. The test structure is sound once the evidence document exists.
- Naming throughout is descriptive and encodes both scenario and expected outcome.
- `codex_test.go:13` compile-time interface assertion (`var _ provider.Provider = (*Provider)(nil)`) is a good practice.
