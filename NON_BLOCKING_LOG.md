# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-02 | "Implement Milestone 52: Fix Circular Onboarding Flow"] `lib/init_report.sh:130` — The `! grep -q '<!-- TODO:.*--plan -->'` guard is dead code. The actual stub text injected by `init_helpers.sh:252` is `<!-- TODO: Add milestones here, or run tekhton --plan to generate them -->`, which contains ` to generate them` between `--plan` and `-->`, so the pattern `<!-- TODO:.*--plan -->` never matches. The fallback detection still works correctly via the `^#### Milestone` check alone; the guard can be simplified away.

## Resolved
