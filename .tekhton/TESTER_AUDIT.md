## Test Audit Report

### Audit Summary
Tests audited: 3 files, 18 test functions
Verdict: PASS

---

### Findings

#### NAMING: Test H comment declares false "expected to fail" and misrepresents implementation ordering
- File: tests/test_plan_batch_emit_tail.sh:219-227
- Issue: The block comment for test H states "gsub(/\\n/, "\n", line) -- FIRST (current code)" and "It is expected to fail on the current implementation." Both claims are wrong. The actual implementation in `lib/plan_batch.sh:177` stashes `\\` to `\001` FIRST (`gsub(/\\\\/, "\001", line)`), then processes `\n`, then restores `\001` → `\` — the correct order that makes test H pass. The comment accurately described the pre-fix code but was not updated when the fix landed. A future reader will assume this test is a known-failing sentinel, may not investigate when it starts passing, and may even delete it to "remove a known-broken test."
- Severity: MEDIUM
- Action: Replace the "expected to fail" comment block with a regression-guard note. Document the correct current ordering (stash `\\` to placeholder first, then substitute `\n`/`\t`/`\"`, then restore placeholder to `\`). Remove the obsolete description of the broken ordering.

#### COVERAGE: Test F assertion is too weak to verify the stated intent
- File: tests/test_plan_batch_trim_preamble.sh:130-133
- Issue: The test description (file header line 6 and inline comment lines 126-131) says the goal is to verify that "`#word`" lines (no space after `#`) do NOT trigger heading detection, and that "only ^# (space) triggers." The assertion is `[[ -n "$output_f" ]]` — pass as long as output is non-empty. This would pass even if the function returned a single newline or garbage. The actual implementation's fast path at `lib/plan_batch.sh:204` checks `[[ "$first_line" == "#"* ]]`, which matches ANY `#`-prefixed first line including `#!/usr/bin/env bash`. The test does not verify which behavior actually occurred.
- Severity: MEDIUM
- Action: Replace `[[ -n "$output_f" ]]` with a check that the first output line equals `#!/usr/bin/env bash` (confirming the fast path returned content unchanged) and update the description to reflect the implementation's actual contract: any `#`-prefixed first line triggers the fast path, not only `^# ` with a space.

#### NAMING: Test F suite header description contradicts implementation behavior
- File: tests/test_plan_batch_trim_preamble.sh:6 (header coverage list)
- Issue: The header states "F — preamble contains a `#word` comment line (not a markdown heading): only ^# (space) triggers." The fast path at `lib/plan_batch.sh:204` triggers on `"#"*` (any `#` prefix), making `#!/usr/bin/env bash` and `#pragma once` trigger early-return — not only `^# ` with a trailing space. The "only ^# (space) triggers" claim applies to the slow path's `grep -n '^# '` search used when the fast path does NOT fire. Describing the function's behavior incorrectly here would mislead callers about when preamble stripping is safe to invoke.
- Severity: MEDIUM
- Action: Update the F entry in the header to: "F — first line starts with `#` (non-space): fast path returns content unchanged (^# space distinction applies only in the slow path)."

#### COVERAGE: Test K does not verify the short on-disk content was replaced (only that summary was written)
- File: tests/test_plan_batch_disk_rescued.sh:188-197
- Issue: Test K asserts `grep -q "I wrote a short CLAUDE.md"` in the final CLAUDE.md, confirming the summary text was written. It does not assert that the pre-existing `# Short Document` heading from the 5-line fixture file is absent. A regression that accidentally appended (`>>`) instead of overwrote (`>`) would still pass this assertion.
- Severity: LOW
- Action: Add `! grep -q "# Short Document" "${WORK_DIR}/CLAUDE.md"` as an additional condition to confirm the old disk content was replaced, not appended.

---

### Passing Checks (no action required)

**Assertion Honesty** — All 18 assertions derive from real function calls against fixture-generated inputs. No hard-coded magic values unrelated to the implementation logic were found. No tautological assertions (assertTrue(True), assertEqual(x,x)) present.

**Implementation Exercise** — All three files source the real implementation (`lib/plan_batch.sh`, `stages/plan_generate.sh`) and call real functions under test (`_plan_batch_emit_tail`, `_trim_document_preamble`, `run_plan_generate`). Only boundary dependencies are mocked: logging stubs, `_shim_resolve_binary`/`_shim_write_request`/`_shim_field` (binary-free shim layer), and `render_prompt`/DAG helpers. The function under test is never mocked.

**Test Weakening** — No pre-existing assertions were loosened or removed. The emit-tail file received one new test (G, H were already present); the trim-preamble and disk-rescued files are wholly new. No weakening detected.

**Test Naming** — All test functions use scenario-and-outcome labels consistent with the project convention (e.g., "I: disk_rescued=true — disk content preserved when stdout is non-heading summary"). Intent is readable across all 18 tests.

**Test Isolation** — All three files create fixtures inside `$(mktemp -d)` with `trap "rm -rf ..." EXIT`. No test reads live pipeline logs, run artifacts, or mutable project state files. The `WORK_DIR` temp tree is self-contained. Isolation is clean.

**Scope Alignment** — Implementation files referenced by the tests (`lib/plan_batch.sh:162-221`, `stages/plan_generate.sh`) exist, export the functions under test, and match the function signatures called by the tests. No orphaned imports or stale references found.

**Test K / _MIN_SUBSTANTIVE_LINES threshold** — Verified that `_MIN_SUBSTANTIVE_LINES=20` at `stages/plan_generate.sh:21` matches the threshold assumed by the test (5-line file ≤ 20 → not rescued). The `count_lines` stub at `test_plan_batch_disk_rescued.sh:43` correctly reads from stdin (`wc -l | tr -d ' '`), matching the `count_lines < "$file"` call pattern in the stage. The threshold comparison uses `-gt` (strictly greater than), so a file with exactly 20 lines is also not rescued — consistent with the test's 5-line fixture.
