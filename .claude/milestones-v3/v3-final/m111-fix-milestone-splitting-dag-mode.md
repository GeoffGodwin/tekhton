# M111 - Fix Milestone Splitting for DAG Mode

<!-- milestone-meta
id: "111"
status: "done"
-->

## Overview

Milestone splitting (`check_milestone_size`, `split_milestone`, `handle_null_run_split`
in `lib/milestone_split.sh`) was originally written for inline milestones stored in
CLAUDE.md. Since M01 made the DAG manifest + individual milestone files the default,
splitting has been silently broken: the feature never runs in production use. Three
compounding bugs prevent it from working end-to-end.

## Design

### Bug 1 — Extraction reads CLAUDE.md (primary blocker)

`split_milestone()` calls `_extract_milestone_block "$milestone_num" "$claude_md"` (~line 113)
to fetch the milestone definition before invoking the splitting agent.
`_extract_milestone_block` (in `lib/milestone_archival_helpers.sh`) only reads from a flat
CLAUDE.md-style file. In DAG mode CLAUDE.md has no milestone content, so extraction always
returns 1, aborting before any further logic runs.

**Fix:** In `split_milestone()`, check `has_milestone_manifest` before calling
`_extract_milestone_block`. If true, resolve the file via:

```bash
local dag_id
dag_id=$(dag_number_to_id "$milestone_num")
local dag_file
dag_file=$(dag_get_file "$dag_id")
milestone_def=$(cat "${milestone_dir}/${dag_file}")
```

Fall back to `_extract_milestone_block` only when DAG is not active. Callers in
`stages/coder.sh` (~lines 277, 715, 762, 972, 1032) and `lib/intake_verdict_handlers.sh`
(~lines 77, 108) all pass `"CLAUDE.md"` hardcoded — no changes needed there once
extraction is DAG-aware.

### Bug 2 — Sub-milestones appended to end of manifest

After parsing sub-milestones from agent output, the DAG branch executes `_DAG_IDS+=`
which appends them at the end of all parallel arrays. `save_manifest` then writes them
after every other milestone in the manifest. `dag_find_next` uses array index order for
sequencing, so sub-milestones would be scheduled last rather than immediately after
their parent.

**Fix:** After the sub-milestone parsing loop, splice the new entries into the arrays
immediately after the parent's position:

1. Record `parent_idx="${_DAG_IDX[$parent_id]}"`.
2. Rebuild all six `_DAG_*` arrays by inserting the new sub-milestone entries at
   index `parent_idx + 1` (using temp arrays and a loop).
3. Recompute `_DAG_IDX` for all entries at indices `> parent_idx` by incrementing
   each by the number of inserted sub-milestones.
4. Set `_DAG_IDX[$sub_id]` for each new entry.

This is the only way `save_manifest` writes MANIFEST.cfg with sub-milestones in the
correct sequential position.

### Bug 3 — "split" parent re-enters the execution frontier

`dag_get_frontier()` in `lib/milestone_dag.sh` skips only milestones with status
`"done"`. After splitting, the parent is marked `"split"` — but since `"split" != "done"`,
it remains eligible for the frontier and competes with its own sub-milestones for
scheduling. The pipeline would attempt to re-run the original unsplit milestone.

**Fix:** In `dag_get_frontier()`, add one condition:

```bash
if [[ "${_DAG_STATUSES[$i]}" == "done" ]] || [[ "${_DAG_STATUSES[$i]}" == "split" ]]; then
    continue
fi
```

No change to `dag_deps_satisfied()` is needed — the first sub-milestone's dependency
is set to the parent's original deps (not the parent itself), so there is no deadlock.

### Sub-milestone ID and file naming

The existing code already produces correct radix notation:

- `sub_num` parsed from agent output (e.g. `"110.1"`, `"110.2"`)
- `sub_id` formatted as `printf "m%02d%s" "$sub_main" "$sub_suffix"` → `m110.1`, `m110.2`
- `sub_file` → `m110.1-<slug>.md`, `m110.2-<slug>.md`

No changes needed to the ID or file naming logic.

## Files Modified

| File | Change |
|------|--------|
| `lib/milestone_split.sh` | Bug 1: DAG-aware extraction before `_extract_milestone_block`; Bug 2: splice sub-milestones after parent index instead of appending; recompute `_DAG_IDX` |
| `lib/milestone_dag.sh` | Bug 3: skip `"split"` status in `dag_get_frontier()` |

## Acceptance Criteria

- [ ] With `MILESTONE_DAG_ENABLED=true`, `split_milestone` successfully reads the
      milestone definition from the DAG file rather than CLAUDE.md.
- [ ] After a split, sub-milestone files (`m<N>.<sub>-<slug>.md`) appear in
      `.claude/milestones/`.
- [ ] After a split, MANIFEST.cfg contains the sub-milestone rows immediately after
      the parent row, not at the end of the file.
- [ ] The parent milestone row has status `split` in MANIFEST.cfg after splitting.
- [ ] The parent milestone with status `split` does not appear in subsequent pipeline
      runs (it is skipped by the frontier logic).
- [ ] Sub-milestones execute in radix order (`<N>.1` before `<N>.2`) and respect
      their chained dependency chain.
- [ ] The inline (non-DAG) split path is unaffected and continues to write to CLAUDE.md.
- [ ] Null-run auto-split (`handle_null_run_split`) works correctly in DAG mode.
- [ ] Oversized-milestone pre-flight split (`check_milestone_size` → `split_milestone`)
      works correctly in DAG mode.
