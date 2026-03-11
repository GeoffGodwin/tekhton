# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-10 | "Implement Milestone 4: CLAUDE.md Generation Agent"] `lib/plan.sh` is at 291 lines. Milestone 6 will add state save/restore and config defaults, which will push it over the 300-line limit. A split (e.g. extract `check_design_completeness` and helpers into `lib/plan_completeness.sh`) should be planned before Milestone 6 begins.
- [ ] [2026-03-10 | "Implement Milestone 4: CLAUDE.md Generation Agent"] `ARCHITECTURE.md` needs a Layer 1 update noting that `--plan` now sources `agent.sh` in addition to the previous four libraries. The ACP flags this; it is Milestone 7 scope but worth tracking.
- [ ] [2026-03-10 | "Implement Milestone 3: Completeness Check + Follow-Up"] `lib/plan.sh` and `stages/plan_interview.sh` still lack `set -euo pipefail` at the file top. Pre-existing from Milestones 1/2; settings are inherited from the sourcing script and test harness. Fix in a dedicated cleanup pass.
- [ ] [2026-03-10 | "Implement Milestone 3: Completeness Check + Follow-Up"] `run_plan_completeness_loop`: the invalid-choice handler decrements `pass_num` then falls through to the next loop iteration, which re-increments and re-runs `check_design_completeness`, printing a second "Completeness Check — Pass N" header for the same logical pass. A small inner re-prompt loop for just the `[f/s]` choice would eliminate the redundant check and duplicate header.
- [ ] [2026-03-10 | "Implement Milestone 3: Completeness Check + Follow-Up"] `tests/test_plan_completeness.sh` line 14: `TMPDIR=$(mktemp -d)` shadows the system `$TMPDIR` environment variable used by many programs. Rename to `TEST_TMPDIR` (or similar) to avoid unintended side effects.
- [ ] [2026-03-10 | "implement Milestone 2: Interactive Interview Agent"] `stages/plan_interview.sh` and `lib/plan.sh` both lack a `set -euo pipefail` header. These files are sourced by `tekhton.sh` (which has `set -euo pipefail`), so the options are inherited at runtime, but CLAUDE.md rule #2 requires all scripts to carry the header explicitly. Add the header to both files for consistency.
- [ ] [2026-03-10 | "implement Milestone 2: Interactive Interview Agent"] `stages/plan_interview.sh` lines 91 and 102: `wc -l < "$file"` can produce leading whitespace on some platforms. `$(wc -l < "$file" | tr -d ' ')` is strictly portable.
- [ ] [2026-03-10 | "implement Milestone 2: Interactive Interview Agent"] `--dangerously-skip-permissions` is intentional and documented in `CODER_SUMMARY.md`. Consider a one-line `warn` at startup — e.g., "Note: interview agent has write access to your project directory to create DESIGN.md." — so users are explicitly informed before the session starts.
- [ ] [2026-03-10 | "implement Milestone 2: Interactive Interview Agent"] `prompts/plan_interview.prompt.md` instructs the agent to write `DESIGN.md` in "the current working directory." Worth a comment in `run_plan_interview()` noting the implicit CWD coupling, before Milestone 6 adds state-resume logic that might `cd`.
- [ ] [2026-03-10 | "Implement Milestone 1: Foundation — CLI Flag, Library Skeleton, Project Type Selection"] `run_plan()` (plan.sh:84) prints "Project type '...' selected" and "Template resolved: ..." after `select_project_type()` already printed both via `success` and `log`. This is redundant output — the user sees the confirmation twice. Consider removing the duplicates from `run_plan()` (lines 99–102) and letting `select_project_type()` be the single source of truth for those messages.
- [ ] [2026-03-10 | "Implement Milestone 1: Foundation — CLI Flag, Library Skeleton, Project Type Selection"] `select_project_type()` uses `read -r choice` directly from stdin with no `/dev/tty` fallback. If `--plan` is ever invoked with piped stdin (e.g., scripted testing), it will block silently. A natural edge case to handle in Milestone 6's state persistence work.
<!-- Items added here by the pipeline. Mark [x] when addressed. -->

## Resolved
