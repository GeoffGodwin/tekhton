# Milestone 38: Watchtower Live Run & Milestone Map UX Polish
<!-- milestone-meta
id: "38"
status: "pending"
-->

## Overview

The Watchtower Live Run screen has several display fidelity issues: the active
stage indicator lags one stage behind reality (Intake never shows as active,
Scout never lights up), the turns display shows `0/N` which is misleading since
turn counts aren't available until a stage completes, and stage elapsed time —
already tracked in `_STAGE_DURATION` — isn't surfaced. The Milestone Map tab is
also shallow: clicking a milestone reveals only its status and parallel group,
not the rich context needed to understand what it does or how it connects to the
dependency graph.

## Scope

### 1. Fix Active Stage Indicator Lag

**Problem:** When the pipeline enters Intake, the Live Run stage chips show all
stages as `○` (pending). Intake never shows as `●` (active). Once Coder starts,
Intake flips to `✓` and Coder becomes `●` — always one behind. The root cause
is that `emit_dashboard_run_state()` in `lib/dashboard.sh` sets `current_stage`
and `_STAGE_STATUS` but the Intake stage doesn't call the status-update hooks
early enough, and Scout's status is never emitted as a distinct active stage.

**Fix:**
- In `lib/dashboard.sh` (`emit_dashboard_run_state()`), ensure `_STAGE_STATUS`
  for the `current_stage` is always at least `"active"` when emitting. If
  `_STAGE_STATUS[$CURRENT_STAGE]` is empty or `"pending"`, override it to
  `"active"` in the emitted JSON (don't mutate the global).
- In `stages/coder.sh`, ensure `_STAGE_STATUS[intake]` is set to `"active"` at
  the start of the intake phase and `"complete"` before moving to scout/coder.
- In `stages/coder.sh`, ensure `_STAGE_STATUS[scout]` is set to `"active"` when
  scout begins and `"complete"` when scout finishes, with a dashboard emit
  between transitions so watchtower picks it up on the next refresh cycle.
- Verify `statusIcon()` in `templates/watchtower/app.js` (lines 69-75) maps
  `"active"` → `●` correctly (it already does, but confirm).

**Files:** `lib/dashboard.sh`, `stages/coder.sh`

### 2. Replace Turns Display with Stage Elapsed Time

**Problem:** The Live Run detail line shows `turns: 0/70` for the active stage.
The numerator is always 0 during execution because `_STAGE_TURNS` is only
populated after an agent call completes. This makes the display misleading. The
denominator (budget) is useful, but a counter stuck at 0 is not.

**Fix:**
- In `templates/watchtower/app.js`, replace the turns display with elapsed time.
  The data is already available: `_STAGE_DURATION[stg]` is emitted as
  `duration_s` in the stage JSON object (lib/dashboard.sh line 148).
- Format: `Stage: Coder · 3m 42s · budget: 70 turns`
  - Show `duration_s` formatted as `Xm Ys` (or `Xh Ym` for long stages)
  - Show budget as a reference, not a fraction
- In `lib/dashboard.sh`, ensure `_STAGE_DURATION` for the current active stage
  is computed as `$(( SECONDS - _STAGE_START_TS ))` at emit time, not just at
  stage completion. If `_STAGE_START_TS[$CURRENT_STAGE]` exists and the stage
  status is `"active"`, compute live elapsed.
- Keep completed stages showing final `duration_s` and `turns` (actual turns
  used) in their chip tooltip or detail view.

**Files:** `templates/watchtower/app.js`, `lib/dashboard.sh`

### 3. Scout Stage Visibility in Live Run

**Problem:** Scout runs within the Coder stage but has its own entry in
`stageOrder` (line 137 of app.js). During scout execution, the Live Run shows
Scout as a chip before Coder, but it never lights up as active. It appears as
a dead step.

**Fix:**
- Option A (recommended): Make Scout a sub-step of Coder rather than a
  top-level stage chip. Render it as an indented or nested indicator within the
  Coder chip: `[Intake ✓] [Coder ● (Scout ✓)] [Review ○] [Test ○]`
- In `templates/watchtower/app.js`, when rendering stage chips, check if Scout
  is in the stage data. If so, render it as a sub-badge inside the Coder chip
  rather than its own chip. This better reflects the actual pipeline structure
  where Scout is a phase within the Coder stage.
- Alternatively, if Scout is kept as a top-level chip, ensure its
  `_STAGE_STATUS` is properly set to `"active"` and `"complete"` (see fix #1)
  so it lights up correctly.

**Files:** `templates/watchtower/app.js`, `templates/watchtower/style.css`

### 4. Milestone Map Detail Expansion

**Problem:** Clicking a milestone in the Milestone Map shows only `status` and
`parallel_group` (lines 228-229 of app.js). This is nearly useless — users
can't tell what a milestone does without opening the file.

**Fix:**
- Extend the milestone data emitter (`lib/dashboard_emitters.sh` or
  `lib/dashboard.sh`) to include a `summary` field for each milestone. Extract
  the first paragraph of the `## Overview` section from each milestone `.md`
  file (everything between `## Overview` and the next `##` heading, limited to
  300 chars).
- Extend the emitter to include `depends_on` (already in manifest) and
  `enables` (reverse-lookup: which milestones list this ID in their deps).
- In `templates/watchtower/app.js` `renderMilestoneMap()`:
  - Show the `summary` text in the expanded detail view.
  - Show dependency chips in two rows:
    - **Enabled by:** small colored chips (green) for milestones in `depends_on`
    - **Enables:** small colored chips (blue) for milestones in `enables`
  - Chips show milestone ID and are clickable (scroll to that milestone in the
    map and briefly highlight it).
- In `templates/watchtower/style.css`, add styles for:
  - `.milestone-summary` — truncated overview text, muted color
  - `.dep-chip` and `.enables-chip` — small rounded badges with distinct colors
  - `.milestone-highlight` — brief CSS animation for scroll-to highlight

**Files:** `lib/dashboard.sh` or `lib/dashboard_emitters.sh`,
`templates/watchtower/app.js`, `templates/watchtower/style.css`

## Acceptance Criteria

- Intake stage shows `●` (active) on the Live Run screen while intake is running
- Scout stage shows `●` (active) during scout execution (either as sub-step of
  Coder or as its own chip that properly lights up)
- Stage transitions emit dashboard data between each phase so Watchtower picks
  up intermediate states on the next refresh
- Live Run active stage detail shows elapsed time (e.g., `3m 42s`) instead of
  `0/70` turns
- Budget is still shown but as a standalone reference, not a fraction
- Completed stages show actual turns used and final duration
- Milestone Map expanded view shows a summary paragraph from the milestone's
  Overview section
- Milestone Map expanded view shows "Enabled by" dependency chips (green)
- Milestone Map expanded view shows "Enables" forward-dependency chips (blue)
- Dependency chips are clickable and scroll/highlight the target milestone
- Milestone data emitter extracts overview summaries from milestone `.md` files
- Milestone data emitter computes reverse dependency lookup (`enables`)
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n` passes for any modified `.sh` files
- `shellcheck` passes for any modified `.sh` files

## Watch For

- **Emit frequency:** Dashboard emits happen at stage transitions. If emits are
  too infrequent, the Live Run will still appear laggy. Ensure an emit happens
  at: intake start, intake end, scout start, scout end, coder start, etc.
- **Duration computation at emit time:** Computing `SECONDS - _STAGE_START_TS`
  requires `_STAGE_START_TS` to be set at stage entry. Verify all stages set
  this timestamp. For stages that haven't started, `duration_s` should be 0.
- **Milestone file parsing in bash:** Extracting the Overview section requires
  reading each milestone `.md` file. For 40+ milestones, this adds startup
  latency. Cache the summaries in a generated data file rather than parsing on
  every emit cycle.
- **Reverse dependency computation:** The `enables` lookup is an O(N²) scan of
  all manifest entries. With <50 milestones this is fine, but compute it once
  at startup, not per-emit.
- **Scout as sub-step:** If Scout becomes a Coder sub-step in the UI, the
  `stageOrder` array and stage-chip rendering logic both need updating. Ensure
  the Trends per-stage breakdown still counts Scout separately for metrics.

## Seeds Forward

- M39 builds on the action items display improvements
- M40 documents all Watchtower features including these UX changes
- V4 parallel teams (M37) reuses the multi-stage chip pattern for per-team views
