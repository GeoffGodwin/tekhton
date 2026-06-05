# Coder Summary

## Status: COMPLETE

## What Was Implemented

m44 — Commit Subject Regression. Three goals, all landed:

### Goal 1 — Sort the diff-stat fallback by changeset magnitude

`lib/hooks.sh::generate_commit_message` previously refined its
`"<prefix>: changes pending"` placeholder by picking the alphabetically
first file from `git diff --stat | head -1`. Because `.claude/`
sorts before `.tekhton/`, `cmd/`, `internal/`, and `lib/`, every
save_exit commit landed with the bookkeeping bump as its subject:
`feat: changes in .claude/project_version.cfg`.

The fix replaces the `head -1` pick with the same awk-parse-sort-by-lines
pattern already used a few lines below it for the top-5 files block.
Both selections now agree on "most-changed" — and the post-fix subject
on a m40.1-shaped save_exit commit becomes
`feat: changes in <largest-real-file>` instead of pointing at the
bookkeeping bump.

### Goal 2 — Export `TASK`, `_CURRENT_MILESTONE`, `MILESTONE_MODE` from `_orch_record_save_state`

`lib/orchestrate_save.sh::_orch_record_save_state` is the only caller
that fires `finalize_run 1` from a save_exit context. `finalize_run`
execs the Go binary (`tekhton finalize`), which in turn spawns each
finalize hook as its own bash subprocess via `lib/finalize_shim.sh`.
Bash locals do not survive into those subprocesses; only exported
variables flow through.

Adding the three explicit exports before `finalize_run 1` means
`_hook_commit` now sees a non-empty `_CURRENT_MILESTONE`, which it
forwards to `generate_commit_message` as `$2`. That triggers the
existing m40.2 fallback (`get_milestone_title $2`) and produces a
subject derived from the milestone title — e.g.
`feat: Commit Subject Regression` — without depending on the
diff-stat fallback at all.

### Goal 3 — Shim-boundary integration test

`tests/test_commit_subject_fallback.sh` (231 lines) drives
`generate_commit_message` across three scenarios plus the AC grep
verification:

1. **Empty TASK + empty milestone, mixed diff (Goal 1 regression guard)**
   — seeds a git repo with `.claude/project_version.cfg` (1 line),
   `big_file.sh` (~50 lines), `medium_file.sh` (~10 lines). Asserts the
   subject is `feat: changes in big_file.sh` and explicitly asserts
   the subject does NOT contain `project_version.cfg` (the second AC
   bullet `! git log -1 --format='%s' | grep -q project_version.cfg`).

2. **Empty TASK + populated milestone via env export (Goal 2 outcome)**
   — seeds a CLAUDE.md with `#### Milestone 44: Commit Subject
   Regression`, drives `generate_commit_message "" "44"`. Asserts the
   subject contains `Commit Subject Regression` (the milestone title).

3. **Populated TASK + empty milestone (happy-path smoke)** — drives
   `generate_commit_message "Implement feature X" ""`. Asserts the
   subject still contains `Implement feature X`.

4. **AC grep verification** — runs the literal AC predicate
   `grep -cE "^[[:space:]]*export (TASK|_CURRENT_MILESTONE|MILESTONE_MODE)" lib/orchestrate_save.sh`
   and asserts the result is exactly 3.

Test runs in ~1s, follows the m40.2 shim-boundary pattern
(`tests/test_state_writer_resume_fields.sh`) — sources the minimum bash
surface (`common.sh`, `milestones.sh`, `milestone_query.sh`,
`milestone_ops.sh`, `hooks.sh`), seeds throwaway git repos, drives
the function, asserts on stdout. Auto-discovered by
`tests/run_tests.sh`'s `test_*.sh` glob.

## Root Cause (bugs only)

`git diff --stat` emits files in plumbing/index order, which is
lexicographic. Combined with the bookkeeping bump touching
`.claude/project_version.cfg` on every run, the alphabetical
`head -1` always returns the bump file rather than the real work.

The compounding factor was that `_orch_record_save_state` did not
forward `TASK` or `_CURRENT_MILESTONE` to the finalize subprocess, so
the higher-quality task-/milestone-derived subject paths in
`generate_commit_message` never fired in save_exit contexts. The
diff-stat fallback was the only signal that reached `_hook_commit`,
and it pointed at the wrong file.

## Files Modified

### Created (NEW)
- `tests/test_commit_subject_fallback.sh` (NEW) — 5-assertion shim-boundary
  regression test.

### Modified
- `lib/hooks.sh` — Goal 1. Replaced the alphabetical `head -1` fallback
  inside `generate_commit_message` with the same awk-sort-by-lines
  pattern used by the top-5 block below it. Net length: 299 → 298 lines
  (compacted the awk pipeline onto one line to stay under the 300-line
  ceiling).
- `lib/orchestrate_save.sh` — Goal 2. Added the three `export TASK=…`,
  `export _CURRENT_MILESTONE=…`, `export MILESTONE_MODE=…` lines
  immediately before the `finalize_run 1` call inside
  `_orch_record_save_state`.

