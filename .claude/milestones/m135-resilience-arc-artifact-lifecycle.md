# M135 - Resilience Arc Artifact Lifecycle Management

<!-- milestone-meta
id: "135"
status: "pending"
-->

## Overview

| Prior arc milestone | Artifact(s) created | Current cleanup |
|---------------------|---------------------|-----------------|
| m128 (Build-Fix Continuation Loop) | `.claude/BUILD_FIX_REPORT.md` | None |
| m129 (Failure Context Schema) | `.claude/LAST_FAILURE_CONTEXT.json` | None on success; file persists across runs |
| m131 (Preflight UI Config Audit) | `.claude/preflight_bak/<timestamp>_<file>` (one per auto-fix) | None |
| m53 (existing) | `${BUILD_RAW_ERRORS_FILE}` (`BUILD_RAW_ERRORS.txt`) | Overwritten per gate run but not removed on success |

Three concrete problems that fall through today:

1. **Stale failure context contaminates fresh success runs.** If a project
   had an interactive-reporter failure, `LAST_FAILURE_CONTEXT.json` on
   disk reflects that run. On the next run (which succeeds), `--diagnose`
   still reads the old file and reports "UI_GATE_INTERACTIVE_REPORTER"
   — a completely wrong diagnosis for a succeeding project.

2. **`preflight_bak/` grows without bound.** Every `tekhton --run` that
   applies the preflight auto-fix creates another timestamped backup.
   After 50 runs a project has 50 backup files nobody will ever read.
   Disk usage is small but the directory becomes visual noise and slows
   `find`/`ls` in the `.claude/` tree.

3. **`.gitignore` is incomplete for arc artifacts.** `_ensure_gitignore_entries`
   in `lib/common.sh` covers `.claude/LAST_FAILURE_CONTEXT.json` but
   not `.claude/BUILD_FIX_REPORT.md` or `.claude/preflight_bak/`. Both
   will appear in `git status` as untracked files after the first run
   that exercises the arc, surprising developers who use `git add -A`.

4. **`artifact_defaults.sh` does not declare the new arc artifact paths.**
   `BUILD_FIX_REPORT_FILE` and `PREFLIGHT_BAK_DIR` have no `:=` defaults,
   so they cannot be overridden in `pipeline.conf` the way all other
   Tekhton artifact paths can.

M135 fixes all four problems:
- Adds `.claude/BUILD_FIX_REPORT.md` and `.claude/preflight_bak/` to
  `_ensure_gitignore_entries`.
- Declares `BUILD_FIX_REPORT_FILE` and `PREFLIGHT_BAK_DIR` in
  `artifact_defaults.sh`.
- Adds `_clear_arc_artifacts_on_success` to `lib/finalize_summary.sh`,
  called when the run outcome is `"success"`.
- Adds `_trim_preflight_bak_dir` to `lib/preflight_checks.sh`, called
  at the end of every auto-fix. Keeps the `N` most-recent backups
  (default 5, overridable via `PREFLIGHT_BAK_RETAIN_COUNT`).

No changes to the recovery arc logic, RUN_SUMMARY schema, or test
framework. This is purely lifecycle hygiene.

## Design

### Goal 1 — Register new artifact path defaults in `artifact_defaults.sh`

Add two new `:=` lines to `lib/artifact_defaults.sh` after the existing
`.tekhton/` defaults block. Both use `.claude/` not `.tekhton/` because
they are operational metadata (not human-readable reports visible in the
project root).

```bash
# --- Resilience arc operational artifacts (m128, m131) ----------------------
: "${BUILD_FIX_REPORT_FILE:=${PROJECT_DIR:-.}/.claude/BUILD_FIX_REPORT.md}"
: "${PREFLIGHT_BAK_DIR:=${PROJECT_DIR:-.}/.claude/preflight_bak}"
```

**Why `.claude/` not `.tekhton/`:** `.tekhton/` holds files the human is
meant to read between runs (DESIGN.md, CODER_SUMMARY.md, etc.). These two
paths are transient operational state. They belong in `.claude/` alongside
`LAST_FAILURE_CONTEXT.json` and `PIPELINE_STATE.md`.

