# Go Test Audit

Audited 82 test files across 18 packages, ~818 test/fuzz/benchmark functions.

Overall the Go test suite is in healthy shape — it is recent (most files
post-date the m02–m26 wedges), thoroughly comments most invariants it
guards, and uses standard Go practice (table-driven cases, `t.TempDir()`,
seam-based fakes, no global state). Only a handful of true findings; no
DELETE-STALE candidates; one CONSOLIDATE candidate; the remaining notes are
coverage gaps and skipped-test inventory.

## Per-package summary

| Package | Test files | Verdict | Notes |
|---|---|---|---|
| `cmd/tekhton` | 15 | OK | Cobra subcommand smoke + flag-parsing tests; clean. |
| `internal/finalize` | 11 | OK | One-file-per-hook + orchestrator + shim layering; coverage is dense. |
| `internal/supervisor` | 8 | OK | Largest package by LOC; `run_test.go` is 722 lines but cohesive. |
| `internal/runner` | 8 | OK | Hook/env/single/complete/resume well covered; nil-guard tests slightly thin (see gaps). |
| `internal/proto` | 7 | OK | Round-trip + validation + fixture parity. Comprehensive. |
| `internal/preflight` | 6 | OK | Per-check files + orchestrator; m22 acceptance criteria explicit. |
| `internal/errors` | 6 | OK | Classify / cross-subsystem / recovery / redact / sentinels — taxonomy fully exercised. |
| `internal/dag` | 4 | OK | State machine + migration + validation; one trivial helpers-only file. |
| `internal/stagerunner` | 3 | OK | Adapter + helpers + parity-against-legacy.sh. Parity test critical during V4. |
| `internal/tui` | 2 | OK | Sidecar lifecycle + status file; POSIX-only paths gated correctly. |
| `internal/state` | 2 | OK | Snapshot + fuzz; AC #1–#5 exhaustively covered. |
| `internal/pipeline` | 2 | OK | Runner + gates; fake adapter/runner pattern is clean. |
| `internal/orchestrate` | 2 | OK | Loop + classify recovery matrix; mirrors bash classifier. |
| `internal/causal` | 2 | OK | Log + fuzz; bash-style JSON-escape parity explicit. |
| `internal/version` | 1 | NEEDS-REVIEW | Six tests for a trivial `strings.TrimSpace` wrapper. Slight overkill but harmless; one test (DoesNotTrimInteriorSpaces) is the only one really worth keeping. |
| `internal/prompt` | 1 | OK | Template engine fully covered (variables + conditionals + edge cases + runaway protection). |
| `internal/manifest` | 1 | OK | Parser + frontier + atomic save + concurrency smoke; comprehensive. |
| `internal/config` | 1 | OK | 704-line file; covers parse, defaults, CI, clamp, validate, emit, late-defaults, edge cases. |

## Specific findings

### Stale or redundant tests

- `internal/version/version_test.go` — **NEEDS-REVIEW**. Six tests for a
  function whose body is `strings.TrimSpace(Version)`. The two whitespace
  variants (`TrimsTrailingNewline`, `TrimsLeadingWhitespace`, `TrimsBothSides`)
  are all the same assertion against different inputs and could be a single
  table-driven test. Not stale — but if anyone is doing a pass to tidy, this
  is the package to merge into one parameterised test. Default verdict: KEEP.

- `internal/finalize/shim_test.go:TestBashShimHook_PassesEnvAndExitCodeThrough`
  vs `shim_env_contract_test.go:TestShimEnvHasContract` — **CONSOLIDATE candidate
  (low priority)**. Both files exercise `BashShimHook.Run` writing env vars
  into a bash subprocess that echoes them back. The shim_env_contract_test
  is the newer m26 acceptance criterion (pre-composed `EnvKV`); the shim_test
  one uses the legacy buildEnv code path. Both are valuable as paired
  contract tests — keep separate but worth a doc comment cross-link.
  Verdict: KEEP (paired by design, comments make intent clear).

No DELETE-STALE candidates were found. Every Go test file targets code that
exists and is current. The cross-package overlaps that exist
(`shim_env_contract_test.go` + `stage_env_uniformity_test.go` +
`stage_env_test.go` all asserting different layers of the m26 env-contract
chain) are deliberate end-to-end layering and should remain.

### Coverage gaps

- **`internal/version`** — Tests only `String()`. If `Version` is ever
  parsed for semver comparison or bump logic (PROJECT_VERSION machinery),
  there is no Go-side coverage. The actual bump logic lives in
  `lib/project_version*.sh`, so this is fine for now; flag only if a
  V5 milestone ports it.

- **`internal/manifest`** — Comprehensive, but no test verifies the
  behavior when an existing `MANIFEST.cfg` is altered concurrently by an
  external process between `Load` and `Save` (last-writer-wins is the
  assumption — confirm whether the atomic-rename pattern survives this).
  `TestConcurrentReadsAfterRename` covers reader concurrency but not
  external-writer races.

