## Test Audit Report

### Audit Summary
Tests audited: 16 files, 49 test functions
Verdict: PASS

No HIGH findings. The tests are structurally sound; three MEDIUM-severity issues
are logged for tracking: one missed implementation gap (stale comment the test
failed to catch), one vacuously-passing security test, and one assertion that does
not verify the specific routing outcome it names. Two LOW integrity weaknesses are
noted for follow-up.

**Note on prior report:** A prior run of this auditor wrote a report identifying
six tautological `|| true` issues. Those issues do not exist in the test files
currently on disk — the `|| true` suffix is absent from all assertions the prior
report flagged. That report was generated against an earlier draft; this report
supersedes it.

---

### Findings

#### SCOPE: Test failed to detect a surviving stale comment
- File: tests/test_coder_buildgate_retry_removed.sh:27
- Issue: `test_comment_updated` asserts
  `grep -q "run_build_fix_loop" ... || grep -q "Build gate" ...`. Both patterns
  exist in `stages/coder.sh` regardless of whether the targeted comment was
  updated, so the assertion always passes. The coder updated the inline comment
  at `stages/coder.sh:1109` ("retry depth driven by BUILD_FIX_MAX_ATTEMPTS") but
  left the function-header docstring at line 96 unchanged: it still reads
  `#   6. Build gate with one retry`. The test was the right place to catch this
  and did not.
- Severity: MEDIUM
- Action: Replace the loose presence check with an absence check for the stale
  phrase:
  `! grep -q "with one retry" "${TEKHTON_HOME}/stages/coder.sh"`
  That assertion would have caught the missed update and currently fails.

#### EXERCISE: Path-traversal test passes vacuously — guard never reached
- File: tests/test_milestone_split_path_traversal_malicious.sh:37–77
- Issue: All three test functions call `_split_apply_dag 1 "$split_output"` with
  `2>/dev/null`. Inside `_split_apply_dag`, the first call is
  `parent_id=$(dag_number_to_id "$milestone_num")`. `dag_number_to_id` is not
  stubbed and not defined, so bash returns exit 127 (command not found). With
  `set -euo pipefail` in effect, the function exits before reaching the
  path-traversal guard at `lib/milestone_split_dag.sh:83–86`. All three
  `if _split_apply_dag ...; then return 1; fi; return 0` tests then PASS because
  the function returned non-zero — not because the guard fired.
  If the guard were deleted from `lib/milestone_split_dag.sh`, all three tests
  would still pass.
- Severity: MEDIUM
- Action: Add stubs for `dag_number_to_id` (return `"m01"`), `dag_set_status`
  (no-op), and `save_manifest` (no-op) before sourcing the implementation. Also
  stub `_DAG_IDS`, `_DAG_TITLES`, `_DAG_STATUSES`, `_DAG_DEPS`, `_DAG_FILES`,
  `_DAG_GROUPS` arrays with at least one entry so the rebuild loop executes. Use
  a `_slugify` that does NOT strip slashes (or passes the title through) so the
  guard fires on the path-separator inputs. Then assert:
  - Function exits 1 (rejected) for `../../etc/passwd` title
  - Function exits 0 and produces a safe filename for a clean title

#### INTEGRITY: Threshold assertion accepts any valid routing token
- File: tests/test_error_patterns_classify_threshold.sh:52
- Issue: `test_noncode_dominant_at_exactly_60_percent` asserts only
  `[[ -n "$routing" ]] && [[ "$routing" =~ ^(code_dominant|noncode_dominant|mixed_uncertain|unknown_only)$ ]]`.
  `classify_routing_decision` always returns one of those four tokens for any
  input, so the assertion is trivially true. The test name claims to verify that
  60% noncode confidence routes to `noncode_dominant`, but the assertion would
  pass equally well if the result were `unknown_only`.
  Additionally, the test log data (`npm warn`, `yarn warn`, `pnpm notice`,
  two unmatched lines) actually routes to `unknown_only`, not `noncode_dominant`:
  the `npm warn` and `yarn warn` lines are classified as noise by
  `_is_non_diagnostic_line` and excluded from the classification statistics,
  leaving zero `matched_noncode`, which disqualifies Rule 2.
- Severity: MEDIUM
- Action: Replace `[[ "$routing" =~ ... ]]` with
  `[[ "$routing" == "noncode_dominant" ]]`. Also fix the test data so that
  noncode error patterns actually appear in the log (patterns from
  `_EP_PATTERNS` with `noncode` category, not just noise-filtered `npm warn`
  lines). The test for the threshold specifically requires lines that match a
  noncode *error pattern*, not merely noise-filtered package-manager chatter.

#### INTEGRITY: Always-true disjunction weakens the printf presence check
- File: tests/test_milestone_split_dag_printf.sh:12
- Issue: `test_milestone_split_dag_uses_printf` asserts
  `grep -q "printf" ... || grep -q "echo" ...`. Since `lib/milestone_split_dag.sh`
  contains `echo` in comments (e.g., the file banner), this disjunction is always
  true regardless of whether `printf` was ever added. The other two tests in the
  same file (`test_printf_replaces_echo` and `test_no_echo_with_variable`) cover
  the meaningful properties — this function adds no signal.
- Severity: LOW
- Action: Remove `|| grep -q "echo" ...` from the disjunction (or remove the
  function entirely and rely on the other two tests). The meaningful property is
  already verified by `grep -q "printf '%s"` in `test_printf_replaces_echo`.

#### INTEGRITY: Fallback clause makes ordering check trivially pass
- File: tests/test_diagnose_rules_source_numbering.sh:15
- Issue: `test_source_numbering_consistent` uses
  `echo "$func_text" | grep -q "Source 1.*RUN_SUMMARY\|Source.*RUN_SUMMARY" || echo "$func_text" | grep -q "RUN_SUMMARY"`.
  The fallback `grep -q "RUN_SUMMARY"` matches any occurrence of the string
  in the function body, including the variable `$summary_file` definition at the
  top of `_rule_build_fix_exhausted`. The test always passes. A reordering of
  sources (e.g., moving LAST_FAILURE_CONTEXT to Source 1) would not be caught.
- Severity: LOW
- Action: Remove the `||` fallback. Assert the full ordered prefix explicitly:
  ```bash
  echo "$func_text" | grep -q "Source 1.*RUN_SUMMARY" && \
  echo "$func_text" | grep -q "Source 2.*BUILD_FIX_REPORT\|Source 2.*BUILD_FIX" && \
  echo "$func_text" | grep -q "Source 3.*LAST_FAILURE_CONTEXT"
  ```
