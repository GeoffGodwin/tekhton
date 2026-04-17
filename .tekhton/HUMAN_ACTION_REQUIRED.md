# Human Action Required

The pipeline identified items that need your attention. Review each item
and check it off when addressed. The pipeline will display a banner until
all items are resolved.

## Action Items
- [ ] [2026-04-16 | Source: architect] **[M89] `lib/test_audit.sh` (574 lines) needs a dedicated split milestone** `lib/test_audit.sh` is 274 lines over the 300-line soft ceiling. The file's seven exported symbols fall into two natural clusters that warrant independent extraction:
- [ ] [2026-04-16 | Source: architect] **Detection helpers** (`_detect_orphaned_tests`, `_detect_test_weakening`) — pure shell analysis with no verdict routing dependencies. Natural target: `lib/test_audit_detection.sh`.
- [ ] [2026-04-16 | Source: architect] **Verdict layer** (`_parse_audit_verdict`, `_route_audit_verdict`) — report parsing and downstream dispatch. Natural target: `lib/test_audit_verdict.sh`. This split is not addressable in this audit run because it requires updating callers, ARCHITECTURE.md, and test coverage across three files. A dedicated milestone is warranted. **Recommended action for human:** Add a new milestone to `.claude/milestones/` targeting the `lib/test_audit.sh` split. Acceptance criteria should include: parent file ≤ 300 lines, all extracted functions covered by existing tests, `shellcheck` clean on all three output files. ---
