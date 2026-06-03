<!-- milestone-meta
id: "42"
status: "todo"
-->

# m42 — Preflight: guard against the no-op `TEST_CMD="true"` default

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | On a downstream project (sdivi-rust) a milestone was marked `[MILESTONE 49.2 ✓]` and progressed to finalize while a real, repo-defined test (`workspace_version`, a version-consistency check) was failing. Tekhton never caught it because the project's `pipeline.conf` carried `TEST_CMD="true"` — so the acceptance and final-check stages "passed" trivially by running `true`. The operator only discovered the failure by running `cargo test` manually after the blocked commit. A measurement pipeline that can mark milestones green without running the project's tests is silently unsafe. |
| **Gap** | `lib/init_config_emitters.sh:87` emits `echo 'TEST_CMD="true"'` as the fallback when init cannot detect a test command. `lib/milestone_acceptance.sh:45` then runs `bash -c "${TEST_CMD:-true}"`, and `lib/hooks_final_checks.sh::run_final_checks` runs the same — both exit 0 on `true`. Nothing warns the operator that the configured test command is a no-op, so a project initialized without a detected test runner accumulates green milestones with **zero test coverage enforcement**. There is no signal in `RUN_RESULT.json`, the tester report, or preflight that "tests were not actually run." |
| **m42 fills** | (a) A preflight check (`lib/preflight*.sh`) that, in `MILESTONE_MODE`, **warns loudly** (and writes a `HUMAN_ACTION_REQUIRED` entry) when `TEST_CMD` is a recognized no-op (`true`, `:`, empty, or unset). (b) Surface a `tests_not_run: true` flag in the tester report / `RUN_RESULT.json` so a no-op test gate is visible in the run summary rather than indistinguishable from a real pass. (c) Improve init auto-detection so common ecosystems get a real default `TEST_CMD` (Rust → `cargo test`, Node → the package.json `test` script, Go → `go test ./...`), reducing how often the `"true"` fallback is emitted at all. |
| **Depends on** | — |
| **Files changed** | `lib/preflight_checks.sh` (or the active preflight module), `lib/init_config_emitters.sh`, `lib/init_*detect*.sh`, `lib/hooks_final_checks.sh` (flag emission), `tests/test_preflight_noop_test_cmd.sh` (new), `tests/test_init_test_cmd_detection.sh`. |

---

## Design

### Goal 1 — preflight warning for a no-op TEST_CMD

Add an `is_noop_command` helper (`true`/`:`/empty after trimming) and, in preflight,
when `MILESTONE_MODE=true` and `TEST_CMD` is a no-op, emit a `⚠`/`✗`-class finding:
"TEST_CMD is a no-op (`true`) — milestone acceptance will pass WITHOUT running tests.
Set a real TEST_CMD in pipeline.conf." Append the same to `HUMAN_ACTION_REQUIRED.md`.
This is a warning by default (not a hard stop) so existing intentional no-op projects
are not broken; gate a hard-fail behind an opt-in (`REQUIRE_REAL_TEST_CMD=true`).

### Goal 2 — make the no-op visible in run output

When `run_final_checks` / acceptance runs a no-op `TEST_CMD`, set `tests_run=false`
in the tester stage result and `RUN_RESULT.json`, and print `tests: skipped (no-op TEST_CMD)`
in the Run Summary instead of `[✓] true: all passing`, which currently reads as a real pass.

### Goal 3 — better init detection

In the init detector, probe for `Cargo.toml` → `cargo test`, `package.json` with a
`scripts.test` → `npm test`, `go.mod` → `go test ./...`, etc., before falling back to
`true`. Emit the detected command (with the existing source-attribution comment).

## Files Modified

- `lib/preflight_checks.sh` — no-op TEST_CMD finding + HUMAN_ACTION entry.
- `lib/init_config_emitters.sh` / `lib/init_*detect*.sh` — ecosystem detection before the `true` fallback.
- `lib/hooks_final_checks.sh` — `tests_run` flag + honest summary line.
- `tests/test_preflight_noop_test_cmd.sh` (new), `tests/test_init_test_cmd_detection.sh`.

## Acceptance Criteria

- A project with `TEST_CMD="true"` in `MILESTONE_MODE` produces a preflight warning and a `HUMAN_ACTION_REQUIRED` entry.
- The Run Summary distinguishes "tests skipped (no-op)" from "tests passed."
- `RUN_RESULT.json` / tester result carries `tests_run=false` for a no-op gate.
- Init on a Cargo/Node/Go project emits a real `TEST_CMD`, not `true`.
- `REQUIRE_REAL_TEST_CMD=true` turns the warning into a preflight hard-fail; default stays warn.

## Watch For

- Do not hard-break existing projects that intentionally run with `TEST_CMD="true"` (some non-test pipelines). Default to warn; hard-fail is opt-in.
- The acceptance stage already logs `TEST_CMD:-true` — align the no-op detection so the warning and the runner agree on what counts as no-op.

## Seeds Forward

- A baseline check that fails the run if a previously-real `TEST_CMD` silently became a no-op between runs (config drift detection).
