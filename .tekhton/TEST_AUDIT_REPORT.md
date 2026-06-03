## Test Audit Report

### Audit Summary
Tests audited: 6 files (3 bash under primary audit, 3 Go proto as freshness sample), 60+ test functions/assertions
Verdict: PASS

---

### Findings

#### COVERAGE: bold-label Watch For survival not verified in extractor bold-label case
- File: tests/test_milestone_window_focused.sh:461
- Issue: The `[m41] extractor matches **Acceptance Criteria:** bold-label` assertion
  checks that `crit alpha` appears in `_extract_first_paragraph_and_acceptance` output
  for the bold-label fixture (lines 447–463), but does not check that `watch alpha`
  (from the `**Watch For:**` block) appears. The H2 case (lines 434–444) correctly
  asserts both acceptance criteria AND Watch For / Seeds Forward survival. For the
  bold-label case, Watch For survival is implicit — the accumulation loop naturally
  includes it because no `^#{1,5}` heading break fires on `**Watch For:**` — but
  the exemption code in `_extract_first_paragraph_and_acceptance:122-124` only
  guards against the H2 heading form. A test covering bold-label Watch For survival
  would distinguish "Watch For was kept because no heading broke the loop" from
  "Watch For was actively preserved by the exemption logic."
- Severity: LOW
- Action: Add one assertion after line 463:
  ```bash
  result=0
  echo "$output" | grep -q "watch alpha" && result=0 || result=1
  assert "[m41] extractor keeps **Watch For:** through bold-label truncation" "$result"
  ```

---

#### SCOPE: Go proto freshness-sample tests unaffected by m41
- File: internal/proto/pipeline_v1_test.go, internal/proto/run_v1_test.go, internal/proto/stage_v1_test.go
- Issue: None. These files test `PipelineAttemptRequestV1`, `RunRequestV1`, and
  `StageRequestV1` marshal/unmarshal and Validate() logic — a subsystem untouched
  by m41. Constants referenced (`StageCoder`, `StageReview`, `StageTester`,
  `StageDocs`, `StageIntake`, `StageCleanup`, `VerdictPass`, etc.) remain current.
  All three test files are in scope alignment with their implementations. No
  action needed.
- Severity: LOW (informational — freshness sample confirmed non-stale)
- Action: None.

---

### Per-file notes (no findings above LOW)

**tests/test_finalize_commit_block_reason.sh** (NEW, 172 LOC, 12 assertions)

- Assertion honesty: All assertions are derived from real implementation behavior.
  - Tests 2.1/3.1/4.1: Write sentinel via `trip_commit_gate` (or directly via
    `printf`) then call `_final_check_reason_read` — both functions exist in
    `lib/common.sh` and `lib/finalize_commit_sentinel.sh` and the assertions
    match the strip/trim logic at sentinel lines 46–52.
  - Tests 5.x: Call `_hook_commit 0` in a subshell with a sentinel prewritten by
    `trip_commit_gate`. The blocked path in `finalize_commit.sh:186–198` takes the
    `warn "Commit blocked: ${_fcr_reason} (see ...)"` branch — assertions 5.2 and
    5.4 check exactly those strings. Assertion 5.3 checks that the legacy
    contradictory `FINAL_CHECK_RESULT=0, persisted=1` string does not appear in
    stderr/stdout — confirmed correct, that string is now emitted only by
    `log_verbose`.
  - Tests 6.x: Sentinel with no reason line (`printf '1\n'`). The fallback at
    `finalize_commit.sh:191` is `"Commit blocked: final checks failed (see ...)"`.
    Assertion 6.2 matches. Assertion 6.3 regex `'Commit blocked: *\(see'` (ERE,
    zero or more spaces between `:` and `(see`) correctly fails to match the
    fallback that includes `final checks failed` between the two tokens — it guards
    against an empty-reason rendering like `"Commit blocked:  (see ..."`.
  - Test 7.1: `FINAL_CHECK_RESULT=1 _hook_commit 0` triggers the in-memory path
    (`finalize_commit.sh:186`); sentinel also written so reason reads correctly.
