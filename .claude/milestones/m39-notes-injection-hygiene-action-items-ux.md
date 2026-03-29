# Milestone 39: Notes Injection Hygiene & Action Items UX
<!-- milestone-meta
id: "39"
status: "pending"
-->

## Overview

Human notes and non-blocking notes are injected into agent prompts on nearly
every run, even though they're only actionable when specific flags (`--human`,
`--fix-nonblockers`) are used. This wastes context tokens and confuses agents
with information they can't act on. Additionally, the action items section at
the end of a pipeline run is always cyan/blue regardless of severity, giving no
visual signal when the non-blocking backlog is approaching a dangerous threshold.
This milestone tightens injection criteria, gates notes behind their respective
flags, and adds progressive color warnings to the action items display.

## Scope

### 1. Gate Human Notes Injection Behind `--human` Flag

**Problem:** `extract_human_notes()` in `lib/notes.sh` is called during prompt
assembly in `stages/coder.sh` (line 282) on every run. The resulting
`HUMAN_NOTES_BLOCK` is injected into the coder prompt via the template engine.
On non-`--human` runs, this block is present in the prompt but serves no purpose
— the coder isn't tasked with addressing those notes and typically ignores them.
This wastes context tokens (often 500-2000 chars) and occasionally causes agents
to start "fixing" human notes they weren't asked to address.

**Fix:**
- In `lib/prompts.sh` or wherever `HUMAN_NOTES_BLOCK` / `HUMAN_NOTES_CONTENT`
  are set for template substitution: only populate these variables when
  `HUMAN_MODE=true`.
- When `HUMAN_MODE=false`, set `HUMAN_NOTES_BLOCK=""` and
  `HUMAN_NOTES_CONTENT=""` so the template `{{IF:HUMAN_NOTES_BLOCK}}` blocks
  produce no output.
- Ensure the `--with-notes` flag (which explicitly opts in to notes on a
  non-human run) still works: if `WITH_NOTES=true`, populate the variables
  even when `HUMAN_MODE=false`.
- Update the pipeline log message that says "Human notes injected into prompt"
  to only appear when injection actually happens.

**Files:** `lib/notes.sh`, `lib/prompts.sh`, `stages/coder.sh`

### 2. Gate Non-Blocking Notes Injection Behind `--fix-nonblockers` Flag

**Problem:** In `stages/coder.sh` (lines 384-400), non-blocking notes from
`NON_BLOCKING_LOG.md` are injected as a context component when the count exceeds
`NON_BLOCKING_INJECTION_THRESHOLD` (default 8). This happens on regular milestone
runs, human-notes runs, and ad hoc runs — not just `--fix-nonblockers` runs. The
injected notes waste context and occasionally cause agents to address non-blocking
items unprompted, muddying the scope of the current task.

**Fix:**
- Only inject non-blocking notes into the coder prompt when
  `FIX_NONBLOCKERS_MODE=true`.
- Remove or gate the threshold-based injection logic. The threshold concept was
  meant to surface urgent debt, but the action items display (Scope §3) now
  handles urgency signaling visually.
- Keep the `count_open_nonblocking_notes()` call for the action items display
  but don't build the context component unless in fix-nonblockers mode.
- The non-blocking notes count should still be logged for observability:
  `info "Non-blocking notes: ${nb_count} open (injection skipped — not in --fix-nonblockers mode)"`

**Files:** `stages/coder.sh`, `lib/drift_cleanup.sh`

### 3. Progressive Color Action Items Display

**Problem:** The action items section in `lib/finalize_display.sh`
(`_print_action_items()`) uses a fixed cyan color (ℹ) for non-blocking notes
and yellow (⚠) for human notes, regardless of quantity. A backlog of 3
non-blocking items and a backlog of 30 look identical. There's no escalating
visual urgency.

**Fix:**
- Define three severity thresholds for non-blocking notes:
  - **Normal** (count < `CLEANUP_TRIGGER_THRESHOLD`, default 5): cyan/blue ℹ
  - **Warning** (count >= threshold but < 2× threshold): yellow ⚠
  - **Critical** (count >= 2× threshold): red ✗
- Apply the same logic to human notes (using a separate threshold, default 10).
- For the critical (red) level, append a suggested command:
  ```
  ✗ NON_BLOCKING_LOG.md — 14 accumulated observation(s) [CRITICAL]
    → Suggested: tekhton --fix-nonblockers --complete
  ```