**Why `PROJECT_DIR:-.`:** `artifact_defaults.sh` may be sourced before
`PROJECT_DIR` is populated (e.g., in planning mode). The `:-.` fallback
keeps the assignment safe; callers that need the absolute path set
`PROJECT_DIR` before sourcing.

### Goal 2 — Add missing patterns to `_ensure_gitignore_entries`

In `lib/common.sh`, the `_gi_entries` array in `_ensure_gitignore_entries`
gains two new entries appended immediately after the existing `.claude/`
entries:

```bash
".claude/BUILD_FIX_REPORT.md"
".claude/preflight_bak/"
```

Exact placement (after `.claude/watchtower_inbox/` which is the last
existing `.claude/` entry):

```bash
local -a _gi_entries=(
    ".claude/PIPELINE.lock" ".claude/PIPELINE_STATE.md"
    ".claude/MILESTONE_STATE.md" ".claude/CHECKPOINT_META.json"
    ".claude/LAST_FAILURE_CONTEXT.json" ".claude/TEST_BASELINE.json"
    ".claude/TEST_BASELINE_OUTPUT.txt" ".claude/test_acceptance_output.tmp"
    ".claude/dashboard/data/" ".claude/logs/" ".claude/indexer-venv/"
    ".claude/index/" ".claude/serena/" ".claude/dry_run_cache/"
    ".claude/migration-backups/" ".claude/watchtower_inbox/"
    ".claude/tui_sidecar.pid" ".claude/worktrees/"
    ".claude/BUILD_FIX_REPORT.md"        # m128 build-fix continuation loop
    ".claude/preflight_bak/"             # m131 preflight auto-fix backups
)
```

The function is idempotent: the `grep -qF` guard at the top of the loop
means adding entries to `_gi_entries` is always safe on already-initialized
projects.

### Goal 3 — Success-path artifact cleanup in `lib/finalize_summary.sh`

Add `_clear_arc_artifacts_on_success` after the last existing helper
function in `lib/finalize_summary.sh`, before `_hook_emit_run_summary`.

```bash
# _clear_arc_artifacts_on_success
# Removes transient resilience-arc failure artifacts when a run completes
# successfully. Prevents stale failure context from contaminating --diagnose
# on the next run.
#
# Artifacts cleared (each rm is guarded — silently skipped if absent):
#   .claude/LAST_FAILURE_CONTEXT.json  — failure cause from m129
#   .claude/BUILD_FIX_REPORT.md        — build-fix loop summary from m128
#   ${BUILD_RAW_ERRORS_FILE}           — raw build errors (default .tekhton/BUILD_RAW_ERRORS.txt)
#
# NOT cleared on success:
#   .claude/preflight_bak/             — retained for audit trail; trimmed by
#                                        _trim_preflight_bak_dir separately
#   .claude/logs/RUN_SUMMARY.json      — always kept (success run is useful history)
#   .tekhton/DIAGNOSIS.md              — kept to show last successful run diagnosis
#
# Called only when outcome == "success" (exit_code 0) inside
# _hook_emit_run_summary.
_clear_arc_artifacts_on_success() {
    local _proj="${PROJECT_DIR:-.}"
    local _cleared=0

    local -a _targets=(
        "${_proj}/.claude/LAST_FAILURE_CONTEXT.json"
        "${_proj}/${BUILD_FIX_REPORT_FILE:-".claude/BUILD_FIX_REPORT.md"}"
        "${BUILD_RAW_ERRORS_FILE:-${_proj}/.tekhton/BUILD_RAW_ERRORS.txt}"
    )
    for _f in "${_targets[@]}"; do
        if [[ -f "$_f" ]]; then
            rm -f "$_f" 2>/dev/null && _cleared=$(( _cleared + 1 )) || true
        fi
    done

    (( _cleared > 0 )) && log_verbose \
        "[artifact lifecycle] Cleared ${_cleared} stale failure artifact(s) on success"
    return 0
}
```

**Integration point in `_hook_emit_run_summary`:**

`_hook_emit_run_summary` already receives `exit_code` as `$1`. The call
is at the top of the success branch, before the final `log` call:

