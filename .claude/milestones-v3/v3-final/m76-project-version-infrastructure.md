
# Milestone 76: Target-Project Version File Management
<!-- milestone-meta
id: "76"
status: "done"
-->
<!-- PM-tweaked: 2026-04-12 -->

## Overview

Tekhton has no concept of the **target project's** version. Grepping `lib/`,
`stages/`, and `prompts/` returns zero matches for `PROJECT_VERSION` outside
of Tekhton's own `TEKHTON_VERSION` / `TEKHTON_CONFIG_VERSION` constants.
Every target project built with Tekhton goes through milestone after
milestone with no version bump, no CHANGELOG, no release tags.

Developer feedback: "Every time Tekhton does work on a project the version
should bump by either major, minor or patch, and the question of how to
version the project should be in the --plan questions, defaulting to semver
if unclear."

This milestone is **Part 1 of 2** on versioning. M76 ships the
**infrastructure** — detection, parsing, bumping, plan-interview question.
M77 ships **CHANGELOG** generation on top of it.

Keeping M76 purely about version-file management lets it land as a
reviewable diff without being coupled to changelog concerns. If M76 ships
alone, a project still benefits (version files get bumped); M77 is additive
polish.

## Design Decisions

### 1. Autodetect version files on first run, cache the list

New library: `lib/project_version.sh`. On the first pipeline run after M76
lands (or after `--init`), it scans the project root for known version
files and writes the list to `.claude/project_version.cfg`:

```
VERSION_STRATEGY=semver
VERSION_FILES=package.json:.version;pyproject.toml:.project.version;VERSION:.
CURRENT_VERSION=0.1.0
```

Supported ecosystems (ordered by detection priority):

| File | How to parse | How to bump |
|------|-------------|-------------|
| `package.json` | JSON `.version` | `jq -r` read, `jq` write (or python) |
| `pyproject.toml` | regex `^version\s*=\s*"X.Y.Z"` under `[project]` or `[tool.poetry]` | sed replace |
| `Cargo.toml` | regex `^version\s*=\s*"X.Y.Z"` under `[package]` | sed replace |
| `setup.py` / `setup.cfg` | regex `version\s*=\s*['"]X.Y.Z['"]` | sed replace |
| `gradle.properties` | regex `^version\s*=\s*X.Y.Z` | sed replace |
| `Chart.yaml` (Helm) | regex `^version:\s*X.Y.Z` | sed replace |
| `composer.json` | JSON `.version` | jq/python |
| `pubspec.yaml` (Flutter/Dart) | regex `^version:\s*X.Y.Z` | sed replace |
| `VERSION` (plain text) | whole file | echo replace |

If none are found, create `VERSION` at the project root as the source of
truth (plain text `0.1.0`). This gives every project *some* version surface.

### 2. Plan interview adds a single required question

Edit `prompts/plan_interview.prompt.md` (Phase 2). Add:

> **Versioning strategy.** How should this project be versioned?
> 1) Semantic versioning (major.minor.patch) — default
> 2) CalVer (YYYY.MM.patch)
> 3) Date-stamped (YYYY-MM-DD)
> 4) None / manual (Tekhton won't bump)

If the user says nothing or says "unclear," default to semver. Write the
answer into DESIGN.md's existing/new "Versioning & Release Strategy"
section. The library.md template already has this section — extend the
other six templates to include it too (as `<!-- REQUIRED -->`).

### 3. Bump rules — simple by default, overridable

At finalize time, `lib/project_version.sh` computes the next version from
the current version plus a disposition hint:

- **patch** — default. Bug fix milestones, non-blocker sweeps, drift
  resolution, any milestone not matching the rules below.
- **minor** — milestone title contains the word "feature" (case-insensitive),
  OR the milestone type in the manifest is explicitly marked a feature group,
  OR the coder summary contains `## New Public Surface` (added by M74).
- **major** — only when the coder summary contains a `## Breaking Changes`
  subsection. Never automatic on title match — major bumps must be
  explicit.

For CalVer, "patch" increments the patch digit of the current YYYY.MM; a
new month triggers a new YYYY.MM.0. For date-stamped, each run bumps to
today's date. For `none`, the stage is a no-op.

### 4. Idempotent on a no-op run

If the pipeline run didn't actually change code (e.g., an advice-only
run, or milestone acceptance without a commit), the version bump is
skipped. The gate: check whether `_do_git_commit` was called with a
non-empty diff. If not, don't touch the version file.

### 5. Don't touch the file if the user already bumped it

