## Test Audit Report

### Audit Summary
Tests audited: 3 files, 8 test cases (6 in test_audit_bash_env_coverage.sh + 1 fixture + 6 in test_m27_sweep_regression.sh)
Verdict: PASS

### Findings

#### EXERCISE: _strip_m27_defaults tested via inline copy, not actual function
- File: tests/test_m27_sweep_regression.sh:80-83
- Issue: The `_strip_m27_defaults` function is redefined inline in the regression test rather than sourced or imported from `test_m84_static_analysis.sh` where the actual production function lives. If the implementation in `test_m84_static_analysis.sh` is later modified, this regression test continues to pass on the stale inline copy and will not catch the divergence. The inline copy is a one-liner (`grep -v "${fname}}" || true`) so the risk is low, but the test is exercising a copy, not the real thing.
- Severity: MEDIUM
- Action: Either (a) source the relevant section of `test_m84_static_analysis.sh` in a subshell and call through, or (b) add a cross-check assertion that the function body in `test_m84_static_analysis.sh` still matches the expected one-liner so any divergence trips this test explicitly. Since `test_m84_static_analysis.sh` is a test file rather than a library, approach (b) is cleaner.

#### COVERAGE: Case 3 in test_audit_bash_env_coverage.sh intentionally asserts false-positive behavior
- File: tests/test_audit_bash_env_coverage.sh:121-137
- Issue: The test asserts exit 1 and a finding for `echo '${MILESTONE_MODE}'` — a known false positive the scanner produces because it does not track intra-line single-quote boundaries. This is not a test defect: the test file comment at lines 122-127 explicitly documents this as a regression guard so any future fix to the scanner surfaces automatically. Flagged here for visibility, not for remediation.
- Severity: LOW
- Action: No action needed. The intent is correctly documented in the test header and the assertion is faithful to current scanner behavior.

#### ISOLATION: test_m27_sweep_regression.sh Case 1 reads live source tree
- File: tests/test_m27_sweep_regression.sh:36-48
- Issue: Case 1 invokes `scripts/audit-bash-env.sh` with no target argument, causing it to scan the live `lib/` and `stages/` directories. Pass/fail depends on the current state of source files in the working tree. This is distinct from reading run artifacts (the rubric's primary concern), but any future commit that introduces an unguarded `${VAR}` anywhere in `lib/` or `stages/` will flip this test red including work completely unrelated to m27.
- Severity: LOW
- Action: This is intentional by design (described in the test header as "the primary acceptance criterion for m27.2: the sweep covered every unguarded read site"). No remediation needed. Future contributors should understand this test catches any unguarded-read regression across the entire bash surface.

#### ISOLATION: test_m27_sweep_regression.sh Case 2 depends on working-tree file absence
- File: tests/test_m27_sweep_regression.sh:58-63
- Issue: Case 2 checks that `.tekhton/M27_INVENTORY.md` is absent from the working tree. The assertion is sensitive to any process (pipeline run, manual step) that recreates that file path. The `.tekhton/` directory is the mutable pipeline artifact directory.
- Severity: LOW
- Action: Consider adding a comment noting that this check should be retired once M27 is fully closed and there is no process path that recreates the file, to prevent it from becoming a noise source in future pipelines.

### Notes on Files With No Findings

**tests/test_audit_bash_env_coverage.sh** — Assertions in Cases 1 and 2 are derived from real fixture content (`01-guarded.sh` contains `${MILESTONE_MODE:-false}`, `02-unguarded.sh` contains `${MILESTONE_MODE}`) and the scanner's documented `file:line:varname` output format. The binary-absent fallback path is correctly isolated using a tmpdir copy of the script with a filtered PATH and a `TEKHTON_BIN=/nonexistent` override. Tmpdir is cleaned up on EXIT via trap. No honesty, isolation, or scope issues.

**tests/testdata/audit_bash_env/07-single-quoted.sh** — Single-line fixture `echo '${MILESTONE_MODE}'` is the correct content for documenting the known scanner false positive. No issues.

**tests/test_m27_sweep_regression.sh Case 3 sub-cases** — The three sub-cases (3a default-expansion, 3b bare literal, 3c grep-r format) provide good boundary coverage of the filter: one line that should be stripped, one that should be preserved, and one in the actual grep output format. The use of `|| true` in the inline function is correct for `set -e` safety. Assertions check actual output from the real grep invocations, not hard-coded strings.
