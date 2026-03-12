# Drift Log

## Metadata
- Last audit: 2026-03-12
- Runs since audit: 1

## Unresolved Observations
- [2026-03-12 | "Implement  Milestone 3: Generation Prompt Overhaul for Deep CLAUDE.md"] `CLAUDE.md` Template Variables table calls the design content variable `PLAN_DESIGN_CONTENT`, but `stages/plan_generate.sh` exports it as `DESIGN_CONTENT` and `prompts/plan_generate.prompt.md` uses `{{DESIGN_CONTENT}}`. The stage and prompt are consistent with each other and the feature works correctly, but the table documentation is stale. Pre-existing mismatch, not introduced by this change.
- [2026-03-11 | "Implement Milestone 7: Tests + Documentation"] CLAUDE.md:167-323 — The "Current Initiative" section describes milestones 1-7 as if they are pending work. All milestones are shipped. This creates a documentation inconsistency between the milestone plan (future tense) and the implemented reality (complete feature). Not a blocker for this milestone but will mislead future agents reading CLAUDE.md as their project context.

## Resolved
- [RESOLVED 2026-03-11] `lib/drift.sh:61-93` and `lib/drift.sh:465-496` — the AWK continuation-line joining block remains duplicated verbatim between `append_drift_observations()` and `append_nonblocking_notes()`. Extracted into `_awk_join_bullets()` shared helper.
- [RESOLVED 2026-03-11] [2026-03-10 | "Implement Milestone 4: CLAUDE.md Generation Agent"] `prompts/plan_generate.prompt.md` instructs the agent to write CLAUDE.md "in the current working directory" without naming the path explicitly. Fixed: prompt now uses explicit `{{PROJECT_DIR}}/CLAUDE.md` path.
