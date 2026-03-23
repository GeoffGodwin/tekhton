# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-23 | "Fix the bug found in the TESTER_REPORT.md and then fix all of the observations in the NON_BLOCKING_LOG.md"] `lib/detect_ci.sh:173` — `_detect_dockerfile_langs` iterates `Dockerfile Dockerfile.*` without `nullglob`; if no `Dockerfile.*` exists the literal string passes through the loop, but the `-f` guard silently skips it. Harmless currently; worth noting if the function expands.
- [ ] [2026-03-23 | "Fix the bug found in the TESTER_REPORT.md and then fix all of the observations in the NON_BLOCKING_LOG.md"] NON_BLOCKING_LOG items intentionally deferred (init_config.sh hardcoded models, artifact_handler_ops.sh at ceiling, security.sh tool reuse, run_tests.sh naming) — coder's rationale is sound (observation-only, actionable only on next structural change). Carry forward.

## Resolved