- For human notes at critical level:
  ```
  ✗ HUMAN_NOTES.md — 22 item(s) remaining [CRITICAL]
    → Suggested: tekhton --human --complete
  ```
- Use the existing color functions from `lib/common.sh` (`red`, `yellow`,
  `cyan`, `bold`).
- Add config keys for the thresholds:
  - `ACTION_ITEMS_WARN_THRESHOLD` (default: `CLEANUP_TRIGGER_THRESHOLD` or 5)
  - `ACTION_ITEMS_CRITICAL_THRESHOLD` (default: 2× warn threshold or 10)
  - `HUMAN_NOTES_WARN_THRESHOLD` (default: 10)
  - `HUMAN_NOTES_CRITICAL_THRESHOLD` (default: 20)

**Files:** `lib/finalize_display.sh`, `lib/config_defaults.sh`, `lib/config.sh`

### 4. Watchtower Action Items Color Sync

**Problem:** The Watchtower Reports tab or post-run summary may also display
action item counts. These should match the progressive color scheme from the
CLI output.

**Fix:**
- In `lib/dashboard_emitters.sh`, extend the action items data to include a
  `severity` field (`"normal"`, `"warning"`, `"critical"`) computed from the
  same thresholds.
- In `templates/watchtower/app.js`, use the severity field to apply CSS classes:
  - `.action-normal` — existing blue/cyan styling
  - `.action-warning` — yellow/amber background
  - `.action-critical` — red background with suggested command text
- In `templates/watchtower/style.css`, add the warning/critical styles.

**Files:** `lib/dashboard_emitters.sh`, `templates/watchtower/app.js`,
`templates/watchtower/style.css`

## Acceptance Criteria

- Human notes (`HUMAN_NOTES_BLOCK`, `HUMAN_NOTES_CONTENT`) are NOT injected
  into agent prompts when `HUMAN_MODE=false` and `WITH_NOTES=false`
- Human notes ARE injected when `HUMAN_MODE=true` or `WITH_NOTES=true`
- Non-blocking notes are NOT injected as a context component on regular
  milestone runs or ad hoc runs
- Non-blocking notes ARE injected when `FIX_NONBLOCKERS_MODE=true`
- Pipeline log shows "injection skipped" message when notes are present but
  not injected
- Action items display uses cyan for low counts, yellow for moderate, red for
  high (threshold-based)
- Red-level action items include a suggested `tekhton` command
- Thresholds are configurable via `pipeline.conf`
- Watchtower action items reflect the same severity coloring as CLI output
- `--with-notes` flag still works as an explicit opt-in for notes injection
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n` passes for any modified `.sh` files
- `shellcheck` passes for any modified `.sh` files
- No regressions in `--human` mode behavior
- No regressions in `--fix-nonblockers` mode behavior

## Watch For

- **`--with-notes` interaction:** The `--with-notes` flag explicitly opts into
  notes injection even on non-human runs. Don't break this path. The gate
  logic should be: `if HUMAN_MODE || WITH_NOTES; then inject; fi`.
- **Template conditionals:** `{{IF:HUMAN_NOTES_BLOCK}}` blocks in prompt
  templates will naturally produce no output when the variable is empty. But
  verify that an empty variable doesn't leave stray whitespace or blank lines
  in the rendered prompt.
- **Threshold defaults:** `CLEANUP_TRIGGER_THRESHOLD` already exists (default 5)
  and is used for triggering autonomous debt sweeps. Reuse it as the warn
  threshold for action items rather than introducing a duplicate concept.
- **Color function availability:** `lib/common.sh` defines `red()`, `yellow()`,
  `cyan()`, etc. Ensure `finalize_display.sh` sources `common.sh` (it already
  does via the standard source chain).
- **Non-blocking count during --fix-nonblockers:** When in fix-nonblockers mode,
  the count naturally decreases across iterations. The action items display at
  the end of each iteration should reflect the updated count.

## Seeds Forward

- M40 documents the notes injection behavior and action items color scheme
- The severity thresholds feed into future Watchtower dashboard health indicators
- The gated injection pattern could be extended to other context components
  (drift log, architecture log) for further token savings
