<!-- milestone-meta
id: "05"
status: "todo"
-->

# m05 (V5) — Sentinel Hygiene: All `.tekhton/.*` Sentinels Gitignored + Regression Guard

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | The V5 m01-m03 auto-advance run revealed that `.tekhton/.finalize_active` (introduced in m50) was silently getting tracked by git. Three commits in the chain (4d35e63, 199fa5f, 038a624) included the sentinel as a modified file. The retroactive fix in commit 76c111a added it to `.gitignore` + `git rm --cached`. m05 closes the broader gap: audit every `.tekhton/.*` sentinel file across the m41-m50 reliability arc, confirm each is gitignored, and add a regression test that fails CI if any new sentinel file ships untracked. |
| **Gap** | `.gitignore` today lists `.tekhton/.final_check_result` and `.tekhton/.commit_decision` (both from m41 era). m50 added `.tekhton/.finalize_active` but didn't update `.gitignore`. m46 added `.tekhton/.final_check_reason` — also not in `.gitignore` until 76c111a's retroactive sweep. The pattern: every new sentinel introduced by a reliability fix risks leaking into commits because no contract enforces the gitignore-on-introduction rule. A sentinel that survives a commit defeats its own purpose — it's supposed to be transient, but tracking makes it persistent. m50's manifest write guard reads `.tekhton/.finalize_active` to decide if a MANIFEST.cfg write is legitimate. If the sentinel is tracked and stuck at "set" state from a prior commit, the guard's logic inverts: legitimate finalize writes get blocked, rogue writes get allowed. |
| **m05 fills** | (1) Audit `.gitignore` for every sentinel filename pattern under `.tekhton/`. Currently confirmed: `.final_check_result`, `.final_check_reason`, `.commit_decision`, `.finalize_active`. Add any missing ones. (2) Add a regression test (`tests/test_no_tracked_sentinels.sh`) that scans the repo for tracked files matching `.tekhton/\.*` and fails if any exist. (3) Audit the bash + Go side for any other sentinel-shaped file the m41-m50 arc may have introduced — search for `.tekhton/\.` patterns in source. (4) Documentation update in `docs/v4-phase5-stub.md` or a new `docs/sentinel-hygiene.md` noting the convention that all `.tekhton/.*` files are transient and must be gitignored. |
| **Depends on** | none (independent reliability fix) |
| **Files changed** | `.gitignore`, `tests/test_no_tracked_sentinels.sh` (new), possibly `docs/sentinel-hygiene.md` (new), `VERSION` |

---

## Design

### Goal 1 — Audit + close gitignore gaps

**File:** `.gitignore`.

Walk every known sentinel and ensure each has an entry. Current state
after the 76c111a retroactive fix:

```
.tekhton/.final_check_result      ✓
.tekhton/.final_check_reason      ✓ (per 76c111a)
.tekhton/.commit_decision         ✓
.tekhton/.finalize_active         ✓ (per 76c111a)
```

If the audit surfaces additional sentinels under `.tekhton/.*`, add them.

Tighten with a glob pattern in `.gitignore`:

```
# Sentinel files under .tekhton/ are transient. Tracking any of them
# inverts the safety contract they exist to enforce. See
# docs/sentinel-hygiene.md for the rule.
.tekhton/.*
```

The glob covers any future sentinel automatically. Cost: an operator
who legitimately wants to track a specific file starting with `.` under
`.tekhton/` would need an explicit `!` exception. That's an acceptable
constraint — there's no such file today.

### Goal 2 — Regression test

**File:** `tests/test_no_tracked_sentinels.sh` (new, ~60 lines).

