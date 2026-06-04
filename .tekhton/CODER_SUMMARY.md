# Coder Summary

## Status: COMPLETE

## What Was Implemented

m42 — Preflight: guard against the no-op `TEST_CMD="true"` default. All three
goals and all five acceptance criteria are implemented.

### Goal 1 — Preflight warning for a no-op TEST_CMD

New Go check `TestCmdCheck` in `internal/preflight/test_cmd.go`. Registered in
the orchestrator (`internal/preflight/orchestrator.go::checkOrder` + the
`goNativeChecks` factory map) between `claude_env` and `services_infer`.

Behavior:
- Skips when `MILESTONE_MODE` is unset / empty / not "true" — warnings on
  plain `--task` runs would be noise.
- When `MILESTONE_MODE=true` AND `TEST_CMD` matches the no-op set (after
  trimming: `""`, `"true"`, `":"`, `"/bin/true"`, `"/usr/bin/true"`):
  - Default: emits `StatusWarn` with detail "TEST_CMD is a no-op (<value>)
    — milestone acceptance will pass WITHOUT running tests. Set a real
    TEST_CMD in pipeline.conf (e.g. `cargo test`, `npm test`,
    `go test ./...`)."
  - With `REQUIRE_REAL_TEST_CMD=true`: escalates to `StatusFail`, which
    drives `Orchestrator.HasBlockers()=true` and aborts the run.
- Appends one `HUMAN_ACTION_REQUIRED.md` entry per trip via
  `drift.HumanAction.Append("preflight", detail)` so the post-run banner
  surfaces the issue.

The "no-op" recognition is exported as `IsNoopCommand` so the bash side
(see Goal 2) and the Go side share one source of truth.

### Goal 2 — Honest summary line + `tests_run` flag

Two new bash helpers in the new file `lib/hooks_final_checks_helpers.sh`
(extracted to keep `hooks_final_checks.sh` under the 300-line bash ceiling):

1. `_is_noop_test_cmd "$TEST_CMD"` — pure-bash port of `IsNoopCommand`.
   Trims surrounding whitespace via parameter expansion (no sed fork);
   recognises the same set of no-op forms as Go.
2. `_record_tests_run_state "true"|"false"` — writes two artifacts:
   - `${TEKHTON_DIR}/.tests_run_state` (sentinel file, single-line)
   - splices `"tests_run": <bool>` into `RUN_RESULT.json` via `jq`
     (best-effort: missing `jq` / file / dir fall through silently).

Wired into both code paths the milestone names:

- `lib/hooks_final_checks.sh::run_final_checks` — when TEST_CMD is a no-op,
  prints `tests: skipped (no-op TEST_CMD: '<value>') — set TEST_CMD in
  pipeline.conf to actually run tests.` instead of the misleading
  `[✓] true: all passing` and records `false`. Existing success / failure
  branches now also record `true` so a successful real-test run leaves
  `tests_run=true` in `RUN_RESULT.json`.
- `lib/milestone_acceptance.sh::check_milestone_acceptance` — same
  short-circuit, ensuring milestones don't tick green via `bash -c "true"`
  inside the acceptance gate either.

`RunResultV1` gained a `TestsRun *bool` field
(`internal/proto/run_v1.go`) — pointer for tri-state so legacy snapshots
that omit the field are distinguishable from explicit `false`. Field is
`omitempty` so untouched RUN_RESULT.json files stay byte-identical.

### Goal 3 — Better init TEST_CMD detection

New file `lib/init_config_test_cmd.sh` with two helpers:

- `_m42_test_cmd_fallback PROJECT_DIR` — Cargo.toml → `cargo test`,
  go.mod → `go test ./...`, package.json with real `scripts.test` (not
  the npm-init `"no test specified"` placeholder) → `npm test`,
  pyproject.toml / setup.py / requirements.txt → `pytest`,
  Gemfile-with-rspec → `bundle exec rspec`, mix.exs → `mix test`,
  pubspec.yaml → `flutter test` / `dart test`.
- `_m42_test_cmd_fallback_source` — sibling that names the manifest that
  drove the inference, so the source annotation in the emitted
  pipeline.conf points at the right file.