```bash
_hook_emit_run_summary() {
    local exit_code="$1"
    ...
    if [[ "$exit_code" -eq 0 ]]; then
        _clear_arc_artifacts_on_success    # <— new call (m135)
        local outcome="success"
    else
        local outcome="failure"
    fi
    ...
}
```

**Why only on success:** On failure, `LAST_FAILURE_CONTEXT.json` is
precious — it is the primary input to `--diagnose`. Clearing it on failure
would break `--diagnose` for the most important case.

**Why `log_verbose` not `log`:** Success-path cleanup is invisible
maintenance. It should not appear on the terminal during normal runs.
Users can see it with `VERBOSE_OUTPUT=true`.

### Goal 4 — Preflight backup retention cap in `lib/preflight_checks.sh`

Add `_trim_preflight_bak_dir` to `lib/preflight_checks.sh`, called at
the end of `_pf_uitest_playwright_fix_reporter` (the m131 auto-fix
function) immediately after the `PREFLIGHT_UI_REPORTER_PATCHED=1` export.

```bash
# _trim_preflight_bak_dir  BAK_DIR  [RETAIN_COUNT]
# Removes oldest timestamped backups from BAK_DIR keeping only the RETAIN_COUNT
# most recent files. Silently skips if BAK_DIR does not exist.
#
# Backup files written by _pf_uitest_playwright_fix_reporter have the form:
#   <YYYYMMDD_HHMMSS>_<original-filename>
# e.g.: 20260425_182710_playwright.config.ts
#
# Files are sorted lexicographically — YYYYMMDD_HHMMSS prefix ensures
# chronological sort == lexicographic sort. No date parsing needed.
#
# Args:
#   $1 = bak_dir  — directory containing backup files
#   $2 = retain   — number of most-recent files to keep (default: PREFLIGHT_BAK_RETAIN_COUNT or 5)
_trim_preflight_bak_dir() {
    local bak_dir="$1"
    local retain="${2:-${PREFLIGHT_BAK_RETAIN_COUNT:-5}}"

    [[ -d "$bak_dir" ]] || return 0

    # Count all backup files (any file directly in bak_dir — no subdirs expected)
    local total
    total=$(find "$bak_dir" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')

    (( total <= retain )) && return 0

    # Sort ascending (oldest first), delete all but the $retain newest
    local to_delete=$(( total - retain ))
    find "$bak_dir" -maxdepth 1 -type f \
        | sort \
        | head -n "$to_delete" \
        | xargs rm -f 2>/dev/null || true

    log_verbose "[artifact lifecycle] Trimmed preflight_bak: removed ${to_delete} old backup(s), kept ${retain}"
    return 0
}
```

**Calling convention in `_pf_uitest_playwright_fix_reporter`:**

```bash
_pf_uitest_playwright_fix_reporter() {
    ...
    export PREFLIGHT_UI_REPORTER_PATCHED=1
    _trim_preflight_bak_dir "${PREFLIGHT_BAK_DIR:-${PROJECT_DIR:-.}/.claude/preflight_bak}"  # m135
}
```

**Why `find | sort | head | xargs`:** no `jq`, no `python`, no `awk`
date arithmetic. The YYYYMMDD_HHMMSS prefix makes plain lexicographic
sort chronological — same zero-dependency philosophy as the rest of the
codebase.

**Why default retain=5:** Five backups covering five auto-fix events is
a generous audit trail. In a project that auto-patches on every run
(unlikely — the patch is idempotent after first application), five runs
means one week of daily runs.

**`PREFLIGHT_BAK_RETAIN_COUNT` in `pipeline.conf`:** Because
`PREFLIGHT_BAK_RETAIN_COUNT` is read with `${PREFLIGHT_BAK_RETAIN_COUNT:-5}`,
it can be set in `pipeline.conf` without any additional registration.
Set to `0` to disable retention (keep all backups). Set to `1` to keep
only the most recent.

### Goal 5 — Validate with `_ensure_gitignore_entries` audit test

Extend `tests/test_validate_config.sh` (or the test file that exercises
`_ensure_gitignore_entries`) with two assertions:

```
T1: After calling _ensure_gitignore_entries on a fresh .gitignore,
    the file contains ".claude/BUILD_FIX_REPORT.md"

T2: After calling _ensure_gitignore_entries on a fresh .gitignore,
    the file contains ".claude/preflight_bak/"
```

