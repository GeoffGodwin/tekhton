## Planned Tests
- [x] `tests/test_plan_batch_emit_tail.sh` — Add test H: `\\n` ordering case (JSON `"foo\\nbar"` must decode to literal backslash-n, not newline)
- [x] `tests/test_no_claude_e2e.sh` — New e2e harness: full pipeline run with PROVIDER=codex, zero claude invocations, hello.txt created, milestone marked done
- [x] `tests/fixtures/cutover_project/` — Minimal fixture project used by the e2e harness

## Test Run Results
Passed: 5  Failed: 1 (test H — expected failure, confirms BUG-001)

### test_plan_batch_emit_tail.sh — 8 PASS, 1 FAIL
Tests A–G: PASS (pre-existing tests unaffected)
Test H (NEW): FAIL — confirms BUG-001. JSON `"foo\\nbar"` decodes to `foo\nbar` (newline) instead of `foo\\nbar` (literal backslash-n). Root cause: awk applies `gsub(/\\n/, "\n")` before `gsub(/\\\\/, "\\")`, so `\\n` is consumed as `\n` before the double-backslash reduction runs.

### test_no_claude_e2e.sh — 5 PASS (TEKHTON_E2E=1)
A: pipeline exited 0 under PROVIDER=codex
B: MANIFEST.cfg m01 entry is 'done'
C: hello.txt created in fixture project
D: claude was not invoked as an AI agent
E: PROVIDER_REVIEW=claude sabotage correctly detected (claude invocations logged)

Note: sabotage vector is PROVIDER_REVIEW=claude (not PROVIDER_CODER=claude). See BUG-002.

## Bugs Found

### BUG-001: `_plan_batch_emit_tail` awk `\\n` unescape ordering (pre-existing, confirmed)
**File:** `lib/plan_batch.sh` — `_plan_batch_emit_tail` function
**Symptom:** A JSON string `"foo\\nbar"` (literal backslash-n) decodes to `foo\nbar` (actual newline) instead of `foo\nbar` (literal backslash-n).
**Root cause:** The awk gsub order is wrong. `gsub(/\\n/, "\n")` runs BEFORE `gsub(/\\\\/, "\\")`. When the input is `\\n`, the first gsub sees `\\n` as `\n` (backslash-n sequence) and converts it to a newline, before the second gsub can reduce `\\` to `\`. Correct order: `\\\\` → `\\` FIRST, then `\\n` → newline.
**Test:** `tests/test_plan_batch_emit_tail.sh` test H confirms.

### BUG-002: Coder stage `deps.RunAgent` not wired to provider in production
**File:** `internal/stages/coder/orchestrator.go:newOrchestrator`
**Symptom:** `PROVIDER_CODER=claude` has no effect — the coder stage never invokes any AI agent provider. `deps.RunAgent` is nil (from `DefaultDeps()`), so `invokeCoderAgent` is always a no-op in production. `cfg.Provider = stageProvider` is set in `config.go:184` but never consulted by the orchestrator.
**Impact:** The `SetProvider` wiring for the coder stage is effectively dead code. Agents cannot be exercised through the Go provider dispatch for the coder stage.
**Evidence:** Running with `PROVIDER_CODER=claude` still produces 0 claude invocations; running with `PROVIDER_REVIEW=claude` correctly produces claude invocations.

### BUG-003: Codex provider ignores `req.WorkingDir`
**File:** `internal/provider/codex/flags.go:buildExecArgs` (lines 38–45)
**Symptom:** The codex binary is always invoked with `--cd <process_cwd>` (TEKHTON_HOME) instead of the project directory. Several stages (coder, continuation) set `WorkingDir` on `provider.Request`, but `buildExecArgs` falls back to `os.Getwd()` when `codex.cwd` is not set in `ProviderSpecific`, ignoring `req.WorkingDir` entirely.
**Fix required:** `buildExecArgs` should fall through: `codex.cwd` → `req.WorkingDir` → `os.Getwd()`.
**Evidence:** All codex invocations in debug output show `--cd /home/geoff/workspace/geoffgodwin/tekhton` regardless of `--project-dir` flag.

### BUG-004: `checkClaudeVersion` fires even when `PROVIDER=codex`
**File:** `internal/preflight/claude_env.go`
**Symptom:** Even with `PROVIDER=codex`, the preflight calls `claude --version`. This means a zero-claude codex-only deployment still requires `claude` on PATH.
**Context:** m21 Goal 4 ("skip the claude-env check when claude is not in the resolved provider spec") was marked done but not implemented.

## Missing Deliverables (not testable — coder did not implement)
- `internal/preflight/provider_cutover.go` — not created
- `docs/cutover-runbook.md` — not created

## Files Modified
- [x] `tests/test_plan_batch_emit_tail.sh` — added test H (BUG-001 confirmation)
- [x] `tests/test_no_claude_e2e.sh` — new zero-claude e2e harness
- [x] `tests/fixtures/cutover_project/.claude/pipeline.conf`
- [x] `tests/fixtures/cutover_project/.claude/agents/coder.md`
- [x] `tests/fixtures/cutover_project/.claude/agents/reviewer.md`
- [x] `tests/fixtures/cutover_project/.claude/agents/tester.md`
- [x] `tests/fixtures/cutover_project/.claude/milestones/MANIFEST.cfg`
- [x] `tests/fixtures/cutover_project/.claude/milestones/m01-hello.md`
