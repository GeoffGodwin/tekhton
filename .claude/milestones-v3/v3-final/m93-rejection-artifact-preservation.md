# Milestone 93: Rejection Artifact Preservation & Smart Resume Routing
<!-- milestone-meta
id: "93"
status: "done"
-->

## Overview

When a pipeline run exits due to repeated agent failures, it leaves users with
no good `--start-at` option. The root cause has two parts:

1. **Archive-on-start destroys the resume path.** When `--start-at coder` is
   used to retry, startup archives `REVIEWER_REPORT.md`. Now `--start-at test`
   is impossible even if the reviewer successfully ran in a prior attempt.

2. **PIPELINE_STATE.md always suggests `--start-at coder`.** Even when the
   reviewer ran and approved, the coder rework loop exhausted its budget. The
   right resume point is `--start-at test`, not another round at coder.

This milestone fixes both:

- Track which stage artifacts were archived at startup. When the run fails and
  the last failing stage was the one that could have used them, restore the
  archived artifact so the *next* run can use it.
- Update `write_pipeline_state` to suggest the smartest available `--start-at`
  based on which artifacts exist or were just restored.
- Apply the same pattern to TESTER_REPORT.md when tester failures are the
  terminal exit condition.

## Design Decisions

### 1. Track archived artifact paths at startup

During the `START_AT=coder` archive loop in `tekhton.sh`, record the destination
path for each archived report in exported variables:
```bash
_ARCHIVED_REVIEWER_REPORT_PATH=""
_ARCHIVED_TESTER_REPORT_PATH=""
```

These are unset by default; set only when the corresponding file is archived.

### 2. Restore policy in _save_orchestration_state

When `_save_orchestration_state` is called with exit reason `max_attempts` (or
similar loop-exhausted outcomes) and the final failing stage is `coder`:

- If `_ARCHIVED_REVIEWER_REPORT_PATH` is set and the file exists, copy it back
  to `$REVIEWER_REPORT_FILE`.
- Set Resume Command to `--start-at test`.
- Log: `[orchestrate] Restored archived REVIEWER_REPORT.md — resume with --start-at test.`

When the final failing stage is `tester`:

- If `_ARCHIVED_TESTER_REPORT_PATH` is set and the file exists, copy it back.
- Set Resume Command to `--start-at tester`.

### 3. If the artifact was already absent, don't block

If `_ARCHIVED_REVIEWER_REPORT_PATH` is not set (meaning no reviewer report
existed at all at startup), fall back to the current behavior: suggest
`--start-at coder`.

### 4. In-run REVIEWER_REPORT is already preserved

When the reviewer runs and writes a new `REVIEWER_REPORT.md` during the current
run, that file exists at `$REVIEWER_REPORT_FILE` when `_save_orchestration_state`
fires. Scenario A (reviewer ran in this run, coder rework failed): REVIEWER_REPORT
already exists — just point Resume Command at `--start-at test`.

This milestone handles both in-run and cross-run scenarios with the same code
path: at save time, `if REVIEWER_REPORT exists → --start-at test`.

### 5. Log artifact preservation for debugging

`PIPELINE_STATE.md` Notes field and `LAST_FAILURE_CONTEXT.json` both record
which artifacts were preserved and under what path, so the user can see why a
particular resume command is recommended.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Shell files modified | 2 | `tekhton.sh` (archive tracking), `lib/orchestrate_helpers.sh` (restore + resume routing) |
| Shell tests added | 1 | `tests/test_rejection_artifact_preservation.sh` |

## Implementation Plan

### Step 1 — tekhton.sh: track archived artifact paths

In the `START_AT=coder` archive loop, record destinations:
```bash
_ARCHIVED_REVIEWER_REPORT_PATH=""
_ARCHIVED_TESTER_REPORT_PATH=""
export _ARCHIVED_REVIEWER_REPORT_PATH _ARCHIVED_TESTER_REPORT_PATH

for f in ...; do
    if [ -f "$f" ]; then
        ARCHIVE_NAME="${LOG_DIR}/archive/$(date +%Y%m%d_%H%M%S)_$(basename "$f")"
        mkdir -p "${LOG_DIR}/archive"
        mv "$f" "$ARCHIVE_NAME"
        log "Archived previous ${f}"
        # Track for potential restoration
        case "$f" in
            *REVIEWER_REPORT*) _ARCHIVED_REVIEWER_REPORT_PATH="$ARCHIVE_NAME" ;;
            *TESTER_REPORT*)   _ARCHIVED_TESTER_REPORT_PATH="$ARCHIVE_NAME" ;;
        esac
    fi
done
```

### Step 2 — lib/orchestrate_helpers.sh: _save_orchestration_state() smart resume

