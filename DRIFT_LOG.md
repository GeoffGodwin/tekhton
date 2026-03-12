# Drift Log

## Metadata
- Last audit: 2026-03-12
- Runs since audit: 5

## Unresolved Observations

## Resolved
- [RESOLVED 2026-03-12] [2026-03-12 | "Implement  Milestone 3: Generation Prompt Overhaul for Deep CLAUDE.md"] `CLAUDE.md` Template Variables table calls the design content variable `PLAN_DESIGN_CONTENT`, but `stages/plan_generate.sh` exports it as `DESIGN_CONTENT` and `prompts/plan_generate.prompt.md` uses `{{DESIGN_CONTENT}}`. Fixed: renamed `PLAN_DESIGN_CONTENT` to `DESIGN_CONTENT` in the Template Variables table.
- [RESOLVED 2026-03-12] [2026-03-11 | "Implement Milestone 7: Tests + Documentation"] CLAUDE.md:167-323 — The "Current Initiative" section describes milestones 1-7 as if they are pending work. Already resolved: header changed to "Completed Initiative", summary paragraph updated, all milestones marked [DONE].
- [RESOLVED 2026-03-11] `lib/drift.sh:61-93` and `lib/drift.sh:465-496` — the AWK continuation-line joining block remains duplicated verbatim between `append_drift_observations()` and `append_nonblocking_notes()`. Extracted into `_awk_join_bullets()` shared helper.
- [RESOLVED 2026-03-11] [2026-03-10 | "Implement Milestone 4: CLAUDE.md Generation Agent"] `prompts/plan_generate.prompt.md` instructs the agent to write CLAUDE.md "in the current working directory" without naming the path explicitly. Fixed: prompt now uses explicit `{{PROJECT_DIR}}/CLAUDE.md` path.
