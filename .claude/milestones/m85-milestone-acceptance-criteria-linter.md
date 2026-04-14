# Milestone 85: Milestone Acceptance Criteria Linter
<!-- milestone-meta
id: "85"
status: "done"
-->

## Overview

M72's post-mortem revealed that its acceptance criteria were entirely
verification-based ("did we do what the spec says?") with zero validation
criteria ("did we achieve the actual goal?"). The spec itself was incomplete,
so perfect verification still shipped bugs.

This milestone introduces an automated linter for milestone acceptance criteria
that warns when criteria patterns are insufficient. The linter runs during
`check_milestone_acceptance()` as a pre-check, flagging structural weaknesses
before the milestone is accepted as done.

The linter is not a gate (it cannot know whether criteria are truly sufficient),
but a warning system that surfaces common anti-patterns: all-structural criteria
with no behavioral checks, refactor milestones with no completeness greps,
config-affecting milestones with no self-referential checks.

## Design Decisions

### 1. Warning-only, not blocking

The linter emits warnings to the non-blocking log, not blocking errors. False
positives are likely (some milestones genuinely need only structural criteria),
and blocking on a heuristic would cause more friction than value. The warnings
are visible in the milestone acceptance output and in the Watchtower dashboard.

### 2. Pattern-based detection

The linter uses simple pattern matching on acceptance criteria text:
- **Behavioral criterion detection:** looks for keywords like "run", "execute",
  "verify at runtime", "observe", "produces no", "creates zero" — patterns
  that indicate the criterion checks actual behavior, not just code structure.
- **Completeness grep detection:** looks for `grep`, `zero.*literal`,
  `no.*remaining`, `no.*occurrences` patterns in refactor-tagged milestones.
- **Self-referential detection:** looks for `pipeline.conf`, `config_defaults`,
  `self-referential`, `own configuration` patterns in config-tagged milestones.

### 3. Milestone category inference

The linter infers the milestone category from content keywords:
- "refactor", "migrate", "move", "rename", "parameterize" → refactor milestone
- "config", "variable", "default", "pipeline.conf" → config milestone
- No inference needed for the behavioral criterion check (universal).

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| New library file | 1 | `lib/milestone_acceptance_lint.sh` |
| Integration point | 1 | `lib/milestone_acceptance.sh` |
| Warning categories | 3 | behavioral, completeness, self-referential |
| Tests | 1 | `tests/test_milestone_acceptance_lint.sh` |

## Implementation Plan

### Step 1 — Create lib/milestone_acceptance_lint.sh

Implement three lint functions:
- `_lint_has_behavioral_criterion()` — checks if any criterion text suggests
  runtime/behavioral verification
- `_lint_refactor_has_completeness_check()` — for refactor milestones, checks
  for a "no remaining references" type criterion
- `_lint_config_has_self_referential_check()` — for config milestones, checks
  for a self-referential pipeline.conf check

Main entry point: `lint_acceptance_criteria MILESTONE_FILE` returns warning
messages (empty string if all checks pass).

### Step 2 — Integrate into check_milestone_acceptance

In `lib/milestone_acceptance.sh`, call `lint_acceptance_criteria` before
running the actual acceptance checks. Log warnings to `${NON_BLOCKING_LOG_FILE}`.

### Step 3 — Write tests

Test against M72's original criteria (should trigger 2+ warnings) and
against M73-M83 criteria (should trigger zero false positives on well-formed
milestones).

### Step 4 — Shellcheck and test

```bash
shellcheck lib/milestone_acceptance_lint.sh
bash tests/run_tests.sh
```

## Files Touched

### Added
- `lib/milestone_acceptance_lint.sh` — acceptance criteria linter
- `tests/test_milestone_acceptance_lint.sh` — linter tests

### Modified
- `lib/milestone_acceptance.sh` — integrate linter call
- `tekhton.sh` — source new library file

## Acceptance Criteria

- [ ] `lint_acceptance_criteria` returns warnings for milestone files with zero behavioral criteria
- [ ] `lint_acceptance_criteria` returns a warning for a refactor milestone missing a completeness grep criterion
- [ ] `lint_acceptance_criteria` returns a warning for a config milestone missing a self-referential check
- [ ] M72's original acceptance criteria text triggers at least 2 warnings
- [ ] M73 through M83 milestone files trigger zero warnings (no false positives)
- [ ] Warnings are logged to `${NON_BLOCKING_LOG_FILE}` during acceptance checking
- [ ] **Behavioral:** Running `check_milestone_acceptance` on a test milestone with only structural criteria produces visible warning output
- [ ] `shellcheck lib/milestone_acceptance_lint.sh` reports zero warnings
- [ ] `bash tests/run_tests.sh` passes
