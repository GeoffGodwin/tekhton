# Coder Summary

## Status: COMPLETE

## What Was Implemented

m27.3 — Parity Gate + CI Wiring + Docs. Institutionalizes the m27.1
audit tool and the m27.2 sweep so a future bash file landing an
unguarded read of a contract variable trips a hard CI failure instead
of silently working until production exercises the broken path.

Implementation:

1. **`tests/test_stage_env_setu.sh`** (new, 142 lines) — pipeline-level
   parity test that drives `tekhton run-stage <name>` for each stage in
   `internal/runner/single.go::defaultStageOrder()` (intake, coder,
   security, review, tester) against the new `tests/testdata/env_contract/`
   fixture. Agent invocations short-circuit via `TEKHTON_AGENT_BINARY`
   pointed at the existing `testdata/fake_agent.sh` (mode=happy). The
   test scans subprocess stderr for `unbound variable` strings and
   cross-checks `/tmp/tekhton_stage_env_<stage>_post.txt` presence as a
   "did sourcing complete?" signal.

   **Deviation from milestone literal wording.** The milestone describes
   `tekhton run --milestone m27test-fixture --dry-run --no-tui`. The
   current `tekhton run --dry-run` flag is plumbed but never consumed
   (see `cmd/tekhton/run.go:85` comment — "no dispatch branch consumes
   it yet"), so running through `tekhton run` would either invoke real
   agents (hitting Anthropic) or fail on the first downstream stage
   that needs upstream output. `tekhton run-stage` per stage is
   mechanically equivalent for the surface under test — it spawns the
   same `stagerunner.BashAdapter` subprocess that sources every
   `lib/*.sh` and `stages/*.sh` under `set -euo pipefail` — and
   guarantees every stage in `defaultStageOrder` is exercised.
   Documented in the test header.

2. **`tests/testdata/env_contract/`** (new fixture) — minimal target
   project: `.claude/pipeline.conf` (validates clean under
   `tekhton config validate`), `.claude/milestones/MANIFEST.cfg` +
   `m27test-fixture.md`, stub `.claude/agents/{coder,reviewer,tester}.md`,
   stub `CLAUDE.md`.

3. **`Makefile` `dogfood` target** — extended with two new gates after
   the existing state-leak step:
   - `scripts/audit-bash-env.sh` (m27.1 static unguarded-read audit)
   - `tests/test_stage_env_setu.sh` (m27.3 set -u parity test)
   Both gates fail-fast, audit runs first (~1s, precise per-file:line
   errors) before the slower parity test.

4. **`scripts/wedge-audit.sh`** — added companion-tool presence
   assertions. Extracted to a sibling file
   (`scripts/wedge-audit-companions.sh`) to keep wedge-audit.sh under
   the 300-line bash ceiling (CLAUDE.md Rule 8). Asserts the existence
   of `scripts/audit-bash-env.sh` + `tests/test_stage_env_setu.sh` and
   that both are referenced from `Makefile` (so `make dogfood` still
   wires them).

5. **`docs/v4-env-contract.md`** (new) — one-page reference. Producer
   side (`internal/runner/env.go::AsKV` + `internal/config/defaults.go`),
   consumer rule (`${VAR:-DEFAULT}` mandatory), CI gates table, full
   default snapshot (366 pipeline.conf defaults + 11 StageEnvV1 runtime
   fields = 377 rows total). Generated via `tekhton config defaults
   --emit shell` with `<PROJECT_DIR>` placeholder substituted in. Doc
   header notes manual-snapshot status and the regeneration command.

6. **`CLAUDE.md`** — added one-line link to the new doc beside the
   existing "TUI lifecycle model" reference under the Template
   Variables section.

7. **`VERSION` → `4.27.0`** — closes the parent m27 arc.

8. **`scripts/wedge-audit.sh`** — fixed pre-existing shellcheck SC2016
   info-level warning on the supervise-call pattern by switching from
   the `\$` form to a `[$]` character class (semantically identical
   regex, no SC2016 trip). This was necessary because the AC requires
   `shellcheck tests/test_stage_env_setu.sh scripts/wedge-audit.sh`
   exit 0; default shellcheck severity includes info findings.

## Acceptance Criteria — verified

- [x] `tests/test_stage_env_setu.sh` exists and is executable.
- [x] `bash tests/test_stage_env_setu.sh` exits 0 against current tree.
- [x] Sanity check exercised manually: reverted `lib/detect_workspaces.sh:12`
      `"${WORKSPACE_ENUM_LIMIT:-50}"` to an unset bareword, ran the
      parity test, observed exit 1 with the offending file + line
      number in the error message; restored. Documented in test header
      with a reproducible recipe.
- [x] `tekhton config validate --project-dir tests/testdata/env_contract`
      exits 0 (`ok — 368 keys, 0 warnings`).
- [x] `make dogfood` exits 0; stdout shows both
      `audit-bash-env.sh` and `test_stage_env_setu.sh` invocation
      lines + `all gates green` footer.
- [x] `bash scripts/wedge-audit.sh` exits 0. Also verified the new
      assertions catch the regression by temporarily renaming
      `scripts/audit-bash-env.sh` away — wedge-audit then failed with
      "missing companion file" and rc=1.
- [x] `docs/v4-env-contract.md` exists, is non-empty (488 lines), and
      contains 377 contract-variable rows in the table (≥30
      requirement).
- [x] `CLAUDE.md` links to `docs/v4-env-contract.md` (`grep -q
      v4-env-contract.md CLAUDE.md` succeeds).
- [x] `VERSION` reads `4.27.0`. (Note: `make dogfood` invocations of
      `tekhton` internally fire the project-version patch bump, which
      re-bumps to `4.27.x`. Final-state VERSION written as `4.27.0`;
      this is the value the m27.3 close commit lands. The next
      milestone close-finalize will re-apply the milestone strategy.)
- [x] `bash tests/run_tests.sh` — 490 shell tests pass, all Go tests
      pass. One pre-existing failure (`test_tester.sh` Test 2,
      UPSTREAM exit 1) — verified failing at base commit `3a89ddb`
      *before* m27.3 touched anything. m27.2's CODER_SUMMARY also
      documented this as out of scope. Same root cause: contract
      mismatch between the test expectation and the
      `_run_tester_write_failing` implementation in
      `stages/tester_tdd.sh:84` (`return` vs `exit 1`).
- [x] `shellcheck tests/test_stage_env_setu.sh scripts/wedge-audit.sh`
      exits 0 (default severity — no warnings or info findings).
- [x] Parent `m27` manifest status update is owned by the finalize
      orchestrator (`mark_done` hook) at m27.3 close — out of scope
      for the coder pass.

## Root Cause (bugs only)

N/A — m27.3 is institutional protection, not a bug fix. The work
adds CI gates + docs around the m27.1/m27.2 surface so future
regressions are caught at PR time instead of runtime.

## Files Modified

**New:**

- `tests/test_stage_env_setu.sh` (NEW, 142 lines) — m27.3 parity test.
- `tests/testdata/env_contract/.claude/pipeline.conf` (NEW) — fixture config.
- `tests/testdata/env_contract/.claude/milestones/MANIFEST.cfg` (NEW) —
  fixture manifest.
- `tests/testdata/env_contract/.claude/milestones/m27test-fixture.md`
  (NEW) — fixture milestone body.
- `tests/testdata/env_contract/.claude/agents/coder.md` (NEW) — stub role.
- `tests/testdata/env_contract/.claude/agents/reviewer.md` (NEW) — stub role.
- `tests/testdata/env_contract/.claude/agents/tester.md` (NEW) — stub role.
- `tests/testdata/env_contract/CLAUDE.md` (NEW) — stub project description.
- `docs/v4-env-contract.md` (NEW, 488 lines) — one-page contract reference.
- `scripts/wedge-audit-companions.sh` (NEW, 53 lines) — extracted
  companion-tool presence checks; sourced by `scripts/wedge-audit.sh`.

**Modified:**

- `Makefile` — `dogfood` target gains audit + parity invocations.
- `scripts/wedge-audit.sh` — sources the new companions file; also
  fixed a pre-existing SC2016 finding via regex character-class rewrite.
- `CLAUDE.md` — added one-line link to `docs/v4-env-contract.md`.
- `VERSION` — `4.27.x` → `4.27.0`.
- `.claude/project_version.cfg` — `CURRENT_VERSION` set to `4.27.0` to
  match VERSION.

## Human Notes Status

No Human Notes attached to this task. The Clarifications block in the
prompt contained five Q&A pairs whose answers were copies of the
question text (noise carried over from a prior run); no signal to
integrate.

## Docs Updated

- `docs/v4-env-contract.md` (NEW) — the doc *is* the public-surface
  change for this milestone. Documents the env contract, the consumer
  rule (`${VAR:-DEFAULT}` mandatory), and the three CI gates that
  enforce it.
- `CLAUDE.md` — added one-line link to the new doc, mirroring the
  existing `TUI lifecycle model` pointer pattern.

## Architecture Change Proposals

None — m27.3 is purely additive CI infrastructure + documentation. No
new dependencies between systems, no new layer boundaries, no changed
interface contracts.

## Observed Issues (out of scope)

- **Pre-existing test failure: `test_tester.sh` Test 2 (UPSTREAM exit 1)**.
  Same finding as m27.2's CODER_SUMMARY — the test asserts
  `_run_tester_write_failing` exits 1 on
  `AGENT_ERROR_CATEGORY=UPSTREAM`, but production code in
  `stages/tester_tdd.sh:84` does `return`, not `exit 1`. Contract
  mismatch predates m27.x. Verified failing at base commit `3a89ddb`.

- **`tekhton run --dry-run` flag is plumbed but never consumed.**
  `cmd/tekhton/run.go:85-88` comments that "no dispatch branch
  consumes it yet — every path below invokes agents for real." This is
  why m27.3's parity test uses `tekhton run-stage` per stage rather
  than `tekhton run --dry-run` as the milestone literal description
  suggested. The deviation is documented in the parity test header and
  in this summary above. A future milestone could wire the flag to a
  preview-only path so the parity test could drive `tekhton run`
  end-to-end as originally envisioned.

- **`docs/v4-env-contract.md` is a manual snapshot.** It will drift as
  new pipeline.conf keys land in `internal/config/defaults.go`. The
  milestone's Watch For called this out; a follow-up M28 could
  generate the doc from `internal/proto/agent_v1.go` field tags +
  `internal/config/defaults.go` comments. The doc header already
  describes the regeneration command.

- **`make dogfood` patch-bumps VERSION as a side effect.** Each
  `make dogfood` invocation runs the test suite, which internally
  calls `tekhton` (which fires the project-version bump hook), patch-
  bumping VERSION from 4.27.0 to 4.27.x. This is independent of m27.3
  and is the existing behavior of the milestone-strategy project-
  version system on non-milestone runs. The final-state VERSION
  written by this coder pass is `4.27.0`; the next finalize hook will
  reset to whatever the milestone strategy resolves at that time.
