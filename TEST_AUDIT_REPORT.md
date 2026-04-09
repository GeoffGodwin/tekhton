## Test Audit Report

### Audit Summary
Tests audited: 2 files, ~102 test assertions
Verdict: CONCERNS

### Findings

#### COVERAGE: Over-budget test never triggers the over-budget path
- File: tests/test_init_synthesize.sh:237-250
- Issue: The test "_compress_synthesis_context: over budget — index unchanged (M68: reader bounds it)" sets `DETECTION_REPORT_CONTENT` to 200,001 chars and `PROJECT_INDEX_CONTENT` to 25 chars. Total ≈ 200,826 chars ÷ 4 (CHARS_PER_TOKEN) ≈ 50,207 tokens. `check_context_budget` for model "opus" at 50% of a 200k-token window enforces a budget of 100,000 tokens. 50,207 < 100,000, so `_compress_synthesis_context` returns early on the "within budget" path without entering any compression logic. `PROJECT_INDEX_CONTENT` is left unchanged — but because compression was never triggered, not because of the M68 guard. A regression that reinstated `summarize_headings` on the index inside the over-budget branch would not be caught. This is confirmed by reading `lib/context.sh:136-151` (`check_context_budget`) and `lib/init_synthesize_helpers.sh:129-175` (`_compress_synthesis_context`).
- Severity: HIGH
- Action: Increase fixture sizes so total chars exceed ~400,001 (100,001 tokens at 4 chars/token). For example: set `PROJECT_INDEX_CONTENT` to 200,001 '#' chars and `DETECTION_REPORT_CONTENT` to 200,001 'D' chars (total ≈ 400,002 chars ≈ 100,001 tokens, just over the 100k budget). Then assert `PROJECT_INDEX_CONTENT` is still `"bounded index from reader"` (i.e., it was NOT subjected to summarize_headings). The git-log-truncation test at lines 254-274 already uses this approach correctly and can serve as a template.

#### COVERAGE: Sample budget test passes on empty output, not bounded output
- File: tests/test_index_reader.sh:431-436
- Issue: `read_index_samples "$PROJ" 50` is called with a 50-char budget. Inside the function (`lib/index_reader.sh:304-310`), the loop computes `remaining=$((50 - 0))` = 50, then checks `[[ "$remaining" -le 100 ]] && break` — 50 ≤ 100 is true, so the loop breaks immediately and returns empty output. `SAMPLE_SIZE=${#SAMPLES_SMALL}` = 0. The assertion `[[ "$SAMPLE_SIZE" -lt 200 ]]` trivially passes on 0 chars. If the budget guard were removed, the function would return all sample content, but `SAMPLE_SIZE` would still be a few hundred chars and `< 200` would still pass. The test labelled "respects max_chars budget" does not actually verify that partial content is bounded within the budget.
- Severity: MEDIUM
- Action: Add a second budget assertion using a value large enough to include at least one sample but small enough to exclude the second. The fixture README sample is ~34 chars of content; set budget to ~120 chars. Assert `echo "$result" | grep -q 'README.md'` AND `! echo "$result" | grep -q 'src/index.ts'` to verify exactly one sample is included.

#### NAMING: Test name claims PLAN_INCOMPLETE_SECTIONS is verified; assertion is a smoke test
- File: tests/test_init_synthesize.sh:429-442
- Issue: The test is titled "_check_synthesis_completeness: thin section detected and PLAN_INCOMPLETE_SECTIONS formatted". The body `eval`s `_check_synthesis_completeness "$PROJECT_DIR" > /dev/null 2>&1 || true; echo "done"` and asserts `[[ "$result" == "done" ]]` — verifying only that the function did not crash. The test comment at line 433-435 acknowledges that `PLAN_INCOMPLETE_SECTIONS` is exported and then unset inside the function after `_synthesize_design` is called, so it cannot be inspected post-call. No aspect of the formatting (`sed '/^$/d' | sed 's/^/- /'`, `lib/init_synthesize_helpers.sh:220`) is exercised.
- Severity: MEDIUM
- Action: Either rename the test to "_check_synthesis_completeness completes without error on thin sections" to match what is asserted, OR capture stderr (`2>&1`) and verify the warn output includes the thin section name: `echo "$warn_result" | grep -q "ThinSection"`. The `warn` output from `lib/init_synthesize_helpers.sh:214-216` lists each thin section name and is visible in stderr.

#### NAMING/COVERAGE: Consumer sections re-test the reader API at different budgets, not actual consumer call sites
- File: tests/test_index_reader.sh:590-644
- Issue: The sections "Intake consumer — structured project" (line 590), "Intake consumer — legacy project" (line 603), "Synthesis consumer — bounded without summarize_headings" (line 616), and "Replan consumer — bounded" (line 636) all call `read_index_summary` directly. The M68 migration wired up `read_index_summary` in `stages/intake.sh`, `lib/replan_brownfield.sh`, and `lib/init_synthesize_helpers.sh`. The intake and replan call sites are not exercised by either test file. `_assemble_synthesis_context` (synthesis call site) is tested in `test_init_synthesize.sh:99-107`, which is adequate. The section labels overstate what is covered.
- Severity: LOW
- Action: Rename the intake and replan consumer sections to reflect their actual scope: "read_index_summary: 8KB budget returns non-empty output" and "read_index_summary: 40KB budget returns bounded output". Add a note (inline comment) that direct intake/replan call-site coverage is a future gap.
