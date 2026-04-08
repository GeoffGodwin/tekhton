## Test Audit Report

### Audit Summary
Tests audited: 1 file, 28 test assertions (PASS/FAIL branches)
Verdict: CONCERNS

---

### Findings

#### WEAKENING: import_answer_file tests removed without justification
- File: tests/test_plan_answers.sh (removed ~40 lines from prior version)
- Issue: `import_answer_file()` (lib/plan_answers.sh:424–452) is still implemented and is the primary entry point for the web mode flow — the user fills a YAML file and it is loaded back into the system via `import_answer_file`. The prior test suite covered: (1) successful import and `load_answer` verification, (2) multi-line block scalar import, and (3) rejection of an invalid file (bad header). All three were removed. The new "Web Mode Integration" section (lines 365–411) tests only `save_answer` + `_parse_answer_field` — it does not exercise `import_answer_file` at all. The task explicitly asks to verify correctness in web mode.
- Severity: HIGH
- Action: Restore the `import_answer_file` tests (success path, multi-line answer path, invalid-file rejection path). These are directly relevant to the stated bug scope.

#### WEAKENING: rename_answer_file_done tests removed without justification
- File: tests/test_plan_answers.sh (removed ~10 lines from prior version)
- Issue: `rename_answer_file_done()` (lib/plan_answers.sh:477–480) is still implemented and exported. The prior test verified the source file was removed and the `.done` file created. Both assertions were dropped with no explanation in TESTER_REPORT.md.
- Severity: MEDIUM
- Action: Restore the two-assertion test for `rename_answer_file_done`. It is a pure, side-effect-only function that is easy to test and was correctly tested before.

#### INTEGRITY: Critical function returns masked with `2>/dev/null || true`
- File: tests/test_plan_answers.sh:129, 169, 189, 193, 203, 217, 253, 298, 308–309, 333, 348, 355, 385, 394–395
- Issue: Every call to `init_answer_file`, `save_answer`, and `export_question_template` is suffixed with `2>/dev/null || true`. This silences both stderr diagnostics and exit-code failures. If any of these functions malfunction (e.g., the escape bug is not fixed or a new regression is introduced), subsequent assertions will observe stale or empty file contents and can still pass — the suite can report 28 passed while the implementation is broken. For example: if `save_answer "architecture" "$quoted_answer"` fails silently, the round-trip check at lines 205–210 compares against what `_parse_answer_field` returns from the stale file (empty string), which does not equal `$quoted_answer`, so the `fail()` branch is reached — but only because the answer wasn't written, not because the escape logic is wrong. The root cause is masked.
- Severity: MEDIUM
- Action: Remove `|| true` from `save_answer` and `init_answer_file` call sites. These functions already handle their own error paths via `warn`/`return 1`. Retain `2>/dev/null` only on calls that are expected to fail (negative-path tests). At minimum, preserve exit codes so the test fails fast on infrastructure errors rather than propagating broken state.

#### COVERAGE: load_all_answers test verifies format but not answer content
- File: tests/test_plan_answers.sh:230–247
- Issue: The `load_all_answers` section checks (a) that 3+ lines are returned and (b) that the first line has 5 pipe-separated fields. Both assertions pass when all answers are empty — which is the initial state of the file from `init_answer_file`. The test does not verify that previously saved answers (overview, architecture, configuration — saved earlier in the same test run at lines 193–218) are actually present in the output. The assertion `$line_count -ge 3` is satisfied by the empty initialized file.
- Severity: MEDIUM
- Action: After saving answers in the round-trip section, call `load_all_answers` and verify that the specific expected answer text appears in a named field. For example: `echo "$all_answers" | grep "^overview|" | cut -d'|' -f5` should equal the saved value.

#### COVERAGE: _slugify_section direct tests removed
- File: tests/test_plan_answers.sh (removed ~10 lines from prior version)
- Issue: The prior test directly invoked `_slugify_section` with two cases: a title with ampersand/spaces and a simple title. These are now only indirectly exercised via `init_answer_file`. Direct unit tests provide a clear signal when slug logic breaks independently of the broader YAML write path.
- Severity: LOW
- Action: Restore or re-add direct `_slugify_section` assertions. Two cases: (1) "Developer Philosophy & Constraints" → `developer_philosophy_constraints`, (2) "Key User Flows" → `key_user_flows`.

#### SCOPE: TESTER_REPORT.md does not justify removals
- File: TESTER_REPORT.md
- Issue: The report states only "YAML escape/unescape and answer file round-trip tests" and lists `tests/test_plan_answers.sh` as modified. It provides no rationale for dropping `import_answer_file`, `rename_answer_file_done`, `_slugify_section`, the empty-answer roundtrip, or the whitespace-only answer test. The weakening flag (net loss of 1 assertion, 8 removed / 7 added) is consistent with this incomplete accounting.
- Severity: LOW
- Action: Tester should document which removed tests are intentional (with justification) versus accidental omissions. The `import_answer_file` removal in particular requires explicit justification given the task's explicit focus on web mode.

---

### What the New Tests Do Well
- The seven `_yaml_escape_dq` / `_yaml_unescape_dq` round-trip tests (lines 34–102) are well-structured, test real implementation logic with meaningful inputs, and cover edge cases (empty string, consecutive quotes, consecutive backslashes, mixed). These directly target the reported bug.
- The "Section Names with Special Characters" test (lines 152–182) correctly verifies that the escape character appears in the actual YAML output — a behavioral check, not a hard-coded assertion.
- The complex answer round-trip at lines 346–362 (quotes + backslash + colon + hash in a single `save_answer` → `_parse_answer_field` cycle) is a good integration test for the real bug scenario.