- Edge cases: absent sentinel, `# reason`, `#reason` (no space), padded whitespace,
  reason in blocked output, reasonless sentinel generic fallback, in-memory
  FINAL_CHECK_RESULT path. Full coverage of `_final_check_reason_read` contract.
- Implementation exercise: Calls `trip_commit_gate`, `_final_check_reason_read`,
  `_hook_commit` — real implementations, not mocks.
- Test isolation: `TEKHTON_DIR` set to `$TMP/.tekhton` (absolute path); all
  sentinel reads/writes and `_write_commit_decision` land in the temp dir.
  `trap 'rm -rf "$TMP"' EXIT` cleans up. `git()` stubbed to detect unexpected
  calls via a flag file in the temp dir. `finalize_commit_staging.sh` confirmed
  to exist on disk.

**tests/test_coder_block_unavailable_gate.sh** (NEW, 104 LOC, 5 assertions)

- Testing approach: structural grep against `stages/coder.sh` — acknowledged and
  justified in the test file header. Pattern matches `tests/test_tekhton_dir_root_cleanliness.sh`
  and `scripts/wedge-audit.sh` precedents. Appropriate here because `stages/coder.sh`
  is 1200+ lines and requires the full pipeline environment to exercise end-to-end.
- Assertion honesty: All grep patterns verified against the actual implementation:
  - AC2 absence check (`trip_commit_gate.*milestone_block_unavailable`) — pattern
    is absent from `coder.sh:240–262` post-m41. ✓
  - Warn string `"hollow-run gates remain in effect"` — present at `coder.sh:260`. ✓
  - Warn string `"MILESTONE_BLOCK could not be populated"` — present at `coder.sh:259`. ✓
  - AC3 `trip_commit_gate "coder_did_not_produce_summary"` — gate untouched by m41. ✓
  - AC3 `trip_commit_gate "completion_gate_failed_substantive_work_only"` — gate untouched. ✓
  - Broad scan of `stages/` and `lib/` for the removed gate — no false positives. ✓
- Isolation: Reads version-controlled source files only (not mutable build artifacts or
  pipeline logs). Structural grep tests have no side effects and no state to isolate.
  The rubric's isolation concern applies to mutable run-time state files, not to
  source code that is stable within a commit.

**tests/test_milestone_window_focused.sh** (modified, 570 LOC, 34+ assertions; m41 additions from line 341)

- Assertion honesty: All m41 additions tested against real implementation paths.
  - Dotted-id tests (341–405): Create `m49.2-bold-label-fixture.md` in the temp
    MILESTONE_DIR, call `set_focused_milestone_block` with `_CURRENT_MILESTONE=49.2`.
    Assertions check for fixture content (`Downstream Bold-Label Fixture`),
    bold-label sections (`**Watch For:**`, `**Seeds Forward:**`), and the
    resolved id in the header (`m49\.2`). All match what `milestone_window.sh:85–98`
    produces.
  - Extractor tests (407–464): Call `_extract_first_paragraph_and_acceptance` with
    inline fixtures and check outputs. H2 assertions at lines 434–444 match the
    function's `##` heading matching at `milestone_window_build.sh:112` and the
    Watch-For/Seeds-Forward exemption at lines 122–124. Bold-label assertion at line
    462 matches the regex at `milestone_window_build.sh:112` which covers
    `\*\*...(A|a)cceptance`.
  - Stale-DAG tests (469–560): Direct in-memory array manipulation adds `m10` with
    a stale file reference. Verifies `dag_get_file` returns the stale name, the stale
    file is absent, glob finds `m10-current.md`, and both `_read_milestone_file` and
    `set_focused_milestone_block` succeed. Mirrors the exact code path in
    `milestone_window.sh:116–152` (DAG-known path absent → shopt nullglob → glob loop).
- Fixture cleanup: `m49.2-bold-label-fixture.md` removed at line 466;
  `m10-current.md` removed at line 559. Reproducible across repeated runs.
- Pre-existing assertions (lines 139–339): No weakening detected. Content structure,
  instruction text, full-content guarantee, unknown milestone, m-prefix fallback, and
  cold-start manifest tests are all intact.
