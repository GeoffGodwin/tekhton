#### Milestone 33: Human Mode Completion Loop & State Fidelity

<!-- milestone-meta
id: "33"
status: "pending"
-->

The `--human` flag is broken in six interrelated ways that compound into a
frustrating user experience: the pipeline picks a note, makes a single coder
attempt, hits the turn limit, and exits — telling the user to re-run manually.
The re-run then loses all human-mode context (flag, tag filter, note claim)
because pipeline state persistence doesn't track human-mode metadata. The
resumed run enters milestone mode instead, which changes turn budgets, skips
notes injection, and leaves claimed notes in limbo (`[~]` status, never
resolved). Meanwhile, the scout's coder turn estimate is never adjusted by
adaptive calibration, so it keeps underestimating on every retry.

This milestone fixes all six issues to bring `--human` up to the v3 standard
of deterministic, run-to-completion behavior.

---

### Bug 1: `--human` without `--complete` is single-shot

**Root cause:** `tekhton.sh:1343-1371` — when `HUMAN_MODE=true` and
`COMPLETE_MODE=false` (the default), the pipeline picks ONE note and calls
`_run_pipeline_stages` exactly once. If the coder hits the turn limit, the
code at `stages/coder.sh:789-812` saves state and `exit 1`. There is no
retry loop. The user must manually re-run.

**Expected behavior:** `tekhton --human BUG` should automatically retry
the coder (via the continuation loop) and, if continuations are exhausted,
proceed to review with partial work — exactly as the orchestration loop does
for `--complete` mode. The user should never need to manually re-run a
`--human` invocation unless the failure is non-transient.

**Fix:** When `HUMAN_MODE=true`, imply `COMPLETE_MODE=true` so the pipeline
enters the orchestration loop (`_run_human_complete_loop` for multi-note or
the standard `run_complete_loop` for single-note). This ensures the coder
gets continuation attempts and the full pipeline retry logic applies. Add a
`HUMAN_SINGLE_NOTE` flag to distinguish "process one note to completion"
(current `--human` behavior) from "process all notes" (`--human --complete`).
Both paths use the orchestration loop; the difference is whether the loop
picks a new note after each success.

Files: `tekhton.sh`

---

### Bug 2: Pipeline state doesn't persist HUMAN_MODE or HUMAN_NOTES_TAG

**Root cause:** `lib/state.sh:13-118` — `write_pipeline_state()` writes
exit_stage, exit_reason, resume_flag, task, notes, milestone, pipeline_order,
tester_mode, and orchestration context. It does NOT write `HUMAN_MODE`,
`HUMAN_NOTES_TAG`, or `CURRENT_NOTE_LINE`. These are command-line-derived
variables that vanish on `exit 1`.

**Expected behavior:** When the pipeline saves state after a human-mode run,
the state file must include all human-mode metadata so that a no-argument
resume reconstructs the exact same execution context.

**Fix:** Add three new sections to `write_pipeline_state()`:
```
## Human Mode
${HUMAN_MODE:-false}

## Human Notes Tag
${HUMAN_NOTES_TAG:-}

## Current Note Line
${CURRENT_NOTE_LINE:-}
```

Add corresponding extraction in the resume detection block
(`tekhton.sh:933-937`) and set the variables before `exec`:
```bash
SAVED_HUMAN_MODE=$(awk '/^## Human Mode$/{getline; print; exit}' "$PIPELINE_STATE_FILE")
SAVED_HUMAN_TAG=$(awk '/^## Human Notes Tag$/{getline; print; exit}' "$PIPELINE_STATE_FILE")
SAVED_NOTE_LINE=$(awk '/^## Current Note Line$/{getline; print; exit}' "$PIPELINE_STATE_FILE")
```

Files: `lib/state.sh`, `tekhton.sh`

---

### Bug 3: Resume constructs `--milestone` instead of `--human`

