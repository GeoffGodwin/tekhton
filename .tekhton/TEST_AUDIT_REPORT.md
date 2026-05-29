## Test Audit Report

### Audit Summary
Tests audited: 1 file (tests/test_mcp_serena_bin.sh), 22 assertions across 8 logical test sections
Freshness sample reviewed: internal/errors/recovery_test.go, internal/errors/redact_test.go, internal/errors/sentinels_test.go (not modified this run — no issues flagged)
Verdict: PASS

### Findings

#### SCOPE: Reported pass count does not include the 22 new assertions
- File: tests/test_mcp_serena_bin.sh (all assertions)
- Issue: TESTER_REPORT.md claims "Passed: 492 Failed: 0". The CODER_SUMMARY reported 490 passing before this file existed. The delta is 2, matching only the "surgical" additions to tests/test_mcp.sh and tests/test_mcp_lifecycle.sh described in the CODER_SUMMARY. The 22 assertions in test_mcp_serena_bin.sh are absent from the delta, indicating run_tests.sh was executed before this file was present in tests/ (or was called with positional args that excluded it). run_tests.sh auto-discovers all tests/test_*.sh files via glob when invoked without positional args (run_tests.sh:254), so the file will run in all future unrestricted invocations. However, the tester's reported count does not reflect a full-suite run that includes the new assertions — the 22 AC checks were not verified to pass under the runner.
- Severity: MEDIUM
- Action: Re-run `bash tests/run_tests.sh` with no positional args after test_mcp_serena_bin.sh is confirmed present in tests/, and update TESTER_REPORT.md with the actual count (expected ~512 if all 22 assertions pass). Confirm the file is in tests/ before the run.

#### COVERAGE: _resolve_mcp_config early-exit paths not exercised
- File: tests/test_mcp_serena_bin.sh (AC3+AC5 section, lines 175-258)
- Issue: lib/mcp.sh:_resolve_mcp_config has two early-exit paths with no test coverage. (1) lines 119-121 — when SERENA_CONFIG_PATH points to an existing file, the function returns immediately with _MCP_CONFIG_PATH set to that path and no template generation occurs; this path goes entirely untested. (2) lines 137-139 — when _SERENA_DIR or _SERENA_BIN is empty, the function returns 1 before reaching the sed block; the guard is relevant for ensuring the AC2 failure mode (missing binary) propagates correctly to the config step. The AC3 test exercises only the generation path (no pre-existing config, fully-resolved paths).
- Severity: LOW
- Action: Add a test case that calls _resolve_mcp_config with an existing config file at the default path and verifies it returns 0 and sets _MCP_CONFIG_PATH without regenerating. Add a test case that calls _resolve_mcp_config with _SERENA_BIN="" and verifies it returns 1. Neither is a blocker for the milestone.

#### ISOLATION: VERSION is read from the live source tree and has already drifted
- File: tests/test_mcp_serena_bin.sh:267-275
- Issue: AC8 reads VERSION directly from ${TEKHTON_HOME}/VERSION (a live source-tree file). The CODER_SUMMARY documents resetting VERSION to 4.27.5 and warns that pipeline finalize hooks will patch-bump it. The file currently reads 4.27.7, confirming the drift. The test uses a floor assertion (`version_major_minor == "4.27" && version_patch -ge 5`) specifically to survive patch drift. This is adequate for the current milestone, but if major.minor advances before this test is retired (e.g., after m28.3 triggers a minor bump to 4.28), the test will fail despite no m28.1 regression existing.
- Severity: LOW
- Action: The floor assertion is a reasonable pragmatic choice for milestone acceptance. A follow-up milestone could either (a) drop the VERSION assertion from this file and leave AC8 verification to the milestone finalize gate, or (b) widen the band to `version_major_minor =~ ^4\.2[789]$` as a bounded future-proof alternative.

### Assertion Honesty Assessment
All 22 assertions derive from real implementation behavior:
- Template file grep checks read the actual file on disk — no inline constant to compare against.
- Resolver tests (_resolve_serena_paths) construct fixture directories in $TMPDIR, call the real function, and assert against the paths the function computed. No mocking.
- Config generation tests (_resolve_mcp_config) call the real function against a fixture venv and validate output file content with `python3 -m json.tool`. No mocking.
- CHANGELOG check extracts the [Unreleased] block via awk and greps for "m28.1" and "start-mcp-server" — both strings are present in the live CHANGELOG at those positions.
No assertion always-passes or uses a value hard-coded independently of the implementation.

### Implementation Exercise Assessment
The test sources lib/common.sh and lib/mcp.sh and calls `_resolve_serena_paths` and `_resolve_mcp_config` directly — these are the production functions, not stubs. Fixture directories in $TMPDIR use `touch` to simulate POSIX (.venv/bin/serena) and Windows (.venv/Scripts/serena.exe) layouts; the function's `-f` checks succeed on zero-byte files, which is correct for path-detection logic. State is reset between test sections (_SERENA_BIN="", _SERENA_PYTHON="", _SERENA_DIR="", SERENA_PATH=...) to prevent cross-section leakage. The AC3+AC5 section resets _MCP_CONFIG_PATH="" and SERENA_CONFIG_PATH="" to bypass the early-exit paths and exercise the generation branch — correctly targets the code path under test.

### Test Naming and Intent Assessment
Section headers (`=== AC1: Template contains 'start-mcp-server' ===`) and individual assertion messages (`"_SERENA_BIN set to POSIX bin/serena path"`) are clear and encode both the scenario and expected outcome. No naming issues found.

### Test Weakening Assessment
test_mcp_serena_bin.sh is a new file — no prior version exists to weaken. The audit context references "surgical" additions to tests/test_mcp.sh and tests/test_mcp_lifecycle.sh, but those files are not in the modified-this-run list and are out of scope per the audit rules. No weakening findings.

### Freshness Sample (not modified this run — informational only)
internal/errors/recovery_test.go, redact_test.go, and sentinels_test.go are in good condition: test function names encode scenario and expected outcome, all assertions call real package functions with no mocking, and coverage spans both happy paths and error/unknown inputs (unknown category, empty context, preserved request IDs vs redacted bearer tokens). No issues flagged; none of these files were modified this run.