- **`internal/prompt`** — Strong on the rendering engine. No test for
  cycle detection in `{{IF:X}}` blocks whose body contains `{{X}}` that
  expands to more `{{IF:X}}` markers (template self-reference) — the
  runaway guard (`TestRenderString_ConditionalRunaway`) covers literal
  unbalanced IFs, not recursive expansion. Probably impossible by
  design since substitution is single-pass, but worth a confirming test.

- **`internal/config`** — No `t.Parallel()` anywhere despite many
  independent test cases. Not a correctness gap — the `clearCIEnv` /
  `t.Setenv` pattern is mutex-incompatible — but reduces test wall-clock
  unnecessarily. Note for future cleanup.

- **`internal/runner/hooks_test.go`** —
  `TestBashHookRunnerFinalizeSkipsMissingScript` asserts that Finalize
  returns nil when no shim exists, but doesn't capture *which* hooks ran.
  The intent (continue-on-error chain) is fine but the assertion is weak.
  Consider adding a counter on the Go-native hooks (clear_state,
  mark_done, archive_milestone) to confirm they still ran.

- **`internal/orchestrate`** — The classify matrix is excellent, but
  `TestEnvGateRetryGuardSticks` only proves the guard sticks after one
  retry. The "envGateRetried = true on subsequent attempts" path through
  a fresh Loop instance via the SetEnvGateRetried CLI seam is exercised
  only by `TestSetGuardSetters`, which doesn't run an attempt. Coverage
  is fine but the pair could be stronger.

- **`internal/supervisor/quota_test.go`** — 22 functions cover
  `EnterQuotaPause` and the M125 layered probe well, but the
  fakeClock/fakeSleep harness is non-trivial. No regression test for
  what happens if `QUOTA_MAX_PAUSE_DURATION` is exceeded mid-pause
  (the M125 hard-cap path).

### Skipped tests

All skips are environmental guards (file present / platform / TTY), not
WIP placeholders. None require enabling-or-deleting action. Inventory:

- `internal/tui/extra_test.go:53,98` — POSIX-only spawn tests, skip on
  Windows. Correct.
- `internal/preflight/env_test.go:23,39,79,83,88` — gate on `go`/`node`
  presence in PATH. Correct (preflight env probe is environment-sensitive).
- `internal/state/snapshot_test.go:141,320` — skip if `chmod` cannot
  modify temp dir (e.g. some Docker layouts). Correct.
- `internal/supervisor/run_test.go:23,26,663,666,692` — POSIX/JobObject
  split; gate on `bash`/`sleep` on PATH. Correct.
- `cmd/tekhton/supervise_test.go:26,29` — same fake_agent.sh skip.
  Correct.
- `internal/stagerunner/parity_test.go:45,51,123,138,214,220` — skip
  when run from outside repo (no `go.mod`) or when `tekhton-legacy.sh`
  missing. **Tekhton-legacy.sh is still present** (139 KB), so the parity
  test is live. Critical during V4 — do not remove.
- `internal/config/config_test.go:463` — `TestApplyLateDefaults_EmptyFastPath`
  self-skips when `lateDefaults` is non-empty. This is a guard against a
  silent regression and self-disables when no longer needed. Correct.
- `internal/config/config_test.go:681` — bash-not-found skip for the
  EmitShell eval round-trip. Correct.
- `internal/supervisor/fsnotify_test.go:138` — skip in fsnotify fallback
  mode (e.g., FS without inotify). Correct.

### Cross-package overlap (informational, not a verdict)

The m26 env-contract is intentionally tested across four files at three
layers:

1. `internal/proto/stage_env_test.go` — wire-format round-trip on the
   `StageEnvV1` struct.
2. `internal/runner/env_test.go` — `EnvBuilder.Compose` produces the
   right fields, `AsKV` is deterministic and unquoted.
3. `internal/runner/stage_env_uniformity_test.go` — every stage gets the
   identical composed env (m26 AC).
4. `internal/finalize/shim_env_contract_test.go` — finalize hooks see
   the same composed env via `EnvKV`.

This is the right shape — each layer guards a distinct contract, and
collapsing them would lose granularity when one layer drifts. Keep as is.

### Other observations

- `internal/stagerunner/parity_test.go` is the most important V4
  cutover test in the suite — it asserts that the Go `BashAdapter`'s
  `DefaultLibHelpers` and per-stage `Helpers` slices match
  `tekhton-legacy.sh` byte-for-byte. Once Phase 5 lands (no `.sh` files
  in lib/), this file becomes obsolete in one go. Until then it is
  load-bearing.
- `internal/proto/agent_v1_test.go` reads JSON fixtures from
  `testdata/supervise/`. Generic concern: fixture rot is silent — if a
  fixture is deleted but a test still globs for it, `len(matches) == 0`
  fatals, which is the right behavior. Already handled correctly here.
- `internal/runner/runner_test.go:TestRunCompleteLoopExit127BoundedByMaxAttempts`
  and `TestRunCompleteLoopRepeatedSaveExitDoesNotIterate` are explicitly
  regression tests for the "147-retry bug" recorded in HUMAN_NOTES.md.
  Comments make the historical context clear — good practice, KEEP.
- No `// TODO` or `// FIXME` markers found in any `_test.go` file in
  scope. The suite is currently clean of dead-comment debt.
