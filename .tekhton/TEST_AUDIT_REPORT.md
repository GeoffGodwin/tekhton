## Test Audit Report

### Audit Summary
Tests audited: 2 files — `cmd/tekhton/dag_test.go` (24 Go test functions) and
`tests/test_dag_advance_parity.sh` (21 assertions in 9 logical groups).
Verdict: PASS

### Findings

#### COVERAGE: validate CLI only exercises one of five validation-error kinds
- File: cmd/tekhton/dag_test.go (no specific line — absence)
- Issue: `TestDagValidateCmd_MissingDep` covers the missing-dep path and
  `TestDagValidateCmd_Clean` covers the happy path, but there are no CLI-level
  tests for cycle detection (`ErrCycle`), duplicate IDs (`ErrDuplicateID`), or
  unknown statuses (`ErrUnknownStatus`) flowing through the validate command.
  All five checks collapse to the same CLI outcome (`exitCorrupt`), so the
  regression risk is low; the five checks are thoroughly exercised by the unit
  tests in `internal/dag/validate_test.go` (out of scope for this audit).
- Severity: LOW
- Action: Optional — add one small cycle fixture test (two entries with a A→B→A
  dep) to confirm the Go `checkCycles` result propagates to `exitCorrupt` at the
  CLI layer. Not blocking.

#### NAMING: `TestDagFrontierCmd_NoPath` name understates the condition
- File: cmd/tekhton/dag_test.go:41
- Issue: The test clears `$MILESTONE_MANIFEST_FILE` AND omits `--path`, so
  `resolveManifestPath("")` returns `""` and `loadDagState` errors with "dag:
  --path or $MILESTONE_MANIFEST_FILE required". The name implies only the flag
  is absent, which is accurate but incomplete — a reader might expect a separate
  test covering the env-var-absent case alone (which is the same code path).
  The paired `TestDagFrontierCmd_ViaEnv` makes the complementary success case
  clear, so the pairing is readable; the name is slightly imprecise, not
  misleading.
- Severity: LOW
- Action: Optionally rename to `TestDagFrontierCmd_NeitherPathNorEnv` or add a
  one-line comment. Not blocking.

#### NAMING: `TestDagValidateCmd_MissingDep` passes unexplained `--milestone-dir ""`
- File: cmd/tekhton/dag_test.go:138-139
- Issue: The test explicitly passes `--milestone-dir ""` without explanation.
  This disables `checkFiles` inside `State.Validate` — the intent is to isolate
  the missing-dep check. Without a comment, a reader cannot tell whether the
  empty string is intentional or an oversight. If the flag is removed, the
  default `filepath.Dir(path)` logic kicks in and adds a spurious `missing_file`
  error alongside the intended `missing_dep` error, making the test harder to
  understand and easier to misread.
- Severity: LOW
- Action: Add a one-line comment above the flag:
  `// --milestone-dir "" skips file-existence checks to isolate the missing-dep path.`

### HIGH and INTEGRITY findings: None

All assertions in both test files are derived from real implementation behavior
and expected values are grounded in fixture data and the documented state-machine
rules (transition table in `internal/dag/dag.go::validTransition`, exit codes in
`cmd/tekhton/errors.go`, frontier semantics in `internal/manifest/manifest.go`).

No test mocks the code under test. `writeFixture` / `captureStdout` are defined
in the same test package (`manifest_test.go`) and write to `t.TempDir()`.
`test_dag_advance_parity.sh` uses `mktemp -d` with a `trap … EXIT` cleanup.
Neither file reads live pipeline artifacts, build reports, or project-state files.
No orphaned references to the deleted files (`lib/milestone_dag_helpers.sh`,
`lib/milestone_dag_validate.sh`, `lib/milestone_dag_migrate.sh`) appear in
either audited file.

#### Rubric summary

| File | Honesty | Coverage | Exercise | Weakening | Naming | Alignment | Isolation |
|---|---|---|---|---|---|---|---|
| cmd/tekhton/dag_test.go | PASS | PASS† | PASS | N/A (new) | PASS‡ | PASS | PASS |
| tests/test_dag_advance_parity.sh | PASS | PASS | PASS | N/A (new) | PASS | PASS | PASS |

† Validate CLI only exercises one of five error-kind paths (LOW, non-blocking).
‡ Two naming nits noted above (LOW, non-blocking).
