# Drift Log

## Metadata
- Last audit: 2026-03-16
- Runs since audit: 1

## Unresolved Observations
- [2026-03-16 | "Implement Milestone 4: Mid-Run Clarification And Replanning"] `ARCHITECTURE.md` Layer 3 library list and File Ownership table still do not include `lib/clarify.sh`, `lib/replan.sh`, or `CLARIFICATIONS.md`. Both the coder and previous review cycle noted this — it should be a follow-up task.
- [2026-03-16 | "Implement Milestone 4: Mid-Run Clarification And Replanning"] --
- [2026-03-16 | "Implement Milestone 1: Token And Context Accounting"] `reviewer.md` architecture boundary check ("No modifications to existing execution pipeline files") conflicts with the 2.0 milestone series, which explicitly authorizes modifications to `stages/*.sh` and `lib/*.sh`. The reviewer role file should clarify that 2.0 feature additions to execution pipeline files are authorized when the CLAUDE.md milestone spec explicitly calls them out. Carry-over from prior cycle.
- [2026-03-16 | "Implement Milestone 1: Token And Context Accounting"] -- **Prior Blocker Verification:** 1. `lib/context.sh` missing `set -euo pipefail` — **FIXED.** Line 2 now reads `set -euo pipefail`. ✓ 2. Token format in `print_run_summary()` — **FIXED.** Lines 152–153 of `lib/agent.sh` now compute `ctx_k=$(( LAST_CONTEXT_TOKENS / 1000 ))` and display `~${ctx_k}k tokens (${LAST_CONTEXT_PCT:-0}% of window)`. ✓
- [2026-03-16 | "Implement Milestone 0.5: Agent Output Monitoring And Null-Run Detection"] `lib/agent.sh:1` — file is now 678 lines (down from 711 after dead-code removal), still more than double the 300-line ceiling in the Code Quality checklist. Pre-existing condition; flagging again for a future refactor pass to split helper sections into a companion file (e.g., `lib/agent_monitor.sh`).
- [2026-03-16 | "Implement Milestone 0.5: Agent Output Monitoring And Null-Run Detection"] --

## Resolved
- [RESOLVED 2026-03-12] [2026-03-12 | "Implement  Milestone 3: Generation Prompt Overhaul for Deep CLAUDE.md"] `CLAUDE.md` Template Variables table calls the design content variable `PLAN_DESIGN_CONTENT`, but `stages/plan_generate.sh` exports it as `DESIGN_CONTENT` and `prompts/plan_generate.prompt.md` uses `{{DESIGN_CONTENT}}`. Fixed: renamed `PLAN_DESIGN_CONTENT` to `DESIGN_CONTENT` in the Template Variables table.
- [RESOLVED 2026-03-12] [2026-03-11 | "Implement Milestone 7: Tests + Documentation"] CLAUDE.md:167-323 — The "Current Initiative" section describes milestones 1-7 as if they are pending work. Already resolved: header changed to "Completed Initiative", summary paragraph updated, all milestones marked [DONE].
- [RESOLVED 2026-03-11] `lib/drift.sh:61-93` and `lib/drift.sh:465-496` — the AWK continuation-line joining block remains duplicated verbatim between `append_drift_observations()` and `append_nonblocking_notes()`. Extracted into `_awk_join_bullets()` shared helper.
- [RESOLVED 2026-03-11] [2026-03-10 | "Implement Milestone 4: CLAUDE.md Generation Agent"] `prompts/plan_generate.prompt.md` instructs the agent to write CLAUDE.md "in the current working directory" without naming the path explicitly. Fixed: prompt now uses explicit `{{PROJECT_DIR}}/CLAUDE.md` path.
