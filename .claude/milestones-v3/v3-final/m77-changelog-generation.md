# Milestone 77: CHANGELOG Generation at Finalize
<!-- milestone-meta
id: "77"
status: "done"
-->

## Overview

M76 ships target-project version bumping. This milestone (Part 2 of 2 on
versioning) adds **CHANGELOG generation** on top of it: every time the
version bumps, Tekhton appends a keep-a-changelog entry to `CHANGELOG.md`
summarizing what the milestone shipped.

Depends on **M76** — reads `parse_current_version` from
`lib/project_version.sh` and `get_version_bump_hint` from
`lib/project_version_bump.sh`.

The entry is synthesized from existing sources — `CODER_SUMMARY.md`
(what the coder did), milestone title from `MANIFEST.cfg`, and
optionally the `## Docs Updated` section (from M74) — so no new agent
invocation is required. This keeps M77 cheap: it's a pure file-assembly
milestone.

## Design Decisions

### 1. Keep a Changelog 1.1.0 format

Standard keep-a-changelog format with sections `Added`, `Changed`,
`Deprecated`, `Removed`, `Fixed`, `Security`. Section selection comes
from the coder's commit type (`feat`/`fix`/`refactor`/...) mapped as:

| Commit type | Changelog section |
|-------------|-------------------|
| feat        | Added (if new surface) or Changed |
| fix         | Fixed |
| refactor    | Changed |
| perf        | Changed |
| security    | Security |
| deprecate   | Deprecated |
| remove      | Removed |
| docs        | (skipped — no changelog entry for docs-only runs) |
| chore/test  | (skipped) |

### 2. Entry template

```markdown
## [1.2.3] - 2026-04-12

### Added
- New `--draft-milestones` interactive flow (M80)
- Documentation Strategy section to plan templates (M74)

### Fixed
- HUMAN_NOTES.md blank-line accumulation (M73)

### Changed
- Tekhton artifacts now live under `.tekhton/` (M72)
```

Milestone number in parentheses lets readers trace entries back to
milestone files. Drawn from `_CURRENT_MILESTONE` env var set by the
milestone runtime.

### 3. Bullet synthesis

Per-run, pull bullets from three sources (in order of priority):

1. **Milestone title** from `MANIFEST.cfg` row (short, human-phrased).
2. **First non-empty paragraph of `CODER_SUMMARY.md`** — usually a
   one-sentence description of what was done.
3. **`## Breaking Changes` / `## New Public Surface`** subsections if
   present — each top-level bullet becomes a separate changelog entry.

Fall back to the commit message's first line if `CODER_SUMMARY.md` is
missing or empty.

### 4. Initialize CHANGELOG.md at init time

If `CHANGELOG_ENABLED=true` and no `CHANGELOG.md` exists, create one on
first run (or during `--init`) with the canonical header:

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
```

Entries are inserted between `## [Unreleased]` and the most recent
release. The `## [Unreleased]` header stays at the top and accumulates
pending changes between bumps — so advice-only runs or no-commit runs
still add bullets there.

### 5. Config surface

```bash
: "${CHANGELOG_ENABLED:=true}"
: "${CHANGELOG_FILE:=CHANGELOG.md}"
: "${CHANGELOG_FORMAT:=keep-a-changelog}"   # future: conventional-commits
: "${CHANGELOG_INIT_IF_MISSING:=true}"
```

`CHANGELOG_FILE` stays at the project root (not `.tekhton/`) — this is
a user-facing artifact, like README.md. Intentional exception to M72's
relocation.

### 6. Skip non-commit runs entirely

If `_do_git_commit` wasn't called with a diff, no changelog entry is
written. No `## [Unreleased]` bullets get added either — because there
was nothing to unrelease. Zero-diff runs are a no-op for M77.

### 7. Idempotency via version anchoring

The changelog insertion checks for an existing `## [X.Y.Z]` heading
before inserting. If found (i.e., this version already has an entry —
re-running on the same version), the bullets are APPENDED to the
existing section rather than creating a duplicate header. Prevents
corrupted CHANGELOGs on re-run.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| New lib | 1 | `lib/changelog.sh` |
| New config vars | 4 | CHANGELOG_ENABLED, CHANGELOG_FILE, CHANGELOG_FORMAT, CHANGELOG_INIT_IF_MISSING |
| Finalize hook | 1 | `_finalize_changelog_append` |
| Tests | 2 | Initialize + entry assembly |
| Init integration | 1 | `lib/init.sh` creates CHANGELOG.md stub if missing |

