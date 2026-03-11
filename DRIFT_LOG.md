# Drift Log

## Metadata
- Last audit: 2026-03-11
- Runs since audit: 2

## Unresolved Observations

## Resolved
- [RESOLVED 2026-03-11] `lib/drift.sh:61-93` and `lib/drift.sh:465-496` — the AWK continuation-line joining block remains duplicated verbatim between `append_drift_observations()` and `append_nonblocking_notes()`. Extracted into `_awk_join_bullets()` shared helper.
- [RESOLVED 2026-03-11] [2026-03-10 | "Implement Milestone 4: CLAUDE.md Generation Agent"] `prompts/plan_generate.prompt.md` instructs the agent to write CLAUDE.md "in the current working directory" without naming the path explicitly. Fixed: prompt now uses explicit `{{PROJECT_DIR}}/CLAUDE.md` path.