Wired into `lib/init_config.sh::_generate_smart_config` immediately after
the upstream detect pipeline and before the CI override block. Only fires
when the upstream `test_cmd` is empty (the common case the milestone fixes
is: detect pipeline silently returned nothing → `TEST_CMD="true"` fallback
fires → milestones tick green).

The Go detect engine (`internal/detect/commands.go`,
`internal/detect/commands_pkg.go`) already covers these ecosystems with
high confidence. The bash fallback is a defense-in-depth net for the
cases the Go side can't see (binary not on PATH during init bootstrap,
`jq` missing, manifest present but predicate didn't match).

## Verification

| Test | Result |
|---|---|
| `tests/test_preflight_noop_test_cmd.sh` | 20 PASS / 0 FAIL |
| `tests/test_init_test_cmd_detection.sh` | 17 PASS / 0 FAIL |
| `internal/preflight/test_cmd_test.go` (8 cases, full Go-side coverage) | PASS |
| `bash tests/run_tests.sh` (full suite) | 506 shell PASS / 0 FAIL + Go PASS |
| `shellcheck` modified bash files (warning+) | clean |

## Acceptance Criteria — predicate-by-predicate

- ✅ **AC1.** A project with `TEST_CMD="true"` in `MILESTONE_MODE` produces
  a preflight warning and a `HUMAN_ACTION_REQUIRED` entry:
  `TestTestCmdCheck_Warn_NoopInMilestoneMode` (asserts both the
  `StatusWarn` finding and the `HUMAN_ACTION_REQUIRED.md` line containing
  `TEST_CMD is a no-op` and `Source: preflight`).
- ✅ **AC2.** The Run Summary distinguishes "tests skipped (no-op)" from
  "tests passed": `lib/hooks_final_checks.sh:107-113` now emits the
  `tests: skipped (no-op TEST_CMD: '<value>')` warn line; the previous
  `success "${TEST_CMD:-true}: all passing"` only fires when a real
  command exited 0.
- ✅ **AC3.** `RUN_RESULT.json` / tester result carries `tests_run=false`
  for a no-op gate: `_record_tests_run_state "false"` splices
  `"tests_run": false` via jq. `internal/proto.RunResultV1.TestsRun` is
  the typed envelope side.
- ✅ **AC4.** Init on a Cargo/Node/Go project emits a real `TEST_CMD`,
  not "true": `tests/test_init_test_cmd_detection.sh` covers Cargo.toml,
  go.mod, package.json (with both real-scripts.test and npm-init
  placeholder cases), pyproject.toml, setup.py, Gemfile-rspec, mix.exs,
  pubspec.yaml (flutter + dart variants), priority ordering, and the
  no-manifest case (17 assertions).
- ✅ **AC5.** `REQUIRE_REAL_TEST_CMD=true` turns the warning into a
  preflight hard-fail; default stays warn:
  `TestTestCmdCheck_Fail_RequireRealTestCmd` (StatusFail when
  REQUIRE_REAL_TEST_CMD=true), `TestTestCmdCheck_Warn_NoopInMilestoneMode`
  (StatusWarn at default).

## Watch For — predicate-by-predicate

- ✅ "Do not hard-break existing projects that intentionally run with
  `TEST_CMD="true"`": default is `StatusWarn`; hard-fail requires opt-in
  via `REQUIRE_REAL_TEST_CMD=true`. Both
  `TestTestCmdCheck_Warn_NoopInMilestoneMode` and the corresponding
  Skipped tests cover the no-break path.
- ✅ "The acceptance stage already logs `${TEST_CMD:-true}` — align the
  no-op detection so the warning and the runner agree on what counts as
  no-op": `IsNoopCommand` (Go) and `_is_noop_test_cmd` (bash) recognise
  the identical set (`""`, `"true"`, `":"`, `"/bin/true"`,
  `"/usr/bin/true"` after trim). The "" case in particular mirrors bash's
  `${TEST_CMD:-true}` substitution: an unset value operationally runs
  `true`, so both gates classify it the same.

## Files Modified

- `internal/preflight/test_cmd.go` (NEW) — `TestCmdCheck`,
  `IsNoopCommand`, `resolveHumanActionPath`.
