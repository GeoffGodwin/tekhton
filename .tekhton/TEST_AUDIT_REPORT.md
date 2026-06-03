## Test Audit Report

### Audit Summary
Tests audited: 2 bash files (primary audit), 3 Go files (freshness sample)
Bash assertions counted: ~34 in `test_milestone_window_focused.sh`,
12 in `test_finalize_commit_block_reason.sh` (46 total)
Verdict: PASS

---

### Findings

#### COVERAGE: Bold-label Watch For survival not asserted in extractor bold-label case
- File: tests/test_milestone_window_focused.sh:447–464
- Issue: The bold-label fixture block calls `_extract_first_paragraph_and_acceptance`
  with a fixture that includes `**Acceptance Criteria:**`, `**Watch For:**`, and item
  text. The only assertion is that `crit alpha` appears in the output. The parallel
  H2 fixture block (lines 432–444) asserts all three items — `crit one`, `watch one`,
  and `seed one`. Since the m41 CODER_SUMMARY claims both H2 and bold-label Watch For
  / Seeds Forward survive the truncation path, the bold-label case should also assert
  Watch For survival. The implementation happens to be correct (bold-label `**Watch
  For:**` does not match the `^#{1,5}[[:space:]]` terminator regex, so it flows
  through the accumulation loop unconditionally), but there is no assertion pin. A
  future regression that added bold-label heading detection would break the behavior
  without failing this test.
- Severity: MEDIUM
- Action: Add one assertion after the existing one at line 463:
  ```bash
  result=0
  echo "$output" | grep -q "watch alpha" && result=0 || result=1
  assert "[m41] extractor keeps **Watch For:** section through bold-label truncation" "$result"
  ```
  No implementation change needed.

#### COVERAGE: _final_check_result_read not directly exercised
- File: tests/test_finalize_commit_block_reason.sh:1–172
- Issue: `lib/finalize_commit_sentinel.sh` exports two functions:
  `_final_check_result_read` and `_final_check_reason_read`. The new test file
  directly exercises `_final_check_reason_read` across four cases and exercises
  `_hook_commit` which calls `_final_check_result_read` internally. There is no
  test that calls `_final_check_result_read` directly. The pre-existing
  `test_final_checks_commit_gate.sh` exercises the overall sentinel read-and-block
  path, so this is a gap in the new file rather than a gap in the suite.
- Severity: LOW
- Action: Optional — add direct `_final_check_result_read` cases (absent → 0,
  sentinel present → 1) to `test_finalize_commit_block_reason.sh`. Not required
  for PASS.

---

### Per-file rubric detail

**tests/test_milestone_window_focused.sh** (modified, 570 LOC, 34 assertions)

- *Assertion honesty*: All assertions derive from real function calls. Expected
  strings (`"Sliding Window"`, `"Seeds Forward"`, `"crit one"`, `"watch one"`,
  `"Downstream Bold-Label Fixture"`) come from fixture files written by the test
  itself. No hard-coded magic values. The `result` variable is set from the
  actual return code of the function under test.
- *Edge cases*: MILESTONE_MODE=false, empty _CURRENT_MILESTONE, unknown milestone ID
  (99), dotted id with no manifest row (49.2), stale DAG file entry (m10 with
  absent `m10-stale.md`), m-prefix fallback without `dag_number_to_id`, already-
  prefixed IDs. Error-path tests outnumber happy-path tests.
- *Implementation exercise*: Sources seven real lib files. Calls `set_focused_
  milestone_block`, `_read_milestone_file`, `_extract_first_paragraph_and_acceptance`
  directly on real implementations with real fixture files on disk.
- *Weakening*: None. Pre-existing 25 assertions are intact and structurally
  unchanged. The m41 and m41-stale blocks are additive from line 341 onward.
- *Naming*: Labels encode scenario and outcome:
  `"[m41] returns 0 for dotted id 49.2 (file on disk, no manifest row)"`,
  `"[m41-stale] returned content is from the glob-discovered file"`.