**Root cause:** `stages/coder.sh:790` — when the coder hits the turn limit
with partial work (`IMPLEMENTED_LINES > 3`), the resume flag is hardcoded:
```bash
RESUME_FLAG="--milestone --start-at coder"
```
This ignores `HUMAN_MODE` entirely. The resumed run enters milestone mode
(different turn budgets, `MILESTONE MODE` banner, etc.) instead of human mode.

**Expected behavior:** The resume flag must reflect the original invocation
mode. If `HUMAN_MODE=true`, the resume flag should be:
```bash
RESUME_FLAG="--human${HUMAN_NOTES_TAG:+ $HUMAN_NOTES_TAG} --start-at coder"
```

**Fix:** In every `write_pipeline_state` call in `stages/coder.sh` (lines
487, 530, 578, 609, 647, 703, 803, 839, 878, 913), prefix the resume flag
with `--human [TAG]` when `HUMAN_MODE=true` instead of `--milestone`. Create
a helper function `_build_resume_flag()` that constructs the correct flag
string based on current mode:
```bash
_build_resume_flag() {
    local start_at="${1:-coder}"
    local flag=""
    if [[ "${HUMAN_MODE:-false}" = "true" ]]; then
        flag="--human${HUMAN_NOTES_TAG:+ $HUMAN_NOTES_TAG}"
    elif [[ "${MILESTONE_MODE:-false}" = "true" ]]; then
        flag="--milestone"
    fi
    echo "${flag:+$flag }--start-at $start_at"
}
```
Use this helper in all `write_pipeline_state` calls across `stages/coder.sh`,
`stages/review.sh`, and `stages/tester.sh`.

Files: `stages/coder.sh`, `stages/review.sh`, `stages/tester.sh`, `lib/state.sh`

---

### Bug 4: "Human notes exist but no notes flag set" on resume

**Root cause:** `stages/coder.sh:434-435` — the condition checks
`HUMAN_MODE != true` before printing this warning. On a resumed run where
HUMAN_MODE was lost (Bug 2), this condition is true even though the original
invocation was `--human BUG`.

**Expected behavior:** This message should never appear on a resumed
human-mode run. Fixing Bug 2 (state persistence) and Bug 3 (resume flag)
eliminates this — the resumed run will have `HUMAN_MODE=true` and the
condition at line 432 will be satisfied.

**Fix:** No additional code change needed beyond Bugs 2 and 3. However, add
a defensive log line: if `HUMAN_MODE` is false but the task string contains
`[BUG]`, `[FEAT]`, or `[POLISH]` tags, emit a hint:
```
Tip: This task appears to come from HUMAN_NOTES.md. Did you mean to use --human?
```

Files: `stages/coder.sh`

---

### Bug 5: Human notes count displayed AFTER claim, showing wrong number

**Root cause:** `tekhton.sh:1368` calls `claim_single_note` which marks the
picked note as `[~]`. Then `tekhton.sh:1505` calls `count_human_notes` which
counts only `[ ]` items. By this point the claimed note is `[~]`, so the
count is short by one.

In the user's first run: 2 BUG items existed, one was picked and claimed
(marked `[~]`), then the count showed "1 unchecked [BUG] item(s)" — the
picked note was already excluded from the count.

**Expected behavior:** The pre-flight count should show the number of
unchecked items BEFORE any claiming, so the user sees the full picture:
"2 unchecked [BUG] item(s)" with the picked note highlighted.

**Fix:** Move the `count_human_notes` call and its display (lines 1503-1517)
to BEFORE the `claim_single_note` call (line 1368). Alternatively, capture
the count before claiming:
```bash
# In the HUMAN_MODE single-note block:
CURRENT_NOTE_LINE=$(pick_next_note "$HUMAN_NOTES_TAG")
PRE_CLAIM_COUNT=$(count_human_notes)  # Count before claiming
claim_single_note "$CURRENT_NOTE_LINE"
```
Then use `PRE_CLAIM_COUNT` for the pre-flight display instead of re-counting.

Files: `tekhton.sh`

---