## Implementation Plan

### Step 1 — Config + template vars

Edit `lib/config_defaults.sh` — add four CHANGELOG_* vars.
Edit `lib/prompts.sh` — register as template vars.

### Step 2 — Changelog library

Create `lib/changelog.sh` with:

```bash
# changelog_init_if_missing PROJECT_DIR
# changelog_assemble_entry VERSION MILESTONE_ID COMMIT_TYPE BULLETS_FILE
# changelog_append PROJECT_DIR VERSION ENTRY_CONTENT
```

Keep functions pure where possible:
- `changelog_init_if_missing` — just checks existence and writes stub
- `changelog_assemble_entry` — takes inputs, emits entry markdown to stdout
- `changelog_append` — inserts into CHANGELOG.md between Unreleased and
  previous release, respecting the idempotency rule from Decision #7

### Step 3 — Bullet synthesis helpers

In the same file, add:

```bash
_changelog_extract_coder_bullet FILE      # first non-empty para
_changelog_extract_breaking FILE          # ## Breaking Changes bullets
_changelog_extract_new_surface FILE       # ## New Public Surface bullets
_changelog_map_commit_type TYPE           # feat → Added, fix → Fixed, ...
```

Each is a small awk/grep one-liner. No external dependencies beyond
coreutils.

### Step 4 — Finalize hook

Add `_finalize_changelog_append` function. Logic:

1. If `CHANGELOG_ENABLED=false` → return 0.
2. If last commit diff is empty → return 0.
3. Read current version (from `lib/project_version.sh` — M76 dep).
4. Read milestone ID from `_CURRENT_MILESTONE` or MANIFEST.cfg active row.
5. Assemble entry, append to CHANGELOG.
6. If `CHANGELOG_INIT_IF_MISSING=true` and file doesn't exist, create it
   first.

Register the hook in `tekhton.sh` AFTER the version-bump hook from M76
— so the changelog knows the new version.

### Step 5 — Init integration

Edit `lib/init.sh` or `lib/init_helpers.sh` — during init, if
`CHANGELOG_ENABLED=true` and no CHANGELOG.md exists, create the stub.
Small addition — one new function call in the existing init sequence.

### Step 6 — Tests

`tests/test_changelog_init.sh`:
- Empty project + `CHANGELOG_ENABLED=true` → stub created
- Empty project + `CHANGELOG_ENABLED=false` → no stub
- Existing CHANGELOG.md → untouched

`tests/test_changelog_append.sh`:
- Fresh CHANGELOG → first entry inserted under Unreleased
- Existing CHANGELOG with prior release → new entry inserted above it,
  original entries intact
- Re-run on same version → bullets appended to existing section, no dup
  header
- Run with empty coder summary → bullets sourced from MANIFEST.cfg title

### Step 7 — Shellcheck + tests + bump

```bash
shellcheck lib/changelog.sh
bash tests/run_tests.sh
```

Edit `tekhton.sh` — `TEKHTON_VERSION="3.77.0"`.
Edit manifest — M77 row with `depends_on=m76`, group `runtime`.

## Files Touched

### Added
- `lib/changelog.sh`
- `tests/test_changelog_init.sh`
- `tests/test_changelog_append.sh`
- `.claude/milestones/m77-changelog-generation.md` — this file

### Modified
- `lib/config_defaults.sh` — four CHANGELOG_* vars
- `lib/prompts.sh` — register as template vars
- `lib/finalize.sh` — register new hook
- `lib/init.sh` or `lib/init_helpers.sh` — CHANGELOG stub on init
- `tekhton.sh` — source new lib, register finalize hook, bump version
- `tests/run_tests.sh` — register new tests
- `.claude/milestones/MANIFEST.cfg` — M77 row

## Acceptance Criteria

- [ ] `lib/changelog.sh` defines `changelog_init_if_missing`,
      `changelog_assemble_entry`, `changelog_append`
- [ ] Config has four `CHANGELOG_*` variables with correct defaults
- [ ] `CHANGELOG_FILE` default is `CHANGELOG.md` (at project root,
      NOT under `.tekhton/`)
