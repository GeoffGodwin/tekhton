# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-23 | "Fix the bug found in the TESTER_REPORT.md and then fix all of the observations in the NON_BLOCKING_LOG.md"] `tests/test_detect_brownfield_coverage.sh:196-201` — The pnpm multi-pattern test accepts both outcomes as PASS (one branch says "awk fixed", the other says "known limitation"). The awk bug was actually fixed in this run, so the test now masks future regressions — if the fix were reverted, the test would still pass via the else branch. Replace the else branch with a `fail` to assert the fix is durable.
- [ ] [2026-03-23 | "Fix the bug found in the TESTER_REPORT.md and then fix all of the observations in the NON_BLOCKING_LOG.md"] `lib/init_helpers.sh:146` — New file carries `&>/dev/null 2>&1` — the same redundant double-redirect that was explicitly fixed in `stages/intake.sh` as NON_BLOCKING item #10 in this same task. Since this is new code, it should not introduce the same pattern. Should use `&>/dev/null` alone.
- [ ] [2026-03-23 | "Implement Milestone 12: Brownfield Deep Analysis & Inference Quality"] [init_config.sh:43-46] Model names (`claude-sonnet-4-6`, `claude-opus-4-6`) are hardcoded in the config generator. This is acceptable for a one-time init helper, but should be revisited if Tekhton ever adds a global `PREFERRED_*_MODEL` config tier — today's generated configs would then be inconsistent with it.
- [ ] [2026-03-23 | "Implement Milestone 11: Brownfield AI Artifact Detection & Handling"] `lib/artifact_handler_ops.sh` is exactly 300 lines (`wc -l`). At the ceiling; acceptable by the established interpretation that 300 = ceiling. Any future additions will require a split.
- [ ] [2026-03-23 | "Implement Milestone 9: Security Agent Stage & Finding Classification"] `run_agent` for the security scan agent passes `"${AGENT_TOOLS_REVIEWER:-}"` as the tools parameter (security.sh:292). This is presumably intentional (read-only tools appropriate for a scan agent), but `AGENT_TOOLS_REVIEWER` is a borrowed name. If a dedicated `AGENT_TOOLS_SECURITY` variable is ever introduced, this should be updated.
- [ ] [2026-03-23 | "Implement Milestone 8: Indexer Tests & Documentation then continue on to implement Milestone 9"] `tests/run_tests.sh` switched to auto-discovery (`for test_file in test_*.sh`) as part of this rework — a good improvement that picks up new split files automatically. The previous `PYTHON_PASS`/`PYTHON_FAIL` flag inconsistency (noted last cycle) remains but is cosmetic only; logic is correct.

## Resolved
