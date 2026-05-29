## Test Audit Report

### Audit Summary
Tests audited: 4 files, 35 test functions (22 in test_mcp_serena_bin.sh,
8 in test_mcp_probe.sh, 10 in test_serena_template_substitution.sh, 25 in
test_mcp.sh). Freshness sample: 3 Go files reviewed (not modified this run).
Verdict: PASS

---

### Findings

#### NAMING: Stale file-header AC8 description in test_mcp_serena_bin.sh
- File: tests/test_mcp_serena_bin.sh:12
- Issue: The file-header comment reads `AC8  — VERSION reads 4.27.5` (implying an
  exact-value check) but the code at lines 225–229 now accepts any version in the
  range 4.27.x (x>=5) or 4.>=28.x. The test's own echo label at line 217 is
  accurate; only the header entry is stale. The current VERSION on disk is 4.28.4,
  confirming the broader range was required.
- Severity: LOW
- Action: Update header line 12 to:
  `# AC8  — VERSION at or above 4.27.5 floor (4.27.x x>=5, or 4.>=28.x after arc close)`

#### NAMING: Stale file-header AC8 description in test_mcp_probe.sh
- File: tests/test_mcp_probe.sh:8
- Issue: The file-header comment reads `AC8 — VERSION is 4.27.x (x >= 6, m28.2
  floor)` but the code at lines 115–118 also accepts 4.>=28.x. The test's own
  echo at line 102 is already correct.
- Severity: LOW
- Action: Update header line 8 to:
  `# AC8  — VERSION at or above 4.27.6 floor (4.27.x x>=6, or 4.>=28.x after arc close)`

#### WEAKENING: AC8 VERSION floor broadened from specific floor to open-ended range
- File: tests/test_mcp_serena_bin.sh:225–229, tests/test_mcp_probe.sh:115–118
- Issue: Prior tests asserted an exact floor (4.27.5 or 4.27.6). Both are now range
  checks accepting any 4.>=28.x as well. The precision reduction means the tests
  can no longer distinguish between the intended milestone floor and an arbitrary
  future version that happens to be higher. A regression that accidentally bumps
  to 4.30.0 would still pass AC8.
- Severity: LOW
- Action: Acceptable as-is. The coder's justification is sound: pipeline finalize
  hooks legally patch-bump VERSION between stages (current value is 4.28.4, already
  past any single milestone floor), and m28.3 closes the arc at 4.28.0. The broader
  range was required for the tests to remain green across the finalize lifecycle.
  CODER_SUMMARY documents this explicitly. No change recommended, but note that
  AC8-style milestone-floor checks may offer diminishing value once an arc promotes.

#### COVERAGE: Skip-as-PASS inflates counter in test_mcp.sh
- File: tests/test_mcp.sh:258–262
- Issue: The `resolve_mcp_config generates config from template` test registers a
  PASS and increments the PASS counter when `tools/serena_config_template.json` is
  absent (line 261: `PASS=$((PASS + 1))`). This makes the test appear to have
  passed without exercising any code, inflating the PASS total in the summary line
  (reported as 25/25 in TESTER_REPORT). The template file does exist in this repo,
  so the skip path is only reachable in stripped CI environments, but it masks
  whether the test ran.
- Severity: LOW
- Action: Replace the skip-PASS pattern with a neutral emit that leaves counters
  unchanged:
  ```bash
  else
      echo "  SKIP: _resolve_mcp_config test (tools/serena_config_template.json absent)"
  fi
  ```

#### COVERAGE: _resolve_case helper omits _SERENA_PYTHON and _SERENA_DIR assertions
- File: tests/test_mcp_serena_bin.sh:93–115
- Issue: The consolidated `_resolve_case` helper asserts return code and `_SERENA_BIN`
  after `_resolve_serena_paths` but does not assert `_SERENA_PYTHON` or `_SERENA_DIR`.
  The implementation sets all three on success. A regression in the Python-path or
  dir-path assignment would be invisible to this helper.
- Severity: LOW
- Action: Add assertions for `_SERENA_PYTHON` and `_SERENA_DIR` in the success-path
  calls (POSIX and Windows layout). For `Binary absent`, both should remain empty
  and can also be asserted. Suggested addition after the `_SERENA_BIN` assertion:
  ```bash
  if [[ "$_SERENA_DIR" == "$dir" ]]; then
      _pass "${label}: _SERENA_DIR matches expected"
  else
      _fail "${label}: _SERENA_DIR='${_SERENA_DIR}', expected '${dir}'"
  fi
  ```

