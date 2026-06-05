<!-- milestone-meta
id: "44"
status: "todo"
-->

# m44 — Commit Subject Regression: Stop Falling Back to ".claude/project_version.cfg"

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Every save_exit recovery path commits with a generic, identical subject (`feat: changes in .claude/project_version.cfg`). On the m40.1 and m40.2 arcs, 7 of 9 commits landed with this subject — including the commits that contain the real Go work. Reviewing the branch by `git log --oneline` is now blind: the subject reveals nothing about which arc, stage, or substance the commit holds. |
| **Gap** | `lib/hooks.sh::generate_commit_message` has a placeholder→refine flow that, when `TASK` and `milestone_num` are both empty, fills the subject with the *first file* of `git diff --stat`. `git diff --stat` orders files lexicographically. `.claude/` sorts before `.tekhton/`, and `.claude/project_version.cfg` is bumped on every run, so it is always the first file in every save_exit diff. Compounded by `_orch_record_save_state` calling `finalize_run 1` on every recovery route (clarify abort, build_exhausted, review_exhausted, etc.) — so a single milestone arc fires 3–4 of these commits with identical subjects. |
| **m44 fills** | Two narrow fixes that together restore meaningful subjects on save_exit commits: (1) refine the diff fallback to sort by changeset magnitude rather than alphabetical path order, and (2) make `_orch_record_save_state` export `TASK` and `_CURRENT_MILESTONE` to the `finalize_run 1` subprocess so the higher-quality task-derived subject path runs in the first place. Adds a shim-boundary integration test that drives a save_exit and asserts the resulting commit subject is informative. |
| **Depends on** | m40.2 (`_CURRENT_MILESTONE` propagation depends on the milestone_id state-snapshot field landing first; m40.2 closes that gap) |
| **Files changed** | `lib/hooks.sh`, `lib/orchestrate_save.sh`, `cmd/tekhton/finalize.go`, `tests/test_commit_subject_fallback.sh` |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m40.1 | Snapshot proto: auto-advance fields persist across resume |
| m40.2 | State writer: milestone_id field round-trips so `_hook_commit` sees `MILESTONE_MODE=true` |
| **m44** | **Commit subject regression: save_exit commits fall through to a generic alphabetically-first-file fallback** |

---

## Design

### Sequencing note

This milestone is independent of m36.3 / m39.x. It can land before, between,
or after the stage-port sprint. The fixes are confined to two bash files
and a Go env block; no proto changes. Land it early to stop the
`git log --oneline` blindness on subsequent dogfood arcs.

### Goal 1 — Sort the diff-stat fallback by changeset magnitude

**File:** `lib/hooks.sh` lines 191–197.

Current code (the "refine the placeholder" branch):

```bash
if [[ "$subject" == "${prefix}: changes pending" ]]; then
    local top_changed_file
    top_changed_file=$(echo "$diff_stat" | awk -F'|' 'NR>0 && NF>=2{print $1}' \
        | sed 's/^ *//;s/ *$//' | head -1)
    if [ -n "$top_changed_file" ]; then
        subject="${prefix}: changes in ${top_changed_file}"
    fi
fi
```

`git diff --stat` emits lines in the order it walks the tree, which for the
plumbing porcelain is the same lexicographic order as the index. `.claude/`
< `.tekhton/` < `VERSION` < `cmd/` < `internal/` < `lib/`, so the
`head -1` always returns `.claude/project_version.cfg` on a save_exit diff.

Replace with a sort-by-lines-changed pick that mirrors the same logic
already used later in the same function for the top-5 files block (lines
202–211). The leading `${n}` is the lines-changed count from
`git diff --stat` (second column).

```bash
if [[ "$subject" == "${prefix}: changes pending" ]]; then
    local top_changed_file
    top_changed_file=$(echo "$diff_stat" \
        | awk -F'|' 'NR>0 && NF>=2 {
            raw=$2; sub(/^ +/,"",raw); n=raw+0;
            path=$1; sub(/^ +/,"",path); sub(/ +$/,"",path);
            print n "\t" path
        }' \
        | sort -rn -k1,1 | head -1 | cut -f2-)
    if [ -n "$top_changed_file" ]; then
        subject="${prefix}: changes in ${top_changed_file}"
    fi
fi
```

