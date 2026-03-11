# Coder Summary
## Status: COMPLETE

## What Was Implemented

Milestone 2: Multi-Phase Interview with Deep Probing

- Extended `_extract_template_sections()` to output a 4th field `PHASE` (1, 2, or 3) parsed from `<!-- PHASE:N -->` markers in templates. Default is 1 if not specified.
- Added `<!-- PHASE:N -->` markers to all 7 design doc templates (`web-app.md`, `web-game.md`, `cli-tool.md`, `api-service.md`, `mobile-app.md`, `library.md`, `custom.md`), organizing sections into:
  - Phase 1 (Concept Capture): overview, tech stack, philosophy, core concept
  - Phase 2 (System Deep-Dive): each feature/system section
  - Phase 3 (Architecture & Constraints): config, naming, open questions, what not to build
- Restructured `run_plan_interview()` to display phase headers on phase transitions, with accumulated Phase 1 context shown at the start of Phase 2+ via `_build_phase_context()`
- Extracted `run_plan_followup_interview()` into `stages/plan_followup_interview.sh` to keep both files under 300 lines
- Updated `run_plan_followup_interview()` to handle the 4-field format from `_extract_template_sections()` and show existing section content before each follow-up question
- Rewrote `plan_interview.prompt.md` to instruct Claude to produce deep, multi-paragraph design prose with sub-sections, tables, config examples, and edge case documentation (replacing the "2-6 sentences" guidance)
- Updated `plan_interview_followup.prompt.md` with matching depth instructions
- Updated test fixture `tests/fixtures/plan_test_template.md` with PHASE markers and additional sections for Phase 2 and 3

## Rework Summary
- **Complex Blocker**: `stages/plan_interview.sh` was 453 lines, exceeding the 300-line limit. Extracted `run_plan_followup_interview()` into new file `stages/plan_followup_interview.sh` (174 lines). Original file is now 299 lines. Added `source` line in `tekhton.sh` `--plan` block. All 34 tests pass.

## Root Cause (bugs only)
N/A — new feature implementation

## Files Modified
- `lib/plan.sh` — Updated `_extract_template_sections()` awk parser to recognize `<!-- PHASE:N -->` and output 4-field format `NAME|REQUIRED|GUIDANCE|PHASE`
- `stages/plan_interview.sh` — Contains `run_plan_interview()`, `_read_section_answer()`, `_build_phase_context()` for 3-phase flow with phase headers and context display (299 lines)
- `stages/plan_followup_interview.sh` — **NEW** — Contains `run_plan_followup_interview()` extracted from plan_interview.sh for 4-field format and existing content display (174 lines)
- `tekhton.sh` — Added `source` for `stages/plan_followup_interview.sh` in `--plan` block
- `prompts/plan_interview.prompt.md` — Rewritten to instruct deep synthesis with sub-sections, tables, config examples
- `prompts/plan_interview_followup.prompt.md` — Updated to match depth instructions
- `templates/plans/web-app.md` — Added PHASE markers (4 P1, 11 P2, 5 P3)
- `templates/plans/web-game.md` — Added PHASE markers (4 P1, 14 P2, 4 P3)
- `templates/plans/cli-tool.md` — Added PHASE markers (4 P1, 8 P2, 4 P3)
- `templates/plans/api-service.md` — Added PHASE markers (4 P1, 12 P2, 4 P3)
- `templates/plans/mobile-app.md` — Added PHASE markers (4 P1, 10 P2, 5 P3)
- `templates/plans/library.md` — Added PHASE markers (4 P1, 7 P2, 4 P3)
- `templates/plans/custom.md` — Added PHASE markers (3 P1, 7 P2, 5 P3)
- `tests/fixtures/plan_test_template.md` — Added PHASE markers and extra sections for testing

## Architecture Decisions
- Phase markers use HTML comment syntax `<!-- PHASE:N -->` for consistency with existing `<!-- REQUIRED -->` marker pattern. Placed on a separate line after `<!-- REQUIRED -->` when both are present.
- `_extract_template_sections()` defaults to phase 1 when no `<!-- PHASE:N -->` marker is present, ensuring backward compatibility with any custom templates lacking phase markers.
- Phase context is built by `_build_phase_context()` using bash namerefs to avoid copying large arrays.
- The followup interview now calls `_get_section_content()` (from `plan_completeness.sh`) to show existing section text before asking for additions. This function is already available because `plan_completeness.sh` is sourced before `plan_interview.sh` in the `--plan` block.
- `run_plan_followup_interview()` extracted to `stages/plan_followup_interview.sh` to resolve the 300-line file size limit. It depends on `_read_section_answer()` from `plan_interview.sh`, which is sourced first in `tekhton.sh`.