Before `write_pipeline_state`, determine the best resume command:

```bash
_choose_resume_start_at() {
    # If REVIEWER_REPORT exists (in-run or just restored from archive),
    # resume from test stage — no need to re-run reviewer
    if [[ -f "${REVIEWER_REPORT_FILE:-}" ]]; then
        echo "test"
        return
    fi
    # Reviewer report was archived this run — restore it and resume from test
    if [[ -n "${_ARCHIVED_REVIEWER_REPORT_PATH:-}" ]] && \
       [[ -f "$_ARCHIVED_REVIEWER_REPORT_PATH" ]]; then
        cp "$_ARCHIVED_REVIEWER_REPORT_PATH" "${REVIEWER_REPORT_FILE}"
        log "[orchestrate] Restored archived REVIEWER_REPORT.md — resume with --start-at test."
        echo "test"
        return
    fi
    # Tester report exists — resume from tester
    if [[ -f "${TESTER_REPORT_FILE:-}" ]]; then
        echo "tester"
        return
    fi
    if [[ -n "${_ARCHIVED_TESTER_REPORT_PATH:-}" ]] && \
       [[ -f "$_ARCHIVED_TESTER_REPORT_PATH" ]]; then
        cp "$_ARCHIVED_TESTER_REPORT_PATH" "${TESTER_REPORT_FILE}"
        log "[orchestrate] Restored archived TESTER_REPORT.md — resume with --start-at tester."
        echo "tester"
        return
    fi
    # No artifacts — start from the beginning
    echo "${START_AT:-coder}"
}
```

In `_save_orchestration_state`, replace the hardcoded `--start-at ${START_AT}` with:
```bash
local _smart_start
_smart_start=$(_choose_resume_start_at)
resume_flags="${resume_flags} --start-at ${_smart_start}"
```

### Step 3 — Shell tests

`tests/test_rejection_artifact_preservation.sh`:
- `test_reviewer_report_preserved_when_exists` — REVIEWER_REPORT exists at save time → resume is `--start-at test`
- `test_reviewer_report_restored_from_archive` — archived path set, file exists → restored, resume `--start-at test`
- `test_no_reporter_fallback_to_coder` — no archive, no current report → resume `--start-at coder`
- `test_tester_report_restored_from_archive` — archived tester path → restored, resume `--start-at tester`

## Files Touched

### Modified
- `tekhton.sh` — archive loop tracks `_ARCHIVED_REVIEWER_REPORT_PATH` and `_ARCHIVED_TESTER_REPORT_PATH`
- `lib/orchestrate_helpers.sh` — `_choose_resume_start_at()` + use it in `_save_orchestration_state`

### Added
- `tests/test_rejection_artifact_preservation.sh`

## Acceptance Criteria

- [ ] When REVIEWER_REPORT.md exists at failure time, PIPELINE_STATE.md `Resume Command` uses `--start-at test`
- [ ] When REVIEWER_REPORT.md was archived at startup and no new one was created, it is copied back and `--start-at test` is suggested
- [ ] When no REVIEWER_REPORT.md is available (archived or current), falls back to `--start-at ${START_AT}`
- [ ] Same behavior for TESTER_REPORT.md → `--start-at tester`
- [ ] Restoration is logged: `[orchestrate] Restored archived REVIEWER_REPORT.md`
- [ ] `PIPELINE_STATE.md` Notes field mentions which artifact was restored
- [ ] `bash tests/test_rejection_artifact_preservation.sh` passes
- [ ] `shellcheck tekhton.sh lib/orchestrate_helpers.sh` zero warnings
- [ ] No behavior change when run succeeds (restoration logic never fires)
- [ ] `bash tests/run_tests.sh` passes (no regressions)

## Watch For

- The archive path variable is exported. Child processes (the agent) should not
  be able to see or modify it. It's exported purely for use by `_save_orchestration_state`
  which runs in the same shell process.
- `cp` (not `mv`) is used for restoration so the archive log entry remains intact.
  If the next run succeeds, the archive is just a harmless stale copy.
- When `--start-at review` is used (not `coder`), the archive loop for
  REVIEWER_REPORT fires but `_ARCHIVED_REVIEWER_REPORT_PATH` should NOT be set,
  because `--start-at review` explicitly archives the report to start fresh.
  Guard: only set `_ARCHIVED_*` when `START_AT = "coder"` or `"intake"`.

## Seeds Forward

- M94 uses the restored artifact path in its recovery CLI output: "Your reviewer
  previously approved this work. Run `tekhton --start-at test 'M88'` to proceed
  directly to the test stage."
- Future: extend to SECURITY_REPORT and INTAKE_REPORT for completeness.