### Audited (no change required)
- `cmd/tekhton/finalize.go` — the Go side already passes `_CURRENT_MILESTONE`
  via the `--milestone` flag and `MILESTONE_MODE` via `--milestone-mode`.
  `TASK` flows through automatically via `os.Environ()` inside
  `internal/finalize/shim.go::BashShimHook.buildEnv` (line 93). Because
  the bash parent now exports TASK, every finalize hook subprocess sees
  it without any Go-side change. No edits needed; AC predicate
  "`TASK`, `_CURRENT_MILESTONE`, and `MILESTONE_MODE` are carried through
  to each hook subprocess" is already true.

## Docs Updated

None — no public-surface changes in this task. CLI flags, config keys,
exported function signatures, and prompt template variables are unchanged.
The change is internal to commit-subject derivation and bash-subprocess
env propagation.

## Acceptance Criteria Verification

- [x] `lib/hooks.sh`'s placeholder-refinement branch picks the file with
      the largest line count from `git diff --stat`, not the alphabetically
      first. Verified by scenario 1 in
      `tests/test_commit_subject_fallback.sh` — subject is
      `feat: changes in big_file.sh` (largest), never points at
      `.claude/project_version.cfg`.

- [x] `_orch_record_save_state` exports `TASK`, `_CURRENT_MILESTONE`, and
      `MILESTONE_MODE` before its `finalize_run 1` call. Verified by the
      grep assertion in `tests/test_commit_subject_fallback.sh`
      (`grep -cE "^[[:space:]]*export (TASK|_CURRENT_MILESTONE|MILESTONE_MODE)" lib/orchestrate_save.sh`
      returns 3).

- [x] When `TASK=""` and `_CURRENT_MILESTONE="m44"` are exported into a
      `tekhton finalize` invocation, the resulting commit subject contains
      the milestone title. Verified by scenario 2 — subject contains
      `Commit Subject Regression`. (The test invokes
      `generate_commit_message` directly with the milestone as `$2`,
      which is what `_hook_commit` does after reading `_CURRENT_MILESTONE`
      from env. The export → env-inheritance → `$2` chain is bash-local
      and tested separately via the grep assertion.)

- [x] A staged-diff containing both `.claude/project_version.cfg` and a
      larger-changeset file never produces a subject ending in
      `.claude/project_version.cfg`. Verified by scenario 1's AC bullet:
      `if echo "$_S1_SUBJECT" | grep -q 'project_version.cfg'; then FAIL`.

- [x] All new tests pass: `tests/test_commit_subject_fallback.sh` — 5/5
      assertions pass.

- [x] No regression in: `tests/test_state_writer_resume_fields.sh` (m40.2)
      still passes; `tests/test_finalize_commit_block_reason.sh` still
      passes; `internal/finalize/...` Go tests still pass (`go test
      ./internal/finalize/... ./cmd/tekhton/...` clean). Full
      `tests/run_tests.sh` summary: Shell 510 pass / 1 fail
      (`test_drift_prompts.sh`); verified pre-existing failure unrelated
      to m44 by running the suite against `git stash` of my changes —
      same failure with the changes stashed.

- [x] `shellcheck lib/hooks.sh lib/orchestrate_save.sh` returns zero warnings.
      Also clean on `tests/test_commit_subject_fallback.sh`.

- [x] `go vet ./cmd/tekhton/...` clean (no Go-side code changes in m44 — the
      milestone's audit of `cmd/tekhton/finalize.go` confirmed no edits
      needed). `golangci-lint run ./cmd/tekhton/...` clean on cmd/tekhton/
      sources — only spurious noise from the user's Go stdlib's
      `chacha20poly1305/fips140only_go1.26.go` file requesting a newer
      compiler than this repo's go.mod targets; unrelated to m44.

## Human Notes Status

No human notes were attached to this milestone.

## Observed Issues (out of scope)

None. The change is narrow and the surrounding `generate_commit_message`
body remains as it was — only the alphabetical `head -1` pick was
replaced. The `_orch_record_save_state` body is otherwise untouched.

## Design Observations

- The milestone's Seeds Forward bullet noted that `_orch_record_save_state`
  commits on every save_exit, producing N commits per arc rather than 1.
  That's out of scope for m44 — m44 only makes those N commits readable.
  A follow-up milestone (m45 in the Seeds Forward) could add a bookkeeping
  allowlist guard around the `finalize_run 1` call to collapse to 1
  commit per arc.

- The milestone design's Goal 3 specified asserting on `git log -1
  --format='%s'`, which implies a full commit was made. The test
  implementation asserts on `generate_commit_message` output instead —
  same subject, no need to spin up the full finalize chain. This keeps
  the test fast (~1s) and self-skip-clean without a tekhton binary, while
  still exercising the exact bash function that produces the subject. The
  AC bullet "`! git log -1 --format='%s' | grep -q project_version.cfg`"
  is satisfied by `! echo "$subject" | grep -q project_version.cfg` —
  the subject is what would have been on `git log`.
