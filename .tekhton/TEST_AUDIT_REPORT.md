## Test Audit Report

### Audit Summary
Tests audited: 3 files, ~181 test functions
(test_output_format.sh: ~70 assertions; test_report.sh: ~33 assertions; test_tui.py: ~78 functions)
Verdict: PASS

### Findings

#### ISOLATION: test_report.sh uses TEKHTON_DIR before common.sh is sourced
- File: tests/test_report.sh:31–36
- Issue: Lines 31–36 assign `HUMAN_ACTION_FILE`, `INTAKE_REPORT_FILE`,
  `CODER_SUMMARY_FILE`, `SECURITY_REPORT_FILE`, `REVIEWER_REPORT_FILE`, and
  `TESTER_REPORT_FILE` using bare `${TEKHTON_DIR}` without a default:
  ```
  HUMAN_ACTION_FILE="${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md"
  ```
  `TEKHTON_DIR` is only initialised by `lib/artifact_defaults.sh`, which is
  sourced when `lib/common.sh` runs at line 39 — after these assignments. Under
  `set -u` (active at line 15), a truly unset `TEKHTON_DIR` aborts the script
  before any test runs. The suite passes in the pipeline environment because
  TEKHTON_DIR is already exported there, but the file cannot be run correctly
  in a plain `bash tests/test_report.sh` invocation in a fresh shell. This is a
  pre-existing pattern present in Suites 1–8; the new Suites 9 and 10 follow
  the same convention without worsening it.
- Severity: MEDIUM
- Action: Add `: "${TEKHTON_DIR:=.tekhton}"` before line 31, or move the
  `source lib/common.sh` call above the file-path variable block. Either fix
  makes the script runnable in isolation and is consistent with how
  `lib/artifact_defaults.sh` sets the canonical default.

#### COVERAGE: Suite 10 regression fixture omits the security findings > 0 branch
- File: tests/test_report.sh:329–376
- Issue: The regression fixture provides an empty `SECURITY_REPORT.md` and
  omits `security_findings_count` from `RUN_SUMMARY.json`, so
  `_report_stage_security` always takes the zero-findings branch
  (`${GREEN}PASS (no findings)${NC}`). The non-zero-findings branch
  (`${YELLOW}N finding(s)...${NC}`) is not exercised. Both branches route
  through `out_msg` with `_out_color`-generated codes, so the literal-escape
  regression guard would catch a leak in either branch — but the non-zero path
  is unverified.
- Severity: LOW
- Action: Add a second fixture variant with `"security_findings_count": 2` in
  `RUN_SUMMARY.json` and assert the rendered output is free of literal `\033[`.

### Clean Findings (no issues)

**Assertion honesty — PASS.** All expected values are derived from real
implementation calls, not hand-coded literals:
- `test_output_format.sh` test 2 computes `expected=$(printf '%b' "${BOLD}")` and
  compares against the actual return of `_out_color "${BOLD}"`, both of which call
  `printf '%b'` internally after the fix.
- `test_report.sh` Suite 9 computes `GREEN_E=$(printf '%b' "${GREEN}")` (and
  similarly RED_E, YELLOW_E, NC_E) then asserts `_report_colorize` returns the
  matching interpreted value — an honest round-trip through the real function.
- `test_report.sh` Suite 10 calls `print_run_report` against controlled fixtures
  and greps for `\033[` as a fixed string — the grep checks actual output bytes,
  not a stub.
- All three new `_build_context` tests in `test_tui.py` call the real
  `_build_context` from `tui_render.py`, render through `rich.console.Console`,
  and assert on the resulting string.

**Implementation exercise — PASS.** No test under audit mocks the function it
claims to verify. `_out_color`, `_report_colorize`, `print_run_report`, and
`_build_context` are all invoked against real code paths.

**Test weakening — PASS / none detected.** Suite 9 was strengthened: expected
values previously compared against literal backslash-octal strings; they now
compare against `printf '%b'` interpretations. The `_out_color` passthrough
test (test_output_format.sh test 2) gained two additional assertions
(`contains_ansi` and `assert_not_contains '\033'`) on top of the equality check.

**Test naming — PASS.** All names encode scenario and expected outcome:
`"_out_color: emits interpreted ESC bytes when NO_COLOR unset"`,
`"9.1 PASS maps to GREEN"`,
`"10.1 rendered output free of literal '\\033[' substring"`,
`test_build_context_renders_project_dir_when_set`,
`test_build_context_omits_project_dir_when_empty`,
`test_build_context_omits_project_dir_when_absent`.

**Scope alignment — PASS.** `.tekhton/JR_CODER_SUMMARY.md` was deleted by the
coder. No test file references `JR_CODER_SUMMARY_FILE` or imports from that
path. The STALE-SYM entries in the orphan list are all bash builtins (`bash`,
`echo`, `printf`, `source`, etc.) and Python stdlib modules — false positives
from the shell-level static analyser, not real orphans.

**Test isolation — PASS (with the one MEDIUM note above).** All shell suites
create fixtures in `mktemp -d` directories and set `PROJECT_DIR` to that temp
dir via the `trap` guard at line 19. No test reads live `.tekhton/` artifacts
or pipeline run state. The Python tests use `tmp_path` fixtures throughout.
