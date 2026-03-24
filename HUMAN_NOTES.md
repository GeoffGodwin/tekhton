# Human Notes

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.

Prefix each note with a priority tag so the pipeline can scope runs correctly:
- `[BUG]` — something is broken, needs fixing before new features
- `[FEAT]` — new mechanic or system, architectural work
- `[POLISH]` — visual/UX improvement, no logic changes


## Features
None currently.

## Bugs
- [x] [BUG] The CLARIFICATIONS.md file structure is not working as intended. I just tried a bug fixing call of Tekhton with ` tekhton --complete "Implement fixes for all of the NON_BLOCKING_LOG items until they are all resolved."` and that resulted in the "Clarification Required" process kicking off in Task Intake. It asked for 4 clarifying questions then alleged to have answered them. If you check the CLARIFICATIONS.md file it generated you will see the answers are all nonsensical.

This surfaces two issues: 1) the non sensical answering of these questions inline is broken and 2) the pipeline likely needs a dedicated flag for "clean up the non blockers from the NON_BLOCKER_LOG" since that's such a common case and another flag for --fix-drift which just tackles all the current architectural DRIFT_LOG items without having to wait for the next architecture threshold to be hit.

Examples of the Clarifications "non sensical answers" bug taken as excerpt from the CLARIFICATIONS.md file:

Clarifications — 2026-03-23 23:22:36

Q: What is the "Watchtower dashboard"? Is it a Tekhton component, an optional add-on, or part of a target project? Where is it defined in the codebase?
**A:** What is the "Watchtower dashboard"? Is it a Tekhton component, an optional add-on, or part of a target project? Where is it defined in the codebase?

Q: Which specific static UI files are expected to be present in `.claude/dashboard/`? (e.g., `index.html`, `dashboard.js`, asset bundles — list them)
**A:** What is the "Watchtower dashboard"? Is it a Tekhton component, an optional add-on, or part of a target project? Where is it defined in the codebase?

Q: How should these files get there? Options: (a) checked into the repo, (b) copied by `tekhton.sh` or an init step, (c) generated at startup, (d) output of a build process.
**A:** What is the "Watchtower dashboard"? Is it a Tekhton component, an optional add-on, or part of a target project? Where is it defined in the codebase?

## Polish
None currently.
