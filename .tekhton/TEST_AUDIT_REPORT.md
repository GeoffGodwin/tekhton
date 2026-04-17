## Test Audit Report

### Audit Summary
Tests audited: 11 files, ~385 test functions/assertions
Verdict: PASS

---

### Findings

#### EXERCISE: Agent invocation counter tests exercise inline arithmetic, not implementation
- File: tests/test_orchestrate.sh:396–406
- Issue: Tests 9.1–9.3 simulate `run_agent()` counter behavior by incrementing
  `TOTAL_AGENT_INVOCATIONS` inline in the test body (`$(( n + 1 ))`), then asserting
  the arithmetic is correct. No implementation code is called — the test verifies
  that bash integer arithmetic works. The actual orchestration counter propagation
  (how `TOTAL_AGENT_INVOCATIONS` is threaded into `_ORCH_AGENT_CALLS`) is not
  exercised.
- Severity: LOW
- Action: Replace inline arithmetic with a call to a real run_agent stub that
  auto-increments (as other test suites do) and assert the resulting
  `_ORCH_AGENT_CALLS` value from `_hook_emit_run_summary` output rather than the
  intermediate global. Alternatively, remove suite 9 if the orchestration loop
  integration is already covered by suites 1–8.

#### ISOLATION: Indexer cache test uses /tmp as PROJECT_DIR
- File: tests/test_indexer_cache.sh:18–19
- Issue: `PROJECT_DIR="/tmp"` is a hard-coded, globally-shared path rather than a
  test-scoped temp directory. Indexer helpers that resolve paths relative to
  `PROJECT_DIR` (e.g., virtualenv detection via `_indexer_find_venv_python`) could
  pick up real project state from `/tmp` if any exists. Cache files themselves use
  the correctly scoped `TMPDIR_CACHE`, so no test assertions are currently affected,
  but the practice violates isolation.
- Severity: LOW
- Action: Replace `PROJECT_DIR="/tmp"` with `PROJECT_DIR="$TMPDIR_CACHE"` (the
  already-created temp dir). No assertions need to change.

---

### Per-File Notes

**tests/test_cli_output_hygiene.sh** (new, M96 AC-1)
Both tests are structurally sound. Test 1 sources `causality.sh` in a subprocess
with `emit_event` stdout-redirected to `/dev/null`, asserting no event ID leaks
to the outer stdout. Test 2 is static analysis over all call sites in `lib/` and
`stages/`, with correct regex that accepts `>/dev/null`, `1>/dev/null`, and
`&>/dev/null` while correctly rejecting bare `2>/dev/null`. The regex for
excluding digit-prefixed redirects is non-trivial but the comment documents the
intent and manual regression injection was performed per CODER_SUMMARY.md. PASS.

**tests/test_orchestrate.sh**
Test 4.1 ANSI-strip fix is correct: `report_orchestration_status` wraps the
attempt number in `${BOLD}...${NC}`, so a raw grep for "2 / 5" would fail; the
sed strip before assertion is required and appropriate. Test 4.2 correctly skips
stripping for the elapsed line (no ANSI codes present). Test 4.3 correctly
verifies "Agent calls:" is absent from the banner (the parameter is accepted in
the function signature but never echoed — a valid regression guard). PASS (see
suite 9 EXERCISE note above).

**tests/test_context_accounting.sh**
The `VERBOSE_OUTPUT=true` addition to all `log_context_report` subshell tests is
the correct adapter for the M96 NR3 change that moved the context breakdown from
`log()` to `log_verbose()`. All assertions are unchanged and remain valid. PASS.

**tests/test_coder_scout_tools_integration.sh,
tests/test_coder_stage_split_wiring.sh,
tests/test_docs_agent_stage_smoke.sh,
tests/test_review_cache_invalidation.sh,
tests/test_run_memory_emission.sh,
tests/test_finalize_summary_escaping.sh,
tests/test_indexer_cache.sh**
All received only stub additions (`stage_header() { :; }`, `log_verbose() { :; }`)
required because M96 introduced these call sites into sourced production code.
Core assertions are unchanged, no weakening detected. PASS (see ISOLATION note
for test_indexer_cache.sh above).

**tests/test_m88_emit_symbol_map_happy_path.sh**
The change maps `log_verbose` to the same `_CAPTURED_LOG` accumulator as `log()`,
which is correct: M96 moved the "Test symbol map written" message from `log()` to
`log_verbose()`. The assertion `grep -q "Test symbol map written"` now correctly
validates against the new call site. PASS.

---

### Symbol Orphan Notes
All `STALE-SYM` warnings reference standard POSIX utilities and bash builtins
(`bash`, `cd`, `echo`, `grep`, `mktemp`, `set`, `trap`, etc.). These are false
positives — the shell-based orphan scanner cannot distinguish builtins and
externals from user-defined symbols. No action required.

The single user-defined symbol flagged — `_base_run_stage_coder` in
`test_coder_stage_split_wiring.sh:188` — is created dynamically via
`declare -f run_stage_coder | sed '1s/run_stage_coder/_base_run_stage_coder/'`
and is therefore invisible to static analysis. This is intentional and correct.
