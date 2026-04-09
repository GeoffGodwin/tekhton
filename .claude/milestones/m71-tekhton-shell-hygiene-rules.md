# Milestone 71: Tekhton Shell Hygiene Rules
<!-- milestone-meta
id: "71"
status: "pending"
-->

## Overview

~11% of all non-blocking reviewer findings are defensive-coding gaps specific
to bash: missing `|| true` on grep under `set -e`, `local var=$(cmd)` masking
exit codes (shellcheck SC2155), missing `--` before variable arguments. These
are mechanical, predictable rules that the coder would follow if told explicitly.

The current coder role file says "Follow the project's style guide and linting
rules" — too generic. This milestone adds explicit shell hygiene rules to
Tekhton's own project-level coder role file (`.claude/agents/coder.md`). This
is the correct location: project-specific rules live in the role file, not in
the reusable prompt template.

No new template variables. No pipeline changes. No changes to the reusable
`templates/coder.md` or `prompts/coder.prompt.md`. This is a single-file change
to the project's own agent configuration.

Depends on M70 so the self-check mechanism is already in place — the hygiene
rules give the coder concrete things to verify during that self-check step.

## Files to Modify

### 1. `.claude/agents/coder.md` — Add Shell Hygiene Section

Add a new section after the existing `### Shell Standards` section (which covers
`set -euo pipefail`, shellcheck, bash 4+, quoting, and `[[ ]]`). The new section
covers the specific patterns that reviewers catch repeatedly.

Add this section:

```markdown
### Shell Hygiene (prevents recurring reviewer findings)
These rules address the most common non-blocking findings from code review.
Follow them to produce cleaner output that passes review without notes.

- **grep under set -e:** `grep` returns exit code 1 when zero lines match,
  which kills `set -e`. Every `grep` call where zero matches is a valid
  (non-error) outcome must end with `|| true`. Pattern:
  `count=$(grep -c 'pat' file || true)`. Note: `sed` and `awk` return 0 on
  zero matches — they do NOT need `|| true` for this reason. Only add
  `|| true` to sed/awk when the command itself may fail (e.g., missing file).
- **Local variable assignment:** Never combine `local` with command substitution
  on the same line — `local var=$(cmd)` masks the exit code (shellcheck SC2155).
  Use two lines: `local var; var=$(cmd)`.
- **Option terminator:** Use `--` before arguments derived from variables in
  `grep`, `sed`, `rm`, and `find` to prevent flag injection.
  Pattern: `grep -- "$pattern" "$file"`
- **Sourced files:** `.sh` files sourced into the pipeline (`lib/`, `stages/`)
  must NOT have their own `set -euo pipefail` — they inherit the caller's
  settings. Only standalone entry-point scripts need it.
- **Stale references after rename:** When renaming a function or variable, use
  `grep -rn 'old_name'` across the project to find all references — including
  comments, log messages, error strings, and test fixtures. Update them all.
- **File length:** After your changes, run `wc -l` on every file you created or
  modified. If any exceeds 300 lines, extract functions into a new `_helpers.sh`
  or similar companion file. Do not leave files at 310–320 lines.
```

### 2. Verify existing test integrity

Run `bash tests/run_tests.sh` to confirm no test regressions. Since this
milestone only modifies `.claude/agents/coder.md` (a project role file, not
a template or library), no tests should be affected.

## Acceptance Criteria

- [ ] `.claude/agents/coder.md` has a `### Shell Hygiene` section
- [ ] Section contains rules for: grep `|| true`, SC2155 two-line local, `--`
      option terminator, sourced file `set -euo`, stale references, file length
- [ ] Each rule includes a concrete pattern/example
- [ ] No changes to `templates/coder.md` (the reusable template)
- [ ] No changes to `prompts/coder.prompt.md` (the prompt template)
- [ ] No changes to any `lib/` or `stages/` files
- [ ] `bash tests/run_tests.sh` passes with no new failures

## Watch For

- The sourced-file rule (`lib/` and `stages/` files must NOT have their own
  `set -euo pipefail`) is specific to Tekhton's architecture where all library
  files are sourced into `tekhton.sh`. This rule would be wrong for projects
  with standalone scripts. This is why it belongs in the project role file,
  not the reusable template.
- The file-length rule here is deliberately redundant with the strengthened rule
  in `templates/coder.md` (M70) and the self-check step in `coder.prompt.md`
  (M70). Triple reinforcement is intentional — this is the #1 non-blocker
  category and historically the coder has ignored single mentions.
- Do NOT add rules that are already covered by shellcheck (e.g., unquoted
  variables, `[ ]` vs `[[ ]]`). The existing "Shellcheck clean" rule handles
  those. The hygiene rules target patterns that shellcheck does NOT catch well
  or at all (like `|| true` on grep, or stale references after rename).
- The `|| true` rule is specific to `grep`. Do NOT extend it to `sed` or `awk`
  — those return 0 on zero matches. Blanket `|| true` on sed/awk masks real
  errors (malformed expressions, missing files).
- Keep the section concise. The role file is read at prompt start — excessive
  length reduces the coder's ability to retain later instructions.

## Seeds Forward

- If other bash projects adopt Tekhton, this section serves as a template for
  their own `.claude/agents/coder.md` shell hygiene section.
- The patterns documented here could eventually feed an automated pre-commit
  check in `lib/gates.sh`, but that is out of scope for this milestone.