```bash
#!/usr/bin/env bash
# tests/test_no_tracked_sentinels.sh — m05 regression guard.
#
# Fails if any file under .tekhton/.* is tracked by git. All such
# files are intended to be transient sentinels; tracking any of
# them inverts their safety contracts (m50's manifest write guard
# is the canonical example — see docs/sentinel-hygiene.md).

set -euo pipefail

tracked=$(git ls-files '.tekhton/.[!.]*' 2>/dev/null || true)
if [[ -n "$tracked" ]]; then
    printf 'FAIL: the following sentinel files are tracked in git:\n' >&2
    printf '  %s\n' $tracked >&2
    printf '\n' >&2
    printf 'All .tekhton/.* files are transient sentinels per m05.\n' >&2
    printf 'See docs/sentinel-hygiene.md for the convention.\n' >&2
    printf 'Fix: add the file pattern to .gitignore and\n' >&2
    printf '  git rm --cached <file>\n' >&2
    exit 1
fi

printf 'PASS: no tracked sentinel files under .tekhton/.*\n'
```

Add a tests/run_tests.sh dispatch entry so the test runs in the suite.

### Goal 3 — Documentation

**File:** `docs/sentinel-hygiene.md` (new, ~60 lines).

Documents:
- The convention: every `.tekhton/.*` file is transient.
- Why tracking inverts safety: m50's manifest guard reads the sentinel
  to decide if a write is legitimate. If the sentinel is tracked-and-set
  from a prior commit, the guard blocks legitimate writes and allows
  rogue ones.
- The introduction protocol: any new sentinel MUST land with a
  `.gitignore` update in the same commit.
- The `.tekhton/.*` glob captures everything; resist exceptions.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `.gitignore` | Modify | Add `.tekhton/.*` glob (or confirm individual entries cover everything). |
| `tests/test_no_tracked_sentinels.sh` | Create | Regression guard. |
| `docs/sentinel-hygiene.md` | Create | Convention doc. |
| `VERSION` | Modify | Bump on close. |

---

## Acceptance Criteria

- [ ] `.gitignore` contains a `.tekhton/.*` glob OR explicit entries for every sentinel filename observed today. Verified by reading `.gitignore`.
- [ ] `git ls-files '.tekhton/.*'` returns empty. Verified by running the command.
- [ ] `tests/test_no_tracked_sentinels.sh` passes when no sentinels are tracked. Verified by running the test.
- [ ] `tests/test_no_tracked_sentinels.sh` fails when a sentinel is artificially tracked. Verified by `git add -f .tekhton/.test_sentinel && tests/test_no_tracked_sentinels.sh` exiting non-zero (then unstage).
- [ ] `docs/sentinel-hygiene.md` exists and documents the convention. Verified by `grep -nE '^## ' docs/sentinel-hygiene.md` returning at least 3 section headings.
- [ ] `tests/run_tests.sh` dispatch includes the new test. Verified by the suite running it.
- [ ] No regression in: existing tests, internal/finalize/..., cmd/tekhton/...
- [ ] `shellcheck tests/test_no_tracked_sentinels.sh` clean.
- [ ] Full suite passes.

## Watch For

- **The `.tekhton/.*` glob is intentionally broad.** Resist adding
  `!` exceptions unless a concrete operator need surfaces. Every
  exception adds tracked-state risk to the next sentinel that
  pattern-matches the exception.
- **Don't track `.tekhton/.*` regression-fixture files in test data.**
  If a test needs to inject a sentinel file, use `t.TempDir()` (Go) or
  a throwaway repo (bash). Never commit fixture sentinels into the
  project's `.tekhton/`.
- **The retroactive cleanup in 76c111a fixed `.finalize_active`.**
  If there are OTHER tracked sentinels lurking (this audit's job to
  find), each needs `git rm --cached` in the m05 implementation
  commit alongside the .gitignore update.

## Seeds Forward

- **Generalize the convention to other ephemeral directories.** Today
  `.tekhton/.*` is the rule. A future arc could extend to
  `.claude/index/` (tree-sitter cache), `.claude/serena/` (MCP runtime),
  etc. — any directory whose contents are runtime-generated.
- **CI gate for new sentinel introduction.** A pre-commit hook (or CI
  job) could grep new files in PRs for paths matching `.tekhton/.*`
  and fail if `.gitignore` doesn't have a matching entry. Catches the
  m50-shape miss at PR time rather than at next-run time.
