# Drift Log

## Metadata
- Last audit: 2026-03-19
- Runs since audit: 5

## Unresolved Observations
- [2026-03-19 | "Implement the items in the HUMAN_NOTES.md"] `tekhton.sh:1028` and `tekhton.sh:1135` both call `_check_gitignore_safety` for the same `git add -A` operation. This split of staging responsibility between the pre-staging block and `_do_git_commit()` is architecturally inconsistent — staging and safety checks belong in one place. Flagging for the M15.3 `finalize_run()` consolidation, which is the right time to unify this.
- [2026-03-19 | "Fix the two bugs in the HUMAN_NOTES.md"] `tekhton.sh:991` — `_PIPELINE_EXIT_CODE=0` is set unconditionally in the success path, which is correct since failures exit earlier. However, this means the `elif [[ -n "${_PIPELINE_EXIT_CODE:-}" ]]` guard in `notes.sh:182` is always true when called from tekhton.sh. The guard exists for testability (callers can set it to 1 to simulate failure). This is intentional design, but a brief comment in `resolve_human_notes()` near the `elif` explaining that `_PIPELINE_EXIT_CODE` is set by the caller (tekhton.sh) would help the next reader.
- [2026-03-19 | "Fix the items in the NON_BLOCKING_LOG.md"] `NON_BLOCKING_LOG.md:23` and `:13` — duplicate resolved entry for `lib/agent_monitor.sh` split (same text appears twice in Resolved section). Pre-existing issue, not introduced by this run.
- [2026-03-19 | "architect audit"] **Obs 2** (agent_monitor.sh Milestone 14 note): The coordination note describes a transient state that was correct at completion. No structural problem exists. Out of scope.
- [2026-03-19 | "architect audit"] **Obs 7** (common.sh fallback rendering): The non-empty fallback path lacks column-width enforcement, but only activates if `printf` fails — an event that does not occur in bash. Severity is below the threshold for a remediation task. Out of scope this cycle.

## Resolved
