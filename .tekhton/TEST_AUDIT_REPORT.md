## Test Audit Report

### Audit Summary
Tests audited: 1 file, 10 test functions (12 total assertions)
Verdict: CONCERNS

### Findings

#### INTEGRITY: test_no_dead_code else-branch is always-pass — dead code cannot be detected
- File: tests/test_install_bash_version_check.sh:155-164
- Issue: The else-branch of `test_no_dead_code` checks whether `}` appears in the last 5 lines of the extracted function body. Because the `sed` range `/^check_bash_version()/,/^}/p` always ends at the bare closing `}` on its own line, `}` is always present in `tail -5`. Any future `exit 1` reinstated in the last 5 lines (exactly the dead-code scenario under test) would enter the else-branch, find `}`, and call `pass "No dead code after fail() - function ends cleanly"`. The call to `fail "Function has unreachable code after fail()"` on line 163 is unreachable by construction. The test can never detect the regression it was written to guard against.
- Severity: HIGH
- Action: Remove the inner else/if and call `fail` directly when `exit 1` is found:
  ```bash
  if ! echo "$after_fail" | grep -q "exit 1"; then
      pass "No dead code (unreachable exit) after fail()"
  else
      fail "Function has unreachable code (exit 1 after fail()) at end of function"
  fi
  ```

#### ISOLATION: Hardcoded absolute path breaks portability
- File: tests/test_install_bash_version_check.sh:18
- Issue: `INSTALL_SH` is set to the literal path `/home/geoff/workspace/geoffgodwin/tekhton/install.sh`. Every test in the file reads from this path. The tests will abort immediately on any other machine, in CI, or when the repo is cloned elsewhere — with `set -euo pipefail` active, a missing file causes `grep` to return non-zero, which kills the runner before any result is printed.
- Severity: HIGH
- Action: Derive the path relative to the test file's location:
  ```bash
  INSTALL_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install.sh"
  ```

#### EXERCISE: All coverage is static source analysis; no behavioral tests
- File: tests/test_install_bash_version_check.sh (all tests)
- Issue: Every test extracts the `check_bash_version()` body with `sed` and greps for text patterns. No test actually executes the function to verify runtime behavior: exit code 1 when major < 4, stdout/stderr content at runtime, or the happy path (major >= 4 returns 0 silently). A syntax error in the function body, a wrong variable expansion, or a quoting mistake would pass all 10 tests. While sourcing `install.sh` wholesale is problematic (top-level argument parsing executes immediately), the function and its three dependencies (`fail`, color vars, `PLATFORM`) can be isolated with a short heredoc or by sourcing just the relevant lines.
- Severity: MEDIUM
- Action: Add at minimum two behavioral tests: (1) define the helpers inline, set `BASH_VERSINFO[0]=3 PLATFORM=linux`, call `check_bash_version`, assert exit code 1 and that stderr contains "4.3+"; (2) set `BASH_VERSINFO[0]=5`, call `check_bash_version`, assert exit code 0.

#### ISOLATION: TEST_DIR created but never used
- File: tests/test_install_bash_version_check.sh:13-14
- Issue: `TEST_DIR=$(mktemp -d)` and its `trap "rm -rf '$TEST_DIR'" EXIT` are present but `$TEST_DIR` is never referenced by any test. The directory is created, then immediately discarded. This is dead setup code that misleads readers into thinking tests run in isolation when they do not.
- Severity: LOW
- Action: Either remove the `TEST_DIR` / `trap` lines entirely, or repurpose `TEST_DIR` to hold an isolated copy of `install.sh` that all tests read from (which would also resolve the ISOLATION finding above).
