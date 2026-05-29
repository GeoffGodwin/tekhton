## Test Audit Report

### Audit Summary
Tests audited: 5 files (2 modified bash files, 3 freshness-sample Go files), ~50 test assertions/functions
Verdict: PASS

---

### Findings

#### COVERAGE: No automated success-path test for `_probe_serena_startup`
- File: `tests/test_mcp_probe.sh` (overall file; header comment lines 13–15)
- Issue: `test_mcp_probe.sh` exercises only failure modes of `_probe_serena_startup`
  (empty `_SERENA_BIN` → return 1; binary exits 1 → `start_mcp_server` returns 1).
  There is no automated test that verifies a zero-exit binary causes the probe to
  return 0. The `start_mcp_server` success path (probe passes → `SERENA_ACTIVE="true"`,
  `_MCP_SERVER_RUNNING=true`, return 0) is partially covered by `tests/test_mcp.sh`
  and `tests/test_mcp_lifecycle.sh` (not under audit for this run), but direct
  `_probe_serena_startup` success-path coverage is absent. The file header explicitly
  defers `/usr/bin/echo`, `/usr/bin/false`, and hanging-binary tests to m28.3,
  which is the documented rationale.
- Severity: MEDIUM
- Action: In m28.3, add a direct `_probe_serena_startup` test with a zero-exit stub
  (e.g., `_SERENA_BIN=/usr/bin/echo _probe_serena_startup` → 0). Also add a
  `start_mcp_server` success-path test with an executable stub so the probe passes
  and `SERENA_ACTIVE="true"` / `_MCP_SERVER_RUNNING=true` are asserted directly.
  No action required to block the current milestone given the explicit m28.3 deferral.

#### COVERAGE: Probe-failure state assertions cannot distinguish explicit clear from unchanged initial value
- File: `tests/test_mcp_probe.sh:83–99`
- Issue: The test initializes `SERENA_MCP_AVAILABLE=false` and `SERENA_ACTIVE=""`
  immediately before calling `start_mcp_server`. After the probe-failure path runs,
  it asserts those variables are still `false` and `""`. Because the initial values
  already match the asserted values, the assertions cannot distinguish between
  (a) "the implementation explicitly cleared the flags" and (b) "the implementation
  never touched them." If lines 231–232 of `lib/mcp.sh` (`SERENA_MCP_AVAILABLE=false`
  / `SERENA_ACTIVE=""`) were removed, these assertions would still pass. The
  implementation does correctly clear both flags, so there is no current bug; however,
  a future regression that removes the explicit clears would go undetected.
- Severity: MEDIUM
- Action: Pre-set `SERENA_MCP_AVAILABLE=true` and `SERENA_ACTIVE="true"` before
  calling `start_mcp_server` in the probe-failure scenario, then assert they are
  cleared to `false` and `""`. This makes the assertions sensitive to the clearing
  action specifically rather than the initial state.

#### NAMING: Stale header comment in `test_mcp_serena_bin.sh`
- File: `tests/test_mcp_serena_bin.sh:11`
- Issue: The file header reads `# AC8  — VERSION reads 4.27.5` but the assertion
  at lines 271–274 checks `version_patch -ge 5`, not `== "4.27.5"`. The broadened
  floor assertion is correct (VERSION is now 4.27.8 and the floor remains valid
  across subsequent patch bumps), but the comment is stale and misleads a reader
  auditing the file header who would expect an exact-value check.
- Severity: LOW
- Action: Update line 11 to: `# AC8  — VERSION is 4.27.x (x >= 5; m28.1 floor)`
  to match the actual assertion semantics.

---

### Assertion Honesty Assessment

All assertions in both bash test files derive from real implementation behavior:

- `test_mcp_serena_bin.sh`: Template grep checks read the actual file on disk.
  Resolver tests construct fixture directories in `$TMPDIR`, call the real
  `_resolve_serena_paths`, and assert against paths the function computed — no
  mocking. Config generation tests call the real `_resolve_mcp_config` against a
  fixture venv and validate the output file with `python3 -m json.tool`. CHANGELOG
  check extracts the `[Unreleased]` block via `awk` and greps for `"m28.1"` and
  `"start-mcp-server"`. No assertion always-passes or compares against a value
  hard-coded independently of the implementation.

- `test_mcp_probe.sh`: Calls `_probe_serena_startup` with `_SERENA_BIN=""` and
  asserts return code 1 — matches `lib/mcp.sh:119–121`. Calls `start_mcp_server`
  with a real executable stub that exits 1; asserts return code 1 — matches the
  probe failure branch at `lib/mcp.sh:228–234`. No trivially-true assertions found.

### Implementation Exercise Assessment

Both files source `lib/common.sh` and `lib/mcp.sh` directly and call production
functions (`_resolve_serena_paths`, `_resolve_mcp_config`, `_probe_serena_startup`,
`start_mcp_server`) without mocking. `test_mcp_probe.sh` sets
`_CLI_MCP_CONFIG_SUPPORTED="1"` to bypass the `claude --help` CLI probe — a
targeted, appropriate bypass that isolates the probe behavior under test.
State is reset between test sections to prevent cross-section leakage.

### Test Weakening Assessment

`test_mcp_probe.sh` is a new file this run — no prior version exists to weaken.
`test_mcp_serena_bin.sh` was modified to broaden the VERSION assertion from
`== "4.27.5"` to `patch >= 5`. Given that VERSION is now at 4.27.8, the
original exact-match assertion would already be failing. The broadening is a
necessary and justified adaptation to the finalize-hook version drift documented
in the CODER_SUMMARY, not a weakening of test intent.

---

### Freshness Sample — Go Test Files (not modified this run)

All three freshness-sample files are healthy. No issues flagged.

- `internal/failure_context/context_test.go` — In-process unit tests using
  `New()` instances; no mocking. Covers empty context, primary-only, secondary-only,
  both slots, question-mark defaults, JSON escaping, and alias fallback. Fully
  isolated. Aligned with the current `failure_context` package.

- `internal/finalize/archive_reports_test.go` — All tests use `t.TempDir()` for
  complete fixture isolation. Covers the happy path, missing-source skip, and
  missing-config error guards. The `Lookup` env-var fallback test exercises the
  seam correctly. No scope drift.

- `internal/finalize/causal_log_finalize_test.go` — Uses `t.TempDir()` and
  `t.Setenv()` for isolation. Covers emit, disable-flag guard, and failure
  exit-code reporting. `proto.RunDispositionSuccess/Failure` constants align with
  the current package. No scope drift.