- [ ] `_finalize_changelog_append` hook registered AFTER version-bump hook
- [ ] Init creates CHANGELOG.md stub when missing and
      `CHANGELOG_INIT_IF_MISSING=true`
- [ ] Entry inserted between `## [Unreleased]` and previous release
- [ ] Re-running on the same version appends to existing section, no
      duplicate `## [X.Y.Z]` headers
- [ ] Commit type mapping: feat→Added, fix→Fixed, refactor→Changed,
      security→Security, deprecate→Deprecated, remove→Removed, docs→skipped
- [ ] Zero-diff runs do not write entries
- [ ] `## Breaking Changes` subsection bullets become Changelog bullets
- [ ] `## New Public Surface` subsection bullets become Changelog bullets
- [ ] `tests/test_changelog_init.sh` passes
- [ ] `tests/test_changelog_append.sh` passes all scenarios
- [ ] `bash tests/run_tests.sh` passes with zero failures
- [ ] `shellcheck lib/changelog.sh` reports zero warnings
- [ ] `lib/changelog.sh` ≤ 300 lines
- [ ] `tekhton.sh` `TEKHTON_VERSION` is `3.77.0`
- [ ] `.claude/milestones/MANIFEST.cfg` contains the M77 row
      (`depends_on=m76`, group `runtime`)

## Watch For

- **Hook order matters.** M76's version bump MUST run before M77's
  changelog append. Register M77's hook AFTER M76's. Verify the order
  with a grep of `register_finalize_hook` calls.
- **CHANGELOG.md stays at root.** M72 relocated Tekhton-managed files
  to `.tekhton/`, but CHANGELOG.md is a user-facing artifact like
  README.md. It explicitly stays at the project root. Do NOT include
  it in any M72 migration list.
- **Idempotency on re-run.** A rework cycle that re-runs the coder on
  the same milestone should NOT write a second `## [X.Y.Z]` header.
  The append function's first check is "does this version already have
  a section?" — if yes, append bullets to it.
- **Empty CODER_SUMMARY.md fallback.** When the summary is empty or
  missing, synthesize a bullet from the milestone title + commit
  message first line. Never emit an empty changelog entry.
- **Commit type extraction.** Read from `generate_commit_message`
  output in `lib/hooks.sh` — that function already classifies the
  commit type. Don't re-infer. If the hook doesn't expose the type,
  add a side-channel (write to a temp file, or export a global var)
  rather than duplicating classification logic.
- **docs/chore/test commit types skip entirely.** No changelog entry for
  docs-only, chore, or test-only runs. The changelog is for user-facing
  changes only.
- **Markdown injection risk.** `CODER_SUMMARY.md` is written by the
  LLM. Don't blindly pipe its content into the changelog — strip any
  leading `##` headers from extracted bullets to avoid nesting-level
  corruption.
- **`## [Unreleased]` accumulation.** Zero-diff runs don't write
  entries (per decision #6), but if a future milestone decides to
  accumulate bullets there between version bumps, the assembler should
  support that pattern. Out of scope for M77 — but keep the append
  function's insert point parameterized so it's easy to change.
- **File-length guardrail.** `lib/changelog.sh` ≤ 300 lines. Split
  helpers into `lib/changelog_helpers.sh` if needed.
- **Testing keep-a-changelog format precisely.** Format fixtures should
  match the official keep-a-changelog.com example verbatim so future
  regressions are easy to spot.

## Seeds Forward

- **Conventional Commits format.** A second value for `CHANGELOG_FORMAT`
  (`conventional-commits`) could emit a different style. Out of scope
  for M77.
- **Release notes generation.** At major/minor bumps, auto-generate a
  longer release notes file from the changelog entries. Out of scope.
- **GitHub Releases integration.** On bump, use mcp github tools to
  create a GitHub release with the changelog entry as the body. Out
  of scope — requires network and auth.
- **Historical backfill.** A `tekhton --backfill-changelog` command
  could read `MILESTONE_ARCHIVE.md` and reconstruct a changelog from
  past completed milestones. Useful for projects adopting this milestone
  mid-flight. Out of scope.
- **Per-project Changelog style.** Some projects prefer user-facing
  prose (Notion, Linear-style) vs. technical diff lists. A future
  milestone could add a `CHANGELOG_STYLE=user|technical|auto` toggle
  that adjusts how bullets are phrased.
