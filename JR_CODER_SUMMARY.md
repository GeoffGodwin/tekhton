# JR Coder Summary — Architect Remediation

## What Was Fixed

### SF-1: ARCHITECTURE.md — `lib/milestone_dag.sh` entry documentation
- **File:** `ARCHITECTURE.md` (Layer 3, line 121)
- **Change:** Updated the `lib/milestone_dag.sh` entry to document `milestone_dag_io.sh` as the first sourced helper module
- **Details:** Added explicit listing of I/O functions provided by `milestone_dag_io.sh`: `_dag_manifest_path`, `_dag_milestone_dir`, `has_milestone_manifest`, `load_manifest`, `save_manifest`
- **Reason:** The I/O layer was missing from the architecture documentation, causing confusion about where manifest path resolution logic lives

### SF-2: `lib/milestone_archival.sh` — Uniqueness assumption documentation
- **File:** `lib/milestone_archival.sh` (lines 51–68)
- **Change:** Added comprehensive block comment before `archive_initiative=""` assignment explaining the DAG-mode archive search behavior
- **Details:** Documented three key points:
  1. Why `archive_initiative` is cleared in DAG mode (forces global grep, avoids false negatives from initiative-name mismatch)
  2. The uniqueness assumption: DAG milestone numbers are globally unique across a project's lifetime
  3. The known edge case: if a project resets milestone numbering, a prior archived entry could produce a false positive; this is considered acceptable
- **Reason:** The code logic was correct but undocumented, creating a hidden assumption about milestone ID uniqueness that could cause subtle bugs if milestone numbering is ever reset

## Files Modified

- `ARCHITECTURE.md` — Updated documentation for `lib/milestone_dag.sh` entry
- `lib/milestone_archival.sh` — Added block comment documenting archive search behavior and uniqueness assumption

## Verification

- `bash -n lib/milestone_archival.sh` — ✓ Passed
- `shellcheck lib/milestone_archival.sh` — ✓ Passed