On the c1a0b36 m40.1-coder-work commit, that would change the subject from
`feat: changes in .claude/project_version.cfg` to
`feat: changes in tests/test_state_writer_resume_fields.sh` (179 lines)
— still not great, but signposts the actual work area.

### Goal 2 — Export `TASK` and `_CURRENT_MILESTONE` across the `finalize_run 1` subprocess on save_exit

**Files:** `lib/orchestrate_save.sh` lines 20–27, `cmd/tekhton/finalize.go`.

`_orch_record_save_state` currently calls `finalize_run 1` without
explicitly exporting `TASK` and `_CURRENT_MILESTONE` to the subprocess.
`finalize_run` in `lib/finalize.sh` execs the Go binary
`tekhton finalize`, which then re-spawns hook subprocesses. The bash
orchestrator's locals do not survive into those subprocesses unless
explicitly exported.

Inside `generate_commit_message` (`lib/hooks.sh` lines 112–127), there
is already a fallback that reads `get_milestone_title "$milestone_num"`
when `TASK` is empty and `milestone_num` is known. That fallback never
fires today because `milestone_num` is *also* empty in the save_exit
subprocess.

Two-part fix:

1. In `lib/orchestrate_save.sh` before the `finalize_run 1` call, export
   the orchestrator's current task + milestone:

   ```bash
   _orch_record_save_state() {
       local outcome="$1"
       local detail="$2"

       _ORCH_ELAPSED=$(( $(date +%s) - _ORCH_START_TIME ))

       # m44: propagate TASK + milestone identity into the finalize
       # subprocess so _hook_commit's generate_commit_message can produce
       # a meaningful subject instead of falling through to the diff-stat
       # fallback. Without these exports, every save_exit commit lands as
       # "feat: changes in <first-file-alphabetically>".
       export TASK="${TASK:-}"
       export _CURRENT_MILESTONE="${_CURRENT_MILESTONE:-}"
       export MILESTONE_MODE="${MILESTONE_MODE:-false}"

       finalize_run 1
       # ...
   }
   ```

2. In `cmd/tekhton/finalize.go`, audit the hook-spawn env block to
   confirm `TASK`, `_CURRENT_MILESTONE`, and `MILESTONE_MODE` are
   carried through to each hook subprocess. The existing `Compose` /
   `AsKV` pipeline already passes a curated env to stage subprocesses;
   the finalize-hook spawn pathway needs the same coverage for these
   three keys.

After this, a m40.1 save_exit commit would land as
`feat: m40.1 — Snapshot Proto: Auto-Advance Fields` (the milestone title
derived via `get_milestone_title`), without depending on the diff fallback
at all.

### Goal 3 — Shim-boundary integration test

**File:** `tests/test_commit_subject_fallback.sh` (new, ~120 lines).

Drive `_orch_record_save_state` with three scenarios and inspect the
resulting commit subject:

1. **Empty TASK, empty milestone, mixed diff** — assert subject contains
   the file with the most lines changed in the diff, NOT
   `.claude/project_version.cfg` (regression guard for Goal 1).
2. **Empty TASK, populated milestone via export** — assert subject is
   derived from `get_milestone_title` (`feat: m44 — Commit Subject…`)
   (regression guard for Goal 2).