Before bumping, read the current version from the file. If it doesn't
match the `CURRENT_VERSION` cached in `.claude/project_version.cfg`, the
user bumped it manually. Log a warning ("user bumped X.Y.Z → A.B.C,
updating cache") and update the cache — don't overwrite the user's bump.

### 6. New finalize hook

`lib/finalize.sh` already has a `register_finalize_hook` registry. Add a
new hook `_finalize_project_version_bump` that reads the disposition
hints and invokes `lib/project_version.sh`'s bump function. Registration
happens during config load so the hook participates in the normal
sequence without special-casing.

### 7. Ecosystem-specific bumping uses `python3` where possible

`python3` is already a hard dependency of Tekhton (per the research on
distribution) — we use it for JSON parsing in several lib files. Prefer
`python3 -c` for JSON/TOML parsing over inventing regex-based parsers.
For plain-text (Cargo.toml regex, Chart.yaml regex), `sed -i.bak` is
fine — restore or remove the `.bak` after the edit.

### 8. Config surface (six new vars)

```bash
: "${PROJECT_VERSION_ENABLED:=true}"
: "${PROJECT_VERSION_STRATEGY:=semver}"      # semver | calver | datestamp | none
: "${PROJECT_VERSION_CONFIG:=.claude/project_version.cfg}"
: "${PROJECT_VERSION_DEFAULT_BUMP:=patch}"   # fallback when no rule matches
: "${PROJECT_VERSION_TAG_ON_BUMP:=false}"    # git tag vX.Y.Z on bump
: "${PROJECT_VERSION_AUTO_DETECT:=true}"     # run detection on first pipeline run
```

Expose all six as template variables in `lib/prompts.sh`.

## Migration Impact

<!-- [PM: Added — rubric requires a Migration Impact section when new user-facing config, files, or auto-enabled behaviors are introduced.] -->

This milestone is **opt-out by default** on all existing target projects:

- `PROJECT_VERSION_ENABLED` defaults to `true`. On the first pipeline run
  after M76 is installed, `detect_project_version_files` will scan the
  project root and create `.claude/project_version.cfg`. Projects that do
  not want auto-versioning must set `PROJECT_VERSION_ENABLED=false` in
  `pipeline.conf`.
- `.claude/project_version.cfg` is a new runtime-state file. It is not
  committed to the target project's repo by default. Add it to `.gitignore`
  in `--init` if desired, or document that it is ephemeral. **Decision
  required**: should `--init` add `.claude/project_version.cfg` to the
  project's `.gitignore`? Current scope leaves this unspecified — either
  document that users must add it manually or add it in `lib/init.sh`.
  Defaulting to: do nothing (`.claude/` is typically already gitignored in
  Tekhton-managed projects).
- The finalize hook runs on every pipeline execution once `M76` lands.
  Projects mid-milestone that receive a `patch` bump on every run may see
  unexpected version churn until M77 lands with CHANGELOG context.
  Mitigation: the no-op gate (Design Decision #4) prevents bumps on
  advice-only / no-commit runs.

No schema migrations are required for `pipeline.conf` — all six new vars
have backward-compatible defaults.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| New lib files | 2 | `lib/project_version.sh`, `lib/project_version_bump.sh` (split to stay under 300 lines) |
| New config variables | 6 | Listed in Design Decision #8 |
| New template variables | 6 | Mirrored |
| Plan templates updated | 6 | Add `## Versioning & Release Strategy` REQUIRED to cli-tool, web-app, api-service, mobile-app, web-game, custom |
| Plan interview questions | 1 | New strategy question in Phase 2 |
| Tests added | 3 | Parse per-ecosystem, bump rule selection, idempotency on no-op |
| Files modified (pipeline) | 3 | `lib/finalize.sh` (register hook), `lib/config_defaults.sh`, `lib/prompts.sh` |

## Implementation Plan (staged so each step is independently testable)

### Step 1 — Config + template variable scaffolding

Edit `lib/config_defaults.sh` — add six vars from Design Decision #8.
Edit `lib/prompts.sh` — register the vars.
No behavior change. Run `bash tests/run_tests.sh` — must pass unchanged.

### Step 2 — Detection library (read-only)

Create `lib/project_version.sh` with two functions:

```bash
# detect_project_version_files  
#   Scans $PROJECT_DIR for known version files. Writes the list +
#   current version to $PROJECT_VERSION_CONFIG. Idempotent.
# parse_current_version
#   Reads $PROJECT_VERSION_CONFIG and emits the current version string.
```

This step is read-only — no file mutations anywhere. Add
`tests/test_project_version_detect.sh` that fixture-tests each ecosystem:
drop a fake `package.json` / `Cargo.toml` / etc. in a temp dir, assert
the cache comes out correct.

### Step 3 — Bump library (write path)

Create `lib/project_version_bump.sh` with:

```bash
# compute_next_version CURRENT STRATEGY BUMP_TYPE
# bump_version_files BUMP_TYPE
```

`compute_next_version` is pure (input → output, no I/O) — trivial to
unit-test. `bump_version_files` does the actual file writes, guarded by
the "user-bumped-it-manually" check from Design Decision #5.

Add `tests/test_project_version_bump.sh` covering:
- semver patch bump (1.2.3 → 1.2.4)
- semver minor bump (1.2.3 → 1.3.0)
- semver major bump (1.2.3 → 2.0.0)
- calver month transition (2026.04.3 at date 2026-05-01 → 2026.05.0)
- strategy=none → no-op
- user pre-bumped detection

### Step 4 — Disposition hint extraction

Add `get_version_bump_hint` to `lib/project_version_bump.sh`. Reads
`CODER_SUMMARY.md` looking for:
- `## Breaking Changes` subsection → `major`
- `## New Public Surface` subsection → `minor`
- Otherwise → `$PROJECT_VERSION_DEFAULT_BUMP` (defaults to `patch`)

Small function, no I/O except reading the summary file. Unit test with
fixture summaries.

### Step 5 — Finalize hook registration

Add `_finalize_project_version_bump` function to `lib/finalize.sh` (or a
new `lib/finalize_version.sh` to keep file length under control). Calls
`bump_version_files "$(get_version_bump_hint)"`. Guarded by
`PROJECT_VERSION_ENABLED=true`.

Register the hook in `tekhton.sh`'s init sequence alongside other
`register_finalize_hook` calls. Position: after milestone archival,
before commit — so the version bump is part of the commit.

### Step 6 — Plan templates + interview

Add `## Versioning & Release Strategy` REQUIRED section to the six
templates that don't have it (library.md already has it — just add the
REQUIRED marker).

Edit `prompts/plan_interview.prompt.md` and
`prompts/plan_interview_followup.prompt.md` — add the single versioning
question in Phase 2. Write the answer into DESIGN.md's new section.

### Step 7 — Git tag on bump (optional)

If `PROJECT_VERSION_TAG_ON_BUMP=true`, after a successful bump + commit,
create a lightweight git tag `vX.Y.Z`. Follow the existing
`MILESTONE_TAG_ON_COMPLETE` pattern in `lib/milestone_ops.sh:82-98` for
consistency. Do NOT tag on no-op runs (no commit = no tag).

### Step 8 — Shellcheck + tests + version bump

```bash
shellcheck lib/project_version.sh lib/project_version_bump.sh lib/finalize*.sh
bash tests/run_tests.sh
```

Edit `tekhton.sh` — `TEKHTON_VERSION="3.76.0"`.
Edit manifest — add M76 row with `depends_on=m72`, group `runtime`.

## Files Touched

### Added
- `lib/project_version.sh` — detection + config cache
- `lib/project_version_bump.sh` — pure bump logic + file writes
- `tests/test_project_version_detect.sh`
- `tests/test_project_version_bump.sh`
- `tests/test_project_version_hint.sh`
- `.claude/milestones/m76-project-version-infrastructure.md` — this file

### Modified
- `lib/config_defaults.sh` — six new PROJECT_VERSION_* vars
- `lib/prompts.sh` — register template vars
- `lib/finalize.sh` (or new `lib/finalize_version.sh`) — register hook
- `tekhton.sh` — source new libs, register finalize hook, bump version
- `templates/plans/cli-tool.md` — add REQUIRED versioning section
- `templates/plans/web-app.md` — ditto
- `templates/plans/api-service.md` — ditto
- `templates/plans/mobile-app.md` — ditto
- `templates/plans/web-game.md` — ditto
- `templates/plans/custom.md` — ditto
- `templates/plans/library.md` — add REQUIRED marker only
- `prompts/plan_interview.prompt.md` — new versioning question
- `prompts/plan_interview_followup.prompt.md` — followup variant
- `tests/run_tests.sh` — register new tests
- `.claude/milestones/MANIFEST.cfg` — M76 row

## Acceptance Criteria

- [ ] `lib/project_version.sh` defines `detect_project_version_files` and
      `parse_current_version`
- [ ] `lib/project_version_bump.sh` defines `compute_next_version`,
      `bump_version_files`, `get_version_bump_hint`
- [ ] Both lib files pass `shellcheck` with zero warnings
- [ ] Both lib files are ≤ 300 lines (hygiene rule from M71)
- [ ] Config has six `PROJECT_VERSION_*` variables with correct defaults
- [ ] `PROJECT_VERSION_STRATEGY` defaults to `semver`
- [ ] Detection handles: package.json, pyproject.toml, Cargo.toml, setup.py,
      setup.cfg, gradle.properties, Chart.yaml, composer.json, pubspec.yaml,
      plain VERSION
- [ ] Detection creates `VERSION` at project root if no known file exists
- [ ] Bump rules: `## Breaking Changes` → major, `## New Public Surface`
      → minor, otherwise → `$PROJECT_VERSION_DEFAULT_BUMP`
- [ ] User pre-bump detection: if file version ≠ cached version, log warning
      and update cache without overwriting
- [ ] Strategy=none → bump is a no-op
- [ ] No-op pipeline runs (no commit) do not bump the version
- [ ] Plan templates (7/7) include a REQUIRED versioning section
- [ ] Plan interview asks the versioning question, defaults to semver
- [ ] `_finalize_project_version_bump` hook registered in finalize sequence
- [ ] `tests/test_project_version_detect.sh` passes all ecosystem fixtures
- [ ] `tests/test_project_version_bump.sh` passes semver/calver/datestamp
      bump tests and user-pre-bump test
- [ ] `tests/test_project_version_hint.sh` passes breaking/minor/patch cases
- [ ] `bash tests/run_tests.sh` passes with zero failures
- [ ] `tekhton.sh` `TEKHTON_VERSION` is `3.76.0`
- [ ] `.claude/milestones/MANIFEST.cfg` contains the M76 row
      (`depends_on=m72`, group `runtime`)

## Watch For

- **Do not confuse `TEKHTON_VERSION` with `PROJECT_VERSION` in new code.**
  `TEKHTON_VERSION` is bumped to `3.76.0` in Step 8 as the standard
  milestone completion action. `PROJECT_VERSION` is the *target project's*
  version managed by the new libraries. Keep them clearly separated in
  variable names, log messages, and comments — never use one where the
  other is meant. <!-- [PM: Reworded to clarify that TEKHTON_VERSION IS bumped in Step 8; the prohibition is against confusing the two in new library code, not against the standard milestone bump.] -->
- **Bash regex is brittle for TOML.** Cargo.toml's `[package]` block can
  be separated from its `version` line by arbitrary whitespace and
  comments. Use `python3 -c 'import tomllib; …'` on Python 3.11+, or a
  forgiving regex that matches `version\s*=\s*"([^"]+)"` within the
  first 20 lines of the file. Don't try to write a full TOML parser.
- **pubspec.yaml is YAML, not TOML.** The regex for YAML `version: X.Y.Z`
  needs `^version:` (no `=`). Easy to miss.
- **`jq` availability.** Some platforms don't have `jq`. Prefer
  `python3 -c 'import json; …'` for JSON parsing — Python is already
  required.
- **Idempotency is non-negotiable.** Running a pipeline twice in a row
  on a no-op change must not produce two bumps. The commit-happened gate
  is the correct check — not timestamp comparison, not cache mtime.
- **Git tag collisions.** If the computed next version already has a git
  tag (maybe the user pre-tagged), log a warning and skip the tag — do
  NOT force-overwrite. Tags are append-only from Tekhton's perspective.
- **File-length guardrail.** `lib/project_version*.sh` must stay under
  300 lines each. Split bump logic into `_bump.sh` if needed (already
  planned). Check `wc -l` before committing.
- **Plan template edits are consistent.** All six non-library templates
  get the same section header, same phase tag, same REQUIRED marker.
  Write the block once, paste into all six — don't rewrite per template.
- **Config cache placement.** `.claude/project_version.cfg` lives under
  `.claude/`, not `.tekhton/` (M72), because it's runtime state not an
  artifact. Consistent with `pipeline.conf` placement.
- **M77 builds on this.** Keep the public APIs of both libraries
  stable — M77's CHANGELOG hook will call `parse_current_version`
  (from `lib/project_version.sh`) and `get_version_bump_hint` (from
  `lib/project_version_bump.sh`). Don't make either function private.

## Seeds Forward

- **M77 — CHANGELOG.md generation.** Depends on this milestone. Reads
  the version bump and CODER_SUMMARY entries to append a keep-a-changelog
  style entry per milestone.
- **Release PR automation.** A future devx milestone could open a GitHub
  PR at each major/minor bump using the existing MCP github tools. Out
  of scope here.
- **Pre-release suffixes.** `1.2.3-rc.1`, `1.2.3-beta.2` — future polish.
  Current scope is stable releases only.
- **Monorepo support.** If a project has multiple version files that
  need independent bumping (workspaces), the cache structure supports it
  via multiple entries, but the bump logic currently assumes one
  canonical version. Flag for a future milestone if monorepo users ask.
- **Version display in Watchtower.** Now that projects have a version,
  Watchtower's project tile could show it. Trivial add post-M77.
