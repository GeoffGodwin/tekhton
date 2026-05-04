# Milestone 90: Auto-Advance Fix — Count Argument & State-File Lifecycle
<!-- milestone-meta
id: "90"
status: "done"
-->

## Overview

`--auto-advance` is broken in two independent ways. First, there is no way to
specify how many milestones to advance — the count can only be set in
`pipeline.conf` as `AUTO_ADVANCE_LIMIT`, making the CLI flag much less useful
than intended. Second, the advance chain never actually runs beyond the starting
milestone because `finalize_run` deletes `MILESTONE_STATE_FILE` before
`_run_auto_advance_chain` is called, causing `should_auto_advance` to return
false on the very first loop iteration.

The desired behaviour after this milestone: `tekhton --auto-advance 5 "M05"`
starts at M05 and continues through M06 → M07 → M08 → M09 → M10 (the initial
milestone plus five more). `tekhton --auto-advance 3 "M05"` runs M05 through M08.
Both the milestone files (status metadata) and `MANIFEST.cfg` are correctly
updated throughout.

## Bug Details

### Bug 1 — No CLI count argument

`--auto-advance` consumes only the boolean flag. Any integer that follows it is
silently consumed as the task string instead:

```bash
# tekhton.sh ~line 1315
--auto-advance)
    AUTO_ADVANCE=true
    MILESTONE_MODE=true
    apply_milestone_overrides
    shift
    ;;
```

`AUTO_ADVANCE_LIMIT` (default: 3) is the only way to control the count, and it
requires editing `pipeline.conf`.

### Bug 2 — `MILESTONE_STATE_FILE` deleted before the advance chain runs

In `run_complete_loop` (lib/orchestrate.sh), the success path is:

```
1. should_auto_advance()   → reads MILESTONE_STATE_FILE disposition  → OK
2. _should_advance=true    → cached decision
3. finalize_run 0          → _hook_clear_state → rm MILESTONE_STATE_FILE
4. _run_auto_advance_chain → while should_auto_advance; do ...
```

Inside the while condition, `should_auto_advance` calls `get_milestone_disposition`
which reads `MILESTONE_STATE_FILE`. The file is already gone, so the function
returns `"NONE"`, the condition is false, and the loop body never executes.
The advance chain returns immediately without ever moving to the next milestone.

### Bug 3 — `advance_milestone` also requires the deleted state file

`advance_milestone` awk-transforms `MILESTONE_STATE_FILE` to increment the
session counter and update the current milestone number. Without the file,
the transform produces nothing, leaving the state file empty or absent for the
next iteration.

## Design Decisions

### 1. Optional integer argument after `--auto-advance`

The parser peeks at the next argument after the flag. If it is a bare integer
(`[0-9]+`), it is consumed as `AUTO_ADVANCE_LIMIT`. If not, the argument is
left on the stack for normal task-string parsing. This is additive — existing
`pipeline.conf`-only usage continues to work.

### 2. In-memory session counter `_AA_SESSION_ADVANCES`

Rather than reading the session count from the (deleted) state file, the number
of milestones completed in this invocation is tracked in a shell variable
`_AA_SESSION_ADVANCES`. It is initialised to `0` before the first pipeline run,
incremented in `_run_auto_advance_chain` before each `advance_milestone` call,
and exported so recursive `run_complete_loop` invocations share the same counter.

### 3. State file re-initialised before each advance

When `_run_auto_advance_chain` is ready to advance to milestone N+1, it calls
`init_milestone_state "$next_ms" "$_total"` to recreate `MILESTONE_STATE_FILE`
for the new milestone before invoking `run_complete_loop`. This means every
milestone run starts with a fresh, valid state file just as a first-run does.

### 4. `should_auto_advance` uses `_AA_SESSION_ADVANCES` for limit checking

The limit guard in `should_auto_advance` switches from `get_milestones_completed_this_session`
(reads state file) to `${_AA_SESSION_ADVANCES:-0}` (in-memory). The disposition
check (`COMPLETE_AND_CONTINUE`) is still read from the state file when it exists
(pre-finalize call site in `run_complete_loop`) and skipped when it does not
(post-finalize call site in `_run_auto_advance_chain`).

### 5. MANIFEST.cfg and milestone file metadata are not changed