These are one-liners using the existing `pass`/`fail` harness pattern:

```bash
echo "Test: BUILD_FIX_REPORT.md in gitignore"
_ensure_gitignore_entries "$TMPDIR" 2>/dev/null
if grep -qF ".claude/BUILD_FIX_REPORT.md" "${TMPDIR}/.gitignore"; then
    pass "BUILD_FIX_REPORT.md added to .gitignore"
else
    fail "BUILD_FIX_REPORT.md missing from .gitignore"
fi

echo "Test: preflight_bak/ in gitignore"
if grep -qF ".claude/preflight_bak/" "${TMPDIR}/.gitignore"; then
    pass "preflight_bak/ added to .gitignore"
else
    fail "preflight_bak/ missing from .gitignore"
fi
```

Also add to `tests/test_resilience_arc_integration.sh` (m134):

```
T3: Success run → LAST_FAILURE_CONTEXT.json removed
T4: Success run → BUILD_FIX_REPORT.md removed
T5: Failure run → LAST_FAILURE_CONTEXT.json retained
T6: preflight_bak/ with 7 files and retain=5 → 2 oldest removed
T7: preflight_bak/ with 3 files and retain=5 → no files removed
T8: PREFLIGHT_BAK_RETAIN_COUNT=0 → no files removed (keep all)
```

Test T3–T5 plug into the existing `_hook_emit_run_summary` mock in
`test_resilience_arc_integration.sh`. T6–T8 call `_trim_preflight_bak_dir`
directly with fixture directories.

## Files Modified

| File | Change |
|------|--------|
| `lib/artifact_defaults.sh` | Add `BUILD_FIX_REPORT_FILE` and `PREFLIGHT_BAK_DIR` `:=` defaults. |
| `lib/common.sh` | Add `.claude/BUILD_FIX_REPORT.md` and `.claude/preflight_bak/` to `_gi_entries` array in `_ensure_gitignore_entries`. |
| `lib/finalize_summary.sh` | Add `_clear_arc_artifacts_on_success` function; call it from `_hook_emit_run_summary` on success branch. |
| `lib/preflight_checks.sh` | Add `_trim_preflight_bak_dir` function; call it from `_pf_uitest_playwright_fix_reporter` after setting `PREFLIGHT_UI_REPORTER_PATCHED=1`. |
| `tests/test_validate_config.sh` (or the file that tests `_ensure_gitignore_entries`) | Add T1–T2 for new gitignore entries. |
| `tests/test_resilience_arc_integration.sh` | Add T3–T8 for success-path cleanup and preflight_bak trimming. |

## Acceptance Criteria

- [ ] `artifact_defaults.sh` declares `BUILD_FIX_REPORT_FILE` and `PREFLIGHT_BAK_DIR` with `:=` and `.claude/` paths.
- [ ] `_ensure_gitignore_entries` adds `.claude/BUILD_FIX_REPORT.md` and `.claude/preflight_bak/` to a fresh `.gitignore`.
- [ ] `_ensure_gitignore_entries` remains idempotent: calling it twice does not add duplicate lines.
- [ ] On a successful run completion, `LAST_FAILURE_CONTEXT.json` is removed if present.
- [ ] On a successful run completion, `BUILD_FIX_REPORT.md` is removed if present.
- [ ] On a failure run, `LAST_FAILURE_CONTEXT.json` is NOT removed.
- [ ] `_clear_arc_artifacts_on_success` is a no-op (no error) when none of the target files exist.
- [ ] `_trim_preflight_bak_dir` with 7 backups and retain=5 removes exactly the 2 lexicographically-oldest files.
- [ ] `_trim_preflight_bak_dir` with 3 backups and retain=5 removes nothing.
- [ ] `PREFLIGHT_BAK_RETAIN_COUNT=0` disables trimming (all backups kept).
- [ ] `_trim_preflight_bak_dir` is a no-op when the directory does not exist (no error).
- [ ] `log_verbose` (not `log`) used for all cleanup messages — no terminal noise on normal runs.
- [ ] Tests T1–T8 pass.
- [ ] `shellcheck` clean for all modified files.