- `internal/preflight/test_cmd_test.go` (NEW) — 8 Go cases covering the
  recognition set, milestone-mode gating, default-warn behavior,
  REQUIRE_REAL_TEST_CMD hard-fail, the unset-counts-as-noop path, and
  the path-resolution helpers.
- `internal/preflight/orchestrator.go` — registered `test_cmd` in
  `checkOrder` and `goNativeChecks`.
- `internal/preflight/orchestrator_test.go` — updated
  `TestCheckOrder_MatchesRegistration` expected list,
  `TestNewOrchestrator_BuildsAllFiveChecks` expected count (6→7), and
  `TestOrchestratorRun_NoApplicableChecks_NoReport` env scrub set.
- `internal/proto/run_v1.go` — added `RunResultV1.TestsRun *bool` field.
- `lib/hooks_final_checks.sh` — replaced inline helpers with a sourced
  shim; new no-op short-circuit in `run_final_checks` plus
  `_record_tests_run_state "true"` calls on the three real-test exit
  paths. File is back under the 300-line bash ceiling (268 lines).
- `lib/hooks_final_checks_helpers.sh` (NEW) — `_is_noop_test_cmd`,
  `_record_tests_run_state`.
- `lib/milestone_acceptance.sh` — short-circuits the TEST_CMD branch when
  `_is_noop_test_cmd` returns 0; logs the same honest warn line and
  records the false state.
- `lib/init_config.sh` — wires the m42 fallback into
  `_generate_smart_config` immediately after the upstream detect pipeline
  and before the CI override block.
- `lib/init_config_test_cmd.sh` (NEW) — `_m42_test_cmd_fallback` and
  `_m42_test_cmd_fallback_source` for the seven ecosystems the milestone
  enumerates.
- `cmd/tekhton/preflight_test.go` —
  `TestPreflightCmd_EmptyProjectExitsZero` env scrub set extended to
  include `MILESTONE_MODE` / `REQUIRE_REAL_TEST_CMD`.
- `tests/test_preflight_noop_test_cmd.sh` (NEW) — 20 bash assertions
  covering `_is_noop_test_cmd` recognition / rejection, the sentinel
  writer's happy path, the RUN_RESULT.json jq splice, and the three
  best-effort no-artifact branches.
- `tests/test_init_test_cmd_detection.sh` (NEW) — 17 bash assertions
  covering every ecosystem branch plus priority ordering and the
  no-manifest case.
- `CLAUDE.md` — added `init_config_test_cmd.sh` to the repo-layout tree
  and `REQUIRE_REAL_TEST_CMD` to the Template Variables table.

## Architecture Change Proposals

None. The new preflight check is a sibling of existing five
(`foundation` / `ui_audit` / `env` / `claude_env` / `services_infer` /
`services`); the registration mechanism, the per-finding shape, and the
HUMAN_ACTION_REQUIRED writer were all already in place. The
`RunResultV1.TestsRun` field is an additive `omitempty` pointer — legacy
RUN_RESULT.json files keep their existing shape, and the bash side
mutates the file via jq rather than the runner re-marshalling.

## Observed Issues (out of scope)

- `lib/finalize_commit.sh` is still at 287 lines (carried over from the
  prior reviewer's non-blocking note). Untouched by m42 but still on the
  edge of the ceiling. A single future addition will breach it; the
  reviewer's recommendation to extract `_do_git_commit` or the
  bookkeeping helpers stands.
- `stages/coder.sh` is still at 1202 lines (carried over). Same story —
  the prior reviewer flagged a dedicated refactor milestone; m42 left it
  alone deliberately.
- `lib/init_config_sections.sh` carries a duplicate of the same
  `TEST_CMD="true"` fallback at line 57 that `_emit_section_essential`
  uses. m42 fixes the upstream by populating `test_cmd` before the
  sectioned generator runs, so the fallback never fires in practice;
  but the two-code-paths situation is a code-smell that a future cleanup
  milestone could collapse.

## Human Notes Status

No Human Notes block was injected for this run.

## Docs Updated

- `CLAUDE.md` — added the new `lib/init_config_test_cmd.sh` to the
  repository layout tree and `REQUIRE_REAL_TEST_CMD` to the Template
  Variables config-key table. The new `RunResultV1.TestsRun` field is
  documented in its struct comment in `internal/proto/run_v1.go`.