`mark_milestone_done` → `emit_milestone_metadata` → `dag_set_status` +
`save_manifest` already correctly updates both the milestone `.md` status field
and `MANIFEST.cfg` during `finalize_run`. No changes needed in that path.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Shell files modified | 4 | `tekhton.sh`, `lib/milestone_ops.sh`, `lib/orchestrate_helpers.sh`, `lib/milestones.sh` |
| Config modified | 0 | `AUTO_ADVANCE_LIMIT` default unchanged |
| Tests modified | 1 | `tests/test_milestones.sh` — new advance-chain cases |
| New data files | 0 | — |

## Implementation Plan

### Step 1 — tekhton.sh: parse optional count after `--auto-advance`

In the argument-parsing `case` block, peek at `$1` after the flag shift. If it
matches `^[0-9]+$`, consume it as `AUTO_ADVANCE_LIMIT` and shift again:

```bash
--auto-advance)
    AUTO_ADVANCE=true
    MILESTONE_MODE=true
    apply_milestone_overrides
    shift
    if [[ $# -gt 0 ]] && [[ "$1" =~ ^[0-9]+$ ]]; then
        AUTO_ADVANCE_LIMIT="$1"
        shift
    fi
    ;;
```

Also update the `--help` description to document the optional count parameter.

### Step 2 — tekhton.sh: initialise `_AA_SESSION_ADVANCES`

In the auto-advance initialisation block (around line 1995), set and export
`_AA_SESSION_ADVANCES=0` when `AUTO_ADVANCE=true`:

```bash
if [ "$AUTO_ADVANCE" = true ]; then
    AUTO_ADVANCE_ENABLED=true
    export AUTO_ADVANCE_ENABLED
    _AA_SESSION_ADVANCES=0
    export _AA_SESSION_ADVANCES
    ...
fi
```

### Step 3 — lib/milestone_ops.sh: fix `should_auto_advance`

Replace the `get_milestones_completed_this_session` call and the hard
`COMPLETE_AND_CONTINUE` disposition guard:

```bash
should_auto_advance() {
    [[ "${AUTO_ADVANCE_ENABLED:-false}" == "true" ]] || return 1

    local completed="${_AA_SESSION_ADVANCES:-0}"
    local limit="${AUTO_ADVANCE_LIMIT:-3}"

    if [[ "$completed" -ge "$limit" ]]; then
        log "Auto-advance limit reached (${completed}/${limit})"
        return 1
    fi

    # Only check disposition when the state file is still present.
    # After finalize_run deletes it, skip the check — the caller (_run_auto_advance_chain)
    # already owns the advance decision.
    if [[ -f "${MILESTONE_STATE_FILE:-}" ]]; then
        local disposition
        disposition=$(get_milestone_disposition)
        [[ "$disposition" == "COMPLETE_AND_CONTINUE" ]] || return 1
    fi

    return 0
}
```

### Step 4 — lib/orchestrate_helpers.sh: fix `_run_auto_advance_chain`

Before calling `advance_milestone` and `run_complete_loop`, re-initialise the
state file and increment `_AA_SESSION_ADVANCES`:

```bash
_run_auto_advance_chain() {
    while should_auto_advance 2>/dev/null; do
        local next_ms
        next_ms=$(find_next_milestone "$_CURRENT_MILESTONE" "CLAUDE.md")
        if [[ -z "$next_ms" ]]; then
            log "No more milestones to advance to."
            break
        fi

        local next_title
        next_title=$(get_milestone_title "$next_ms")

        if [[ "${AUTO_ADVANCE_CONFIRM:-true}" = "true" ]]; then
            if ! prompt_auto_advance_confirm "$next_ms" "$next_title"; then
                log "Auto-advance declined by user."
                break
            fi
        fi

        # Increment the in-memory session counter BEFORE advance_milestone so
        # the transition banner shows the correct completed count.
        _AA_SESSION_ADVANCES=$(( ${_AA_SESSION_ADVANCES:-0} + 1 ))
        export _AA_SESSION_ADVANCES

        # Recreate the state file for the new milestone (finalize_run deleted it).
        local _total
        _total=$(get_milestone_count "CLAUDE.md")
        init_milestone_state "$next_ms" "$_total"

        advance_milestone "$_CURRENT_MILESTONE" "$next_ms"
        _CURRENT_MILESTONE="$next_ms"
        TASK="Implement Milestone ${_CURRENT_MILESTONE}: ${next_title}"
        START_AT="coder"

        _ORCH_REVIEW_BUMPED=false
        _ORCH_ATTEMPT=0
        _ORCH_NO_PROGRESS_COUNT=0
        _ORCH_LAST_ACCEPTANCE_HASH=""
        _ORCH_IDENTICAL_ACCEPTANCE_COUNT=0

        emit_milestone_metadata "$_CURRENT_MILESTONE" "in_progress" || true
        if command -v emit_dashboard_milestones &>/dev/null; then
            emit_dashboard_milestones 2>/dev/null || true
        fi

        run_complete_loop
        return $?
    done
}
```