### Bug 6: Notes never resolved after successful resumed run

**Root cause:** Two failures compound:

1. The resumed run has `HUMAN_MODE=false` (Bug 2), so `_hook_resolve_notes`
   in `lib/finalize.sh:102-131` skips the single-note resolution path.

2. The bulk resolution path (`resolve_human_notes` in `stages/coder.sh:600`)
   only runs when `should_claim_notes()` returns true AND `HUMAN_MODE != true`.
   Since `should_claim_notes()` requires `WITH_NOTES=true` OR `HUMAN_MODE=true`
   OR `NOTES_FILTER` set, and none of these are true on resume, bulk resolution
   also skips.

3. The note claimed as `[~]` by the first run is never resolved to `[x]`
   (success) or `[ ]` (failure). It stays as `[~]` indefinitely.

**Expected behavior:** When a resumed run completes the task that originated
from a human note, that note must be marked `[x]`. This requires either:
- Restoring `HUMAN_MODE` and `CURRENT_NOTE_LINE` on resume (Bug 2 fix), OR
- A cleanup sweep that resolves orphaned `[~]` notes after successful runs.

**Fix:** Primary fix is Bug 2 (state persistence). As a safety net, add
orphan detection to `_hook_resolve_notes`:
```bash
# After normal resolution, check for orphaned [~] notes
local orphan_count
orphan_count=$(grep -c '^- \[~\]' HUMAN_NOTES.md 2>/dev/null || echo "0")
if [[ "$orphan_count" -gt 0 ]] && [[ "$exit_code" -eq 0 ]]; then
    warn "Found ${orphan_count} orphaned in-progress note(s) — resolving."
    sed -i 's/^- \[~\]/- [x]/' HUMAN_NOTES.md
fi
```

Files: `lib/finalize.sh`, `lib/notes.sh`

---

### Bug 7: Scout coder estimate not adjusted by adaptive calibration

**Root cause:** `lib/metrics_calibration.sh` — `calibrate_turn_estimate()`
is called for reviewer and tester stages but NOT for the coder stage. The
scout's coder recommendation is applied directly at
`stages/coder.sh:apply_scout_turn_limits` without passing through
calibration. The log confirms:
```
[metrics] Adaptive calibration: reviewer 8 → 11 (adjusted), clamped → 11
[metrics] Adaptive calibration: tester 20 → 10 (adjusted), clamped → 10
```
No calibration line for coder.

When the scout says `coder=25` and the coder actually needs 99 turns (across
continuations), that historical data should inflate future scout estimates.
Instead, the next scout says `coder=25` again.

**Expected behavior:** The scout's coder turn recommendation should pass
through `calibrate_turn_estimate("coder", recommended_turns)` before being
applied. Historical overshoot should increase the estimate; historical
undershoot should decrease it.

**Fix:** In `stages/coder.sh`, after `apply_scout_turn_limits` sets
`ADJUSTED_CODER_TURNS`, apply adaptive calibration:
```bash
if [[ "${METRICS_ADAPTIVE_TURNS:-true}" = "true" ]]; then
    local calibrated
    calibrated=$(calibrate_turn_estimate "$ADJUSTED_CODER_TURNS" "coder")
    if [[ "$calibrated" != "$ADJUSTED_CODER_TURNS" ]]; then
        log "[metrics] Adaptive calibration: coder ${ADJUSTED_CODER_TURNS} → ${calibrated} (adjusted)"
        ADJUSTED_CODER_TURNS="$calibrated"
    fi
fi
```

Also verify that `calibrate_turn_estimate` handles the "coder" stage name
correctly — it must map to `scout_est_coder` (estimate) vs `coder_turns`
(actual) in the metrics JSONL.

Files: `stages/coder.sh`, `lib/metrics_calibration.sh` (verify coder mapping)

---

Files to create:
- None

Files to modify:
- `tekhton.sh` — Human-mode orchestration loop entry, pre-flight count
  ordering, resume state restoration
