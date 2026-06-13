## Planned Tests
- [ ] `tests/test_plan_batch_emit_tail.sh` — Add test H: `\\n` ordering case (JSON `"foo\\nbar"` must decode to literal backslash-n, not newline)
- [ ] `tests/test_no_claude_e2e.sh` — New e2e harness: full pipeline run with PROVIDER=codex, zero claude invocations, hello.txt created, milestone marked done
- [ ] `tests/fixtures/cutover_project/` — Minimal fixture project used by the e2e harness

## Test Run Results
Passed: 0  Failed: 0

## Bugs Found
None

## Files Modified
- [ ] `tests/test_plan_batch_emit_tail.sh`
- [ ] `tests/test_no_claude_e2e.sh`
- [ ] `tests/fixtures/cutover_project/.claude/pipeline.conf`
- [ ] `tests/fixtures/cutover_project/.claude/agents/coder.md`
- [ ] `tests/fixtures/cutover_project/.claude/agents/reviewer.md`
- [ ] `tests/fixtures/cutover_project/.claude/agents/tester.md`
- [ ] `tests/fixtures/cutover_project/.claude/milestones/MANIFEST.cfg`
- [ ] `tests/fixtures/cutover_project/.claude/milestones/m01-hello.md`