3. **Populated TASK, empty milestone** — assert subject reflects TASK
   (existing happy path; smoke check that Goals 1+2 don't regress it).

Follow the m40.2 shim-boundary test pattern at
`tests/test_state_writer_resume_fields.sh` — set up a throwaway repo,
seed the diff, source the necessary libs, drive the function, assert
on `git log -1 --format='%s'`. Self-skip cleanly when the Go binary
isn't built.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `lib/hooks.sh` | Modify | Replace alphabetical `head -1` fallback at lines 191–197 with a sort-by-lines-changed pick that mirrors the top-5 logic at lines 202–211. |
| `lib/orchestrate_save.sh` | Modify | Add `export TASK / _CURRENT_MILESTONE / MILESTONE_MODE` immediately before the `finalize_run 1` call so the subprocess sees them. |
| `cmd/tekhton/finalize.go` | Modify | Audit hook-spawn env block; carry `TASK`, `_CURRENT_MILESTONE`, `MILESTONE_MODE` into each hook subprocess (likely a one-line addition to the env list passed to `internal/finalize.Orchestrator`). |
| `tests/test_commit_subject_fallback.sh` | Create | Three-scenario shim-boundary regression test (see Goal 3). |

---

## Acceptance Criteria

- [ ] `lib/hooks.sh`'s placeholder-refinement branch picks the file with
      the largest line count from `git diff --stat`, not the alphabetically
      first. Verified by `tests/test_commit_subject_fallback.sh` scenario 1.
- [ ] `_orch_record_save_state` exports `TASK`, `_CURRENT_MILESTONE`, and
      `MILESTONE_MODE` before its `finalize_run 1` call. Verified by
      `grep -E "^[[:space:]]*export (TASK|_CURRENT_MILESTONE|MILESTONE_MODE)" lib/orchestrate_save.sh`
      returning three matches inside the `_orch_record_save_state` body.
- [ ] When `TASK=""` and `_CURRENT_MILESTONE="m44"` are exported into a
      `tekhton finalize` invocation, the resulting commit subject contains
      the milestone title (`m44 — Commit Subject…`), not the diff-stat
      fallback. Verified by scenario 2 of the new test.
- [ ] A staged-diff containing both `.claude/project_version.cfg` and at
      least one larger-changeset file never produces a subject ending in
      `.claude/project_version.cfg`. Verified by scenario 1 + a grep
      assertion `! git log -1 --format='%s' | grep -q project_version.cfg`.
- [ ] All new tests pass: `tests/test_commit_subject_fallback.sh`.
- [ ] No regression in: `tests/test_state_writer_resume_fields.sh`,
      `tests/test_finalize_commit_hook.sh` (if present),
      `internal/finalize/...` Go tests.
- [ ] `shellcheck lib/hooks.sh lib/orchestrate_save.sh` returns zero warnings.
- [ ] `golangci-lint run ./cmd/tekhton/...` and `go vet ./cmd/tekhton/...`
      clean after the finalize.go env-block change.

## Watch For

- The fallback refinement happens *after* the existing diff-stat building
  block at lines 173–189 in `lib/hooks.sh`. Don't move the new sort logic
  above that block — `diff_stat` isn't populated yet at that point.
- `awk -F'|'` with the line-count parse must guard against blank lines and
  the summary line (`N files changed, ...`). The existing top-5 logic at
  lines 202–211 already handles this correctly; copy its pattern verbatim
  rather than re-deriving the awk script.
- Exporting `TASK` in `_orch_record_save_state` is a *targeted* export
  for the duration of the `finalize_run` call. It does not need to be a
  global `export` higher up — the `_orch_record_save_state` function body
  is the only callsite that fires finalize_run from a save_exit context.
- The Go side env carry through (`cmd/tekhton/finalize.go`) likely already
  passes `TASK` because stage subprocesses need it. Verify before adding;
  the fix may be bash-only.
- The `feat: changes in .claude/project_version.cfg` subject was *cosmetic*
  — the commit bodies and diffs are correct. This milestone is purely about
  the subject line readability of `git log --oneline`.
- The user dogfood pattern that exposed this (one `tekhton --resume`
  invocation per stage, save_exit between them) means each arc still
  produces N commits. m44 does not collapse N→1 — that's a deeper
  question about whether save_exit should commit at all. Out of scope here.

## Seeds Forward

- **m45 (potential):** Audit whether `_orch_record_save_state` should
  commit on every save_exit, or only when the diff contains
  non-bookkeeping files. A simple bookkeeping-allowlist
  (`.claude/project_version.cfg`, `.tekhton/*`, `VERSION`) check around
  the `finalize_run 1` call would collapse the N-commit pattern to 1.
- **m40.x follow-on (potential):** The root reason `TASK` and
  `_CURRENT_MILESTONE` don't always reach the finalize subprocess is
  that the bash orchestrator's globals do not survive into Go-spawned
  hook subprocesses unless explicitly listed in
  `internal/runner/env.go::AsKV`. m44 adds these to the export surface;
  a future milestone could systematize the env contract across all
  finalize hooks (mirroring the stage-subprocess env contract).
- **m46 (potential):** Conventional-commit subject derivation could
  pull from the *stage* that produced the save_exit
  (`coder`, `review`, `tester`, `intake_clarify`) and produce subjects
  like `feat: m44 — partial (coder → build_exhausted)`. That is a
  larger change to `generate_commit_message`'s signature; m44 keeps
  the function signature stable.
