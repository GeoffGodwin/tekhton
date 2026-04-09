# Milestone 70: Coder Pre-Completion Self-Check
<!-- milestone-meta
id: "70"
status: "done"
-->

## Overview

Analysis of 14 historical REVIEWER_REPORT.md files shows that ~60% of all
non-blocking reviewer findings are issues the coder could have caught itself
before completing. File length violations alone account for ~38% of all
non-blockers — the same files (tester.sh, gates.sh, metrics.sh) get flagged
repeatedly across runs because the coder reads the 300-line rule at the start,
implements for 30–80 turns, and forgets the rule by completion time.

This milestone adds a mandatory pre-completion self-check step to the coder
prompt's Execution Order and strengthens the 300-line rule in the default role
template. No new template variables. No pipeline infrastructure. Pure prompt
engineering targeting the dominant non-blocker categories.

Depends on M66 (V3 Final Polish complete) as the stable baseline.

## Files to Modify

### 1. `prompts/coder.prompt.md` — Add Step 5 Self-Check and Strengthen Scope

**Change A: Strengthen the Scope Adherence section (~line 122)**

After the existing scope paragraph, append guidance for out-of-scope issues.
The current text says "Do not expand scope" but gives the coder no outlet —
so it either ignores problems (unlikely) or fixes them (creating scope-creep
non-blockers). The new text gives an explicit recording mechanism.

Add after the existing "Scope Adherence" paragraph (do NOT replace it):

```markdown
**Do NOT fix problems you discover outside your task scope.** If you notice bugs,
style issues, missing error handling, or improvement opportunities in files you are
reading that are unrelated to your task, record them in CODER_SUMMARY.md under
`## Observed Issues (out of scope)` — one bullet per item with file path and brief
description. The pipeline routes these to the appropriate cleanup mechanism. Fixing
out-of-scope issues wastes review cycles and creates unnecessary non-blocking findings.
```

**Change B: Insert Step 5 self-check into the Execution Order section (~line 127)**

The current Execution Order has 5 steps. Insert a new Step 5 between the current
Step 4 (run analyze/test) and Step 5 (update CODER_SUMMARY.md). Renumber the
old Step 5 to Step 6.

Insert after `**Step 4:** Run \`{{ANALYZE_CMD}}\` and \`{{TEST_CMD}}\`.`:

```markdown
**Step 5: Pre-Completion Self-Check (mandatory before setting COMPLETE).**
Before updating CODER_SUMMARY.md to COMPLETE, verify each item. Fix violations
NOW — do not leave them for the reviewer:
- **File length:** Every file you created or modified must be under 300 lines
  (`wc -l`). If any file exceeds 300 lines, extract functions into a new file
  until it is under 300. Do not leave a file at 310 or 320 lines — the ceiling
  is 300.
- **Stale references:** If you renamed a function, variable, config key, or
  constant, grep the project for the OLD name. Update any remaining references
  in comments, docs, log messages, and error strings.
- **Dead code:** Remove any variables you declared but never read, functions
  you wrote but never call, and conditional branches that are unreachable.
- **Consistency:** If you added a new file, verify it appears in
  CODER_SUMMARY.md under `## Files Modified` with the annotation `(NEW)`.
  If the project has a repository layout section in CLAUDE.md or
  ARCHITECTURE.md, add the new file there.
```

Renumber the current Step 5 to:

```markdown
**Step 6:** Update `CODER_SUMMARY.md` with final status, root cause, and files modified.
```

### 2. `templates/coder.md` — Strengthen 300-Line Rule and Fix Summary Conflict

**Change C: Strengthen the 300-line rule in Code Quality section**

Replace the current bullet:
```
- Keep files under 300 lines. Split if longer.
```

With:
```markdown
- **300-line hard ceiling.** Every file you create or modify must be under 300
  lines after your changes. If a file exceeds 300 lines, extract helper
  functions into a new file immediately — do not leave it for a future cleanup.
  Run `wc -l` on every file you touched before finishing. The reviewer treats
  this as a recurring finding; prevent it by checking before you finish.
```

**Change D: Fix the CODER_SUMMARY.md instruction conflict in Required Output section**

The current text says "Create CODER_SUMMARY.md **before writing any code**" but
the phrasing is easy to misinterpret. The coder failed to produce CODER_SUMMARY.md
at all in ~6% of runs. Replace the Required Output section header and first
paragraph with emphatic write-first language that aligns with the prompt's Step 1.

Replace from `## Required Output` through the paragraph before the skeleton with:

```markdown
## Required Output

`CODER_SUMMARY.md` is your primary deliverable alongside your code changes.

**Write-first rule:** Create `CODER_SUMMARY.md` with the IN PROGRESS skeleton as
your VERY FIRST action — before reading files, before writing any code. The
execution order in the prompt controls this. If CODER_SUMMARY.md does not exist
on disk after your run, the pipeline classifies your run as a failure regardless
of what code you produced.
```

