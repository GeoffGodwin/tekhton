# Human Action Required

The pipeline identified items that need your attention. Review each item
and check it off when addressed. The pipeline will display a banner until
all items are resolved.

## Action Items
- [x] [2026-04-16 | Source: architect] **[M89] `lib/test_audit.sh` (574 lines) needs a dedicated split milestone** → Resolved: created M95 (`m95-test-audit-sh-file-split.md`), added to MANIFEST.cfg after M92.
- [ ] [2026-04-18 | Source: coder (escalated from NON_BLOCKING_LOG)] **One-line doc fix in `.claude/milestones/m95-test-audit-sh-file-split.md` line 131**: change `All four extracted functions` → `All seven extracted functions`. M95 ended up extracting seven functions across three companion modules (`test_audit_detection.sh`, `test_audit_verdict.sh`, `test_audit_helpers.sh`), not four; the acceptance criterion's count is stale. Agents cannot edit files under `.claude/milestones/*.md` (harness permission gate), so this requires a manual edit.