---

### Assertion Honesty Assessment

All assertions in all four bash test files derive from real function behavior:

- **test_mcp_serena_bin.sh**: Template checks grep the actual file on disk. Resolver
  tests create fixture venvs in `$TMPDIR`, call the real `_resolve_serena_paths`, and
  assert against paths the function computed — no mocking. Config generation calls the
  real `_resolve_mcp_config` against a fixture venv and validates the output file with
  `python3 -m json.tool`. CHANGELOG checks extract the promoted block via `awk`.
  No assertion always-passes or compares against a value hard-coded independently
  of implementation logic.

- **test_mcp_probe.sh**: Calls `_probe_serena_startup` with `_SERENA_BIN=""` and
  asserts return 1 — matches the `[[ -z "${_SERENA_BIN:-}" ]]` guard in
  `lib/mcp_resolve.sh:62`. Calls `start_mcp_server` with a real executable stub that
  exits 1; the three post-call state assertions match the probe-failure branch at
  `lib/mcp.sh:119–124`. No trivially-true assertions.

- **test_serena_template_substitution.sh**: All three scenarios call the real
  `_resolve_mcp_config` with state pre-set from fixture files. The Python inline
  script validates the generated JSON command/args structure against the actual
  `_SERENA_BIN` value, not a hard-coded string. The stale-detection fixture
  (`stale.json`) has `args: ["-m", "serena", ...]`, which exactly matches the
  `_is_stale_serena_config` detection predicate (`args[0]=="-m" && args[1]=="serena"`).
  The correct fixture has `args: ["start-mcp-server", ...]`, which returns 1 (not
  stale) as expected. md5 comparisons before/after correctly distinguish overwrite
  vs. no-overwrite behavior.

- **test_mcp.sh** (new probe scenarios, lines 275–289): Three `_probe_case`
  invocations match implementation branches: empty bin hits the `[[ -z ]]` guard;
  `/usr/bin/false` exits 1 causing the `timeout` call to fail; `$(command -v echo)`
  exits 0, returning 0 from the probe. All expected return codes match the
  implementation.

### Implementation Exercise Assessment

All four files source `lib/common.sh` and `lib/mcp.sh` (which transitively sources
`lib/mcp_resolve.sh`) and call production functions directly. `test_mcp_probe.sh`
sets `_CLI_MCP_CONFIG_SUPPORTED="1"` to bypass the `claude --help` CLI check — a
targeted, appropriate seam that isolates the probe behavior under test without
over-mocking. No test mocks its own subject function.

### Test Weakening Assessment

`test_serena_template_substitution.sh` is new — no prior version exists to weaken.
`test_mcp.sh` additions are purely additive (three new probe scenarios).
`test_mcp_serena_bin.sh` and `test_mcp_probe.sh` broadened AC8 VERSION assertions —
the broadening is documented and necessary (current VERSION 4.28.4 is already
above any single milestone floor). The test count in both files is unchanged.
No coverage was removed.

---

### Freshness Sample — Go Test Files (not modified this run)

The three Go freshness-sample files are unaffected by m28.3 changes and contain
no stale references.

- **internal/finalize/cleanup_milestone_test.go**: Tests use `t.TempDir()` for full
  isolation. Covers the COMPLETE_AND_CONTINUE happy path, the commit-decision gate
  regression (declined/skipped/empty sentinel must not delete milestone file), the
  status-not-done no-op, missing-manifest no-op, and idempotent-when-file-already-gone
  cases. The sentinel regression test (TestCleanupMilestone_GatedByCommitDecisionSentinel)
  is well-motivated and named. No scope drift against m28.3.

- **internal/finalize/emit_run_memory_test.go**: Tests use `t.TempDir()`. Covers
  PASS verdict on exit 0, FAIL verdict on non-zero exit, and pruning above MaxEntries.
  `EmitRunMemory.Git` is injected via the struct field — appropriate seam-based
  fake, not a global mock. No scope drift.

- **internal/finalize/emit_timing_report_test.go**: Tests use `t.TempDir()`. Covers
  no-sidecar skip, full report from sidecar JSON, empty-phases skip, and table-driven
  tests for `formatDurationHuman` and `phaseDisplayName`. Assertions on column
  content and descending sort order are meaningful and specific. No scope drift.