- `lib/state.sh` — Persist HUMAN_MODE, HUMAN_NOTES_TAG, CURRENT_NOTE_LINE
- `stages/coder.sh` — Use `_build_resume_flag()` helper, apply coder
  calibration, defensive hint for orphaned human tasks
- `stages/review.sh` — Use `_build_resume_flag()` helper in state writes
- `stages/tester.sh` — Use `_build_resume_flag()` helper in state writes
- `lib/finalize.sh` — Orphaned `[~]` note detection and resolution
- `lib/metrics_calibration.sh` — Verify coder stage mapping exists

Acceptance criteria:
- `tekhton --human BUG` enters the orchestration loop (no manual re-run needed)
- Coder gets continuation attempts on turn exhaustion in human mode
- Pipeline state file contains `## Human Mode`, `## Human Notes Tag`,
  `## Current Note Line` sections
- No-argument resume of a human-mode run restores HUMAN_MODE and HUMAN_NOTES_TAG
- Resume flag includes `--human [TAG]` instead of `--milestone` for human-mode runs
- "Human notes exist but no notes flag set" never appears on a human-mode resume
- Pre-flight count shows number of unchecked items BEFORE claiming
- Successful completion marks the claimed note as `[x]`
- Orphaned `[~]` notes are resolved on successful pipeline completion
- Scout's coder turn estimate passes through adaptive calibration
- Historical coder overshoot inflates future coder estimates
- `calibrate_turn_estimate "25" "coder"` returns a higher value when
  historical coder runs averaged 50+ turns with 25-turn estimates
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n tekhton.sh lib/state.sh stages/coder.sh lib/finalize.sh` passes
- `shellcheck tekhton.sh lib/state.sh stages/coder.sh lib/finalize.sh` passes

Watch For:
- `_run_human_complete_loop` processes ALL matching notes in a loop. The new
  single-note orchestration path must exit after completing ONE note, not loop
  to pick the next one. Use a `HUMAN_SINGLE_NOTE=true` flag to distinguish.
- `claim_single_note` marks `[ ] → [~]`. If the orchestration loop retries
  the same note, the second attempt must not re-claim (it's already `[~]`).
  Check for idempotency in `claim_single_note`.
- The resume `exec` at line 975 replaces the process. Environment variables
  set before `exec` are inherited. Consider exporting `HUMAN_MODE` and
  `HUMAN_NOTES_TAG` before the `exec` rather than relying solely on
  command-line flags in the resume command.
- `calibrate_turn_estimate` uses `scout_est_coder` and `coder_turns` fields
  from METRICS.jsonl. Verify these fields are actually populated by
  `lib/metrics.sh` — if the field names differ, calibration will silently
  return the unadjusted value.
- The `--human` flag and `--milestone` flag should be mutually exclusive.
  If both are somehow set, `--human` should take precedence. Add a guard.
- Continuation turns (`ACTUAL_CODER_TURNS`) accumulate across continuations
  (e.g., 25+25+25+21=96). The metrics record must store the TOTAL turns,
  not just the last segment, for calibration to be accurate. Verify
  `ACTUAL_CODER_TURNS` is exported correctly after continuations.

Seeds Forward:
- The `_build_resume_flag()` helper centralizes resume flag construction,
  making it trivial to add new modes (e.g., `--express` resume) later
- Human-mode state persistence enables future features like "pause and
  resume a multi-note session across terminal restarts"
- Coder adaptive calibration closes the feedback loop between scout
  estimation and actual coder behavior, improving cost efficiency for
  all pipeline modes — not just human mode

Migration impact:
- New config keys: NONE
- New files in .claude/: NONE
- Breaking changes: `--human` now implies `--complete` behavior (orchestration
  loop). Users who relied on single-shot `--human` for quick testing can use
  `--human --no-complete` (add this flag if needed, but default should be
  run-to-completion)
- State file format: additive (3 new sections). Old state files without these
  sections resume with `HUMAN_MODE=false` — backward compatible
- Migration script update required: NO