- *Scope alignment*: All referenced functions (`set_focused_milestone_block`,
  `_read_milestone_file`, `_extract_first_paragraph_and_acceptance`,
  `dag_get_file`, `load_manifest`) exist in the current implementation at the
  expected paths. The dotted-id glob path at `milestone_window.sh:129–152` is
  the exact code exercised by the 49.2 and m10-stale tests.
- *Isolation*: All fixtures created under `TMPDIR=$(mktemp -d)` with
  `PROJECT_DIR="$TMPDIR"` exported. Milestone files written to
  `$TMPDIR/.claude/milestones/`. `_dag_milestone_dir` resolves through
  `PROJECT_DIR + MILESTONE_DIR`, so no file operations touch the live repo.
  Fixture cleanup (`m49.2-bold-label-fixture.md` at line 466, `m10-current.md`
  at line 559) is in-test, not just on EXIT. No mutable run artifacts read.

**tests/test_finalize_commit_block_reason.sh** (NEW, 172 LOC, 12 assertions)

- *Assertion honesty*: All assertions match implementation behavior precisely.
  - Tests 2.1/3.1/4.1: Write sentinel via `trip_commit_gate` (or `printf`) then
    call `_final_check_reason_read`. Strip/trim logic at
    `finalize_commit_sentinel.sh:46–52` matches the expected values.
  - Tests 5.x: `_hook_commit 0` with a prewritten sentinel. The blocked path at
    `finalize_commit.sh:186–198` emits `"Commit blocked: ${_fcr_reason} (see ...)"`.
    Assertions 5.2 and 5.4 check for exactly those strings. Assertion 5.3 verifies
    the legacy `FINAL_CHECK_RESULT=0, persisted=1` contradiction is absent from
    operator output (it moved to `log_verbose` at `finalize_commit.sh:193`).
  - Tests 6.x: Reasonless sentinel (`printf '1\n'`). Fallback at
    `finalize_commit.sh:191` is `"Commit blocked: final checks failed (see ...)"`.
    Assertion 6.2 matches. Assertion 6.3 regex `'Commit blocked: *\(see'` (ERE:
    zero or more spaces before `(see`) correctly does NOT match the fallback text
    which has `"final checks failed"` between the colon and `(see`.
  - Test 7.1: `FINAL_CHECK_RESULT=1 _hook_commit 0` hits the in-memory path
    (`finalize_commit.sh:186`) while sentinel also carries the reason.
- *Edge cases*: absent sentinel, `# reason`, `#reason` (no space), padded
  whitespace, reasonless sentinel, in-memory FINAL_CHECK_RESULT. Good coverage.
- *Implementation exercise*: Calls `trip_commit_gate`, `_final_check_reason_read`,
  `_hook_commit` — real implementations. `git()` stub is appropriate and targeted;
  it only prevents actual commits while all logic under test runs live.
- *Weakening*: N/A — new file.
- *Naming*: Section headers like `"=== _hook_commit: prints the recorded reason in
  blocked warning ==="` plus per-assertion labels like `"5.2: blocked warning names
  the actual reason"` are descriptive and unique.
- *Isolation*: `TEKHTON_DIR="$TMP/.tekhton"` (absolute path). All sentinel reads
  and writes, `_write_commit_decision`, and the git flag file land in the temp tree.
  `trap 'rm -rf "$TMP"' EXIT` cleans up. No mutable pipeline artifacts read.

**Freshness-sample Go tests** (`internal/proto/tui_test.go`,
`internal/runner/complete_test.go`, `internal/runner/extra_test.go`)

All three files test Go types and runner logic in packages unrelated to the bash
subsystems modified by m41 (`lib/milestone_window*.sh`, `lib/finalize_commit*.sh`,
`stages/coder.sh`). No scope drift, stale function names, or orphaned references
detected. No action needed.
