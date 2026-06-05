## Verdict
TWEAKED

## Confidence
52

## Reasoning
- The milestone title is self-describing enough to identify the bug: commit subject generation incorrectly falls back to showing `.claude/project_version.cfg` as part of the subject line
- The git history corroborates the regression — recent commits show subjects like `feat: changes in .claude/project_version.cfg`, which is clearly not the intended output
- However, the milestone has no body: no description of root cause, no files to modify, no acceptance criteria, and no definition of what the correct behavior should be
- "Stop falling back" is ambiguous without specifying what should happen instead — remove the fallback entirely, substitute a different value, or suppress the cfg file from subject generation?
- A developer familiar with `lib/finalize_commit.sh` and `lib/project_version.sh` could likely locate the bug, but acceptance criteria are entirely absent

## Tweaked Content

# M44: Commit subject regression: stop falling back to ".claude/project_version.cfg"

## Problem Statement

There is a regression in commit subject generation. When a run produces changes
only to `.claude/project_version.cfg` (the project version config cache), the
commit subject incorrectly surfaces the cache file path in the subject line, e.g.:

```
feat: changes in .claude/project_version.cfg
```

This is not meaningful to humans or git history readers. The subject should either
describe the actual versioned artifact that changed (e.g., the target project's
`VERSION` file, `package.json`, etc.) or use a generic version-bump subject if no
better signal is available.

[PM: Problem statement inferred from milestone title and recent git history showing
`feat: changes in .claude/project_version.cfg` as commit subjects.]

## Scope

Fix the commit subject generator so that `.claude/project_version.cfg` is never
surfaced as the primary changed file in a commit subject.

**In scope:**
- Identify where the fallback to `.claude/project_version.cfg` occurs in commit subject logic
- Remove or suppress the cfg cache path from subject generation
- Ensure the subject falls back to a sensible generic (e.g., `chore: version bump`) rather than the internal cache file

**Out of scope:**
- Changes to what `.claude/project_version.cfg` stores or how it is written
- Changes to the version bump logic itself

[PM: Scope derived from milestone title; confirm "out of scope" items with author if uncertain.]

## Expected Behavior

After this fix, a run that bumps the project version and produces changes to
`.claude/project_version.cfg` (with or without changes to other files) must NOT
produce a commit subject that mentions `.claude/project_version.cfg`.

Acceptable subject patterns include:
- `chore: bump version to X.Y.Z`
- `feat: <actual changed file or module description>`
- Any meaningful subject that does not expose the internal cache path

[PM: Acceptable patterns are illustrative — confirm the canonical fallback subject
format with the author before implementing.]

## Files Likely Involved

[PM: Not specified in original. Based on project structure:]
- `lib/finalize_commit.sh` — commit hook + `_do_git_commit` helpers; likely where subject generation occurs
- `lib/project_version.sh` — version file detection; may contribute the cfg path to the subject
- `lib/project_version_bump.sh` — version bump logic; may write or reference the cfg path

## Acceptance Criteria

- [ ] Running a milestone that triggers a version bump no longer produces a commit subject containing `.claude/project_version.cfg`
- [ ] The generated commit subject is human-readable and describes either the versioned artifact or uses a generic version-bump phrase
- [ ] Existing commit subject generation for non-version-bump runs is unaffected
- [ ] `shellcheck` passes on all modified `.sh` files with zero warnings

[PM: Acceptance criteria entirely absent in original — added above based on the stated regression.]

## Watch For

- The cfg file path may be injected via `PROJECT_VERSION_CONFIG` variable — ensure the fix filters on the *value* of that variable, not a hardcoded string
- If commit subject generation uses `git diff --name-only` or similar to pick the "primary" changed file, the filter must exclude Tekhton-internal paths (`.claude/`, `.tekhton/`) generally, not just the cfg file
- Regression: if `.claude/project_version.cfg` is the ONLY changed file (e.g., a version-only run), the fallback must still produce a valid non-empty subject

[PM: Watch For section absent in original — added based on likely implementation surface.]