Then replace the post-skeleton paragraph (the paragraph starting with "Update the
file throughout your work..." through "Required sections:") with:

```markdown
**Update continuously:** Update the file throughout your work as you complete items.
As you implement, update `## What Was Implemented` and `## Files Modified` after each
logical change. Do not batch updates to the end.

**Finalize last:** As your final act, set `## Status` to `COMPLETE` (or leave
`IN PROGRESS` if work remains) after passing the pre-completion self-check. Ensure
all sections reflect what was actually done. Required sections:
```

Keep the skeleton block between these two paragraphs unchanged. Keep the
required-sections bullet list that follows the post-skeleton paragraph unchanged.
The key phrases `before writing any code`, `IN PROGRESS skeleton`,
`Update the file throughout your work`, `As your.*final act`,
`set.*## Status.*to.*COMPLETE`, and `Do NOT set COMPLETE if any planned work is
unfinished` must all be preserved — existing tests grep for them.

Add to the required sections list:
```
- `## Observed Issues (out of scope)`: problems noticed but not fixed (when applicable)
```

### 3. `tests/test_coder_role_before_code.sh` — Verify tests still pass

This test greps `templates/coder.md` for exact phrases. All of these phrases
MUST appear in the new text (see "preserved phrases" note in Change D above):
- `'before writing any code'`
- `'IN PROGRESS skeleton'`
- `'Update the file throughout your work'`
- `'As your.*final act'` (regex)
- `'set.*## Status.*to.*COMPLETE'` (regex)
- `'Do NOT set COMPLETE if any planned work is unfinished'`

Run `bash tests/test_coder_role_before_code.sh` and
`bash tests/test_coder_role_summary_structure.sh` to verify no regressions.

## Acceptance Criteria

- [ ] `prompts/coder.prompt.md` has a 6-step Execution Order (was 5)
- [ ] Step 5 contains file-length, stale-references, dead-code, and consistency checks
- [ ] Scope Adherence section includes the "record, don't fix" paragraph with
      `## Observed Issues (out of scope)` guidance
- [ ] `templates/coder.md` Code Quality section has the strengthened 300-line rule
      with `wc -l` instruction
- [ ] `templates/coder.md` Required Output section has write-first emphasis and
      pipeline-failure consequence language
- [ ] All 6 key phrases from `test_coder_role_before_code.sh` are present in
      the new `templates/coder.md` text
- [ ] `bash tests/test_coder_role_before_code.sh` passes (8/8)
- [ ] `bash tests/test_coder_role_summary_structure.sh` passes (11/11)
- [ ] `bash tests/test_coder_role_status_field.sh` passes (10/10)
- [ ] `bash tests/run_tests.sh` passes with no new failures
- [ ] `shellcheck` clean on any `.sh` files modified
- [ ] No new template variables introduced
- [ ] No changes to pipeline infrastructure (`lib/`, `stages/`) — prompt-only changes

## Watch For

- The self-check step must say "Every file you **created or modified**" — not
  "every file in the project." The coder should only check files it touched,
  not audit the entire codebase for 300-line violations.
- The phrase `Update the file throughout your work` must appear verbatim in
  `templates/coder.md` — `test_coder_role_before_code.sh` Test 3 greps for it.
- Do NOT change the CODER_SUMMARY.md skeleton block (the ``` section with
  `## Status: IN PROGRESS`, `(fill in as you go)` placeholders). Multiple
  tests and the unfilled-skeleton detector in `stages/coder.sh:768` grep for
  these exact placeholder strings.
- The `## Observed Issues (out of scope)` section in CODER_SUMMARY.md is
  informational only — no pipeline parser reads it. If a downstream consumer
  is added later (e.g., to auto-feed cleanup), that's a separate milestone.
- The reviewer agent DOES read CODER_SUMMARY.md in full. Without guidance it
  may flag items in `## Observed Issues` as things the coder should have fixed,
  creating the exact non-blocker findings this milestone aims to prevent. A
  follow-up milestone should add a one-liner to `prompts/reviewer.prompt.md`
  telling the reviewer to ignore this section (it's routed to cleanup, not
  review). Not in scope here — the section is new and the reviewer won't
  encounter it until M70 ships.

## Seeds Forward

- M71 adds bash-specific hygiene rules to Tekhton's own project role file,
  building on the self-check approach established here.
- The `## Observed Issues` section creates a structured channel that could
  feed the cleanup agent in a future milestone.
- The self-check step lives in `coder.prompt.md` only. `coder_rework.prompt.md`
  and `jr_coder.prompt.md` have no execution order and don't inherit it. A
  future milestone could add a lightweight "verify your rework didn't introduce
  file-length violations" step to the rework prompt.
- A follow-up should add a one-liner to `prompts/reviewer.prompt.md` telling
  the reviewer to ignore `## Observed Issues (out of scope)` in CODER_SUMMARY.md.