### Step 5 — lib/milestones.sh: update `advance_milestone` session count display

`advance_milestone` reads the session count from the state file to print the
transition banner. After this fix the state file is freshly initialised (count 0)
when `advance_milestone` is called, so use `_AA_SESSION_ADVANCES` when set:

```bash
advance_milestone() {
    ...
    local completed_count
    if [[ -n "${_AA_SESSION_ADVANCES:-}" ]]; then
        completed_count="${_AA_SESSION_ADVANCES}"
    else
        completed_count=$(get_milestones_completed_this_session)
        completed_count=$(( completed_count + 1 ))
    fi
    ...
}
```

### Step 6 — tests/test_milestones.sh: new advance-chain test cases

Add test cases that verify:
- `should_auto_advance` returns true when `_AA_SESSION_ADVANCES=0` and limit is 3
- `should_auto_advance` returns false when `_AA_SESSION_ADVANCES=3` and limit is 3
- `should_auto_advance` returns true when state file is absent (no disposition check)
- `advance_milestone` uses `_AA_SESSION_ADVANCES` for the banner count when set

### Step 7 — Shellcheck and test

```bash
shellcheck tekhton.sh lib/milestone_ops.sh lib/orchestrate_helpers.sh lib/milestones.sh
bash tests/run_tests.sh
```

## Files Touched

### Modified
- `tekhton.sh` — `--auto-advance` CLI argument parsing (count), init `_AA_SESSION_ADVANCES`
- `lib/milestone_ops.sh` — `should_auto_advance`: in-memory counter, conditional disposition check
- `lib/orchestrate_helpers.sh` — `_run_auto_advance_chain`: state-file re-init, counter increment
- `lib/milestones.sh` — `advance_milestone`: display uses `_AA_SESSION_ADVANCES` when set
- `tests/test_milestones.sh` — new test cases for fixed advance-chain behaviour

## Acceptance Criteria

- [ ] `tekhton --auto-advance 5 "M05"` passes `5` as `AUTO_ADVANCE_LIMIT`; subsequent run with no count falls back to the `pipeline.conf`/default value
- [ ] `tekhton --auto-advance "M05"` (no count) continues to work exactly as before
- [ ] `should_auto_advance` returns false when `_AA_SESSION_ADVANCES` equals `AUTO_ADVANCE_LIMIT`, regardless of whether `MILESTONE_STATE_FILE` exists
- [ ] `should_auto_advance` returns true when `_AA_SESSION_ADVANCES` is below the limit and `MILESTONE_STATE_FILE` is absent (no disposition check performed)
- [ ] After first milestone completes and `finalize_run` runs, `_run_auto_advance_chain` enters the while loop and advances to the next milestone (not a no-op)
- [ ] `_run_auto_advance_chain` re-creates `MILESTONE_STATE_FILE` for the new milestone before calling `run_complete_loop`
- [ ] `_AA_SESSION_ADVANCES` is incremented for each milestone advanced in a single invocation
- [ ] `MANIFEST.cfg` status for each completed milestone is updated to `done` (existing path, not regressed)
- [ ] Milestone `.md` file `status` metadata field reflects `done` for each completed milestone (existing path, not regressed)
- [ ] **Behavioral:** A dry-run trace of `_run_auto_advance_chain` with a 3-milestone sequence shows all three `run_complete_loop` calls reaching the advance logic, not short-circuiting on the first
- [ ] `shellcheck tekhton.sh lib/milestone_ops.sh lib/orchestrate_helpers.sh lib/milestones.sh` reports zero warnings
- [ ] `bash tests/run_tests.sh` passes
