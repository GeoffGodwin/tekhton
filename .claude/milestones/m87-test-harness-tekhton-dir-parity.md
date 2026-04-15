# Milestone 87: Test Harness TEKHTON_DIR Parity
<!-- milestone-meta
id: "87"
status: "done"
-->

## Overview

M72 introduced `.tekhton/` as the default directory for Tekhton-managed files.
However, the test harness (`tests/run_tests.sh`) works around this by setting
all `_FILE` variables to root-relative paths with the comment "Tests predate
the TEKHTON_DIR move (M72), so we default to root-relative paths."

This means tests never exercise the actual `.tekhton/` paths used in production.
A bug where a file is written to the wrong path would pass all tests. This
milestone eliminates the test/production path divergence by updating the test
harness and individual test files to use `${TEKHTON_DIR}/` prefixed paths.

## Design Decisions

### 1. Test-local .tekhton/ directories

Each test that creates files will use a temp directory with a `.tekhton/`
subdirectory. The setup creates `mkdir -p "${TMPDIR}/.tekhton"` and sets
`TEKHTON_DIR=.tekhton` (already the default). File variables resolve to
`.tekhton/NAME.md` relative to the test's working directory.

### 2. Incremental migration of individual tests

Not all tests reference `_FILE` variables directly. Only tests that do need
updating. The bulk change is in `run_tests.sh` (remove root-relative overrides);
individual tests that set their own `_FILE` values are updated one by one.

### 3. New integration test for root cleanliness

Add a dedicated test (`test_tekhton_dir_root_cleanliness.sh`) that:
- Sets up a minimal project directory
- Sources config_defaults.sh to get all `_FILE` defaults
- Verifies every `_FILE` default resolves under `${TEKHTON_DIR}/`
- Verifies no `_FILE` default points to the project root

This is a pure-structural test but catches the exact class of bug that M72
missed (a variable defaulting to root instead of `.tekhton/`).

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Test harness updated | 1 | `tests/run_tests.sh` — remove root-relative overrides |
| Individual tests updated | ~8 | Tests that set _FILE vars to root-relative |
| New test added | 1 | Root cleanliness verification test |

## Implementation Plan

### Step 1 — Update tests/run_tests.sh

Change all `_FILE` variable exports from root-relative to `${TEKHTON_DIR}/`
prefixed paths:

```bash
# Before (M72 workaround):
export CODER_SUMMARY_FILE="${CODER_SUMMARY_FILE:-CODER_SUMMARY.md}"

# After:
export CODER_SUMMARY_FILE="${CODER_SUMMARY_FILE:-${TEKHTON_DIR}/CODER_SUMMARY.md}"
```

Remove the "Tests predate the TEKHTON_DIR move" comment.

### Step 2 — Update individual test files

Search for tests that set `_FILE` variables to root-relative paths.
Known files:
- `tests/test_lifecycle_acp.sh` (lines 21-23)
- `tests/test_notes_rollback.sh` (multiple sites)
- `tests/test_notes_normalization.sh` (line 17)
- `tests/test_cleanup_notes.sh` (line 11)
- `tests/test_human_workflow.sh` (lines 710-712)
- `tests/test_audit_tests.sh` (lines 38, 50)
- `tests/test_specialists.sh` (line 50)
- `tests/test_audit_coverage_gaps.sh` (lines 45, 57)
- `tests/test_clear_resolved_nonblocking_notes.sh` (line 20)
- `tests/test_drift_management.sh` (lines 13-15)

For each, ensure `mkdir -p` creates the `.tekhton/` directory in the test's
temp directory and update variable values.

### Step 3 — Add root cleanliness test

Create `tests/test_tekhton_dir_root_cleanliness.sh`:

```bash
# Verify every _FILE config default resolves under ${TEKHTON_DIR}/
# Catches the class of bug where a new _FILE variable defaults to root.
```

The test sources `config_defaults.sh` (with stubs for `_clamp_config_value`
and `_clamp_config_float`) and checks each `*_FILE` variable.

### Step 4 — Run full test suite

```bash
bash tests/run_tests.sh
shellcheck tests/*.sh
```

## Files Touched

### Added
- `tests/test_tekhton_dir_root_cleanliness.sh` — root path verification test

### Modified
- `tests/run_tests.sh` — use TEKHTON_DIR-prefixed defaults
- `tests/test_lifecycle_acp.sh` — update _FILE paths
- `tests/test_notes_rollback.sh` — update _FILE paths
- `tests/test_notes_normalization.sh` — update _FILE paths
- `tests/test_cleanup_notes.sh` — update _FILE paths
- `tests/test_human_workflow.sh` — update _FILE paths
- `tests/test_audit_tests.sh` — update _FILE paths
- `tests/test_specialists.sh` — update _FILE paths
- `tests/test_audit_coverage_gaps.sh` — update _FILE paths
- `tests/test_clear_resolved_nonblocking_notes.sh` — update _FILE paths
- `tests/test_drift_management.sh` — update _FILE paths

## Acceptance Criteria

- [ ] `tests/run_tests.sh` no longer contains root-relative `_FILE` defaults
- [ ] All `_FILE` exports in `run_tests.sh` use `${TEKHTON_DIR}/` prefix
- [ ] The "Tests predate the TEKHTON_DIR move" comment is removed
- [ ] Every test file that sets `_FILE` variables uses `${TEKHTON_DIR}/` prefix
- [ ] New root cleanliness test exists and passes
- [ ] Root cleanliness test verifies every `*_FILE` variable in config_defaults.sh resolves under `${TEKHTON_DIR}/` (excluding CLAUDE.md, CHANGELOG, and project-root-intentional files)
- [ ] **Behavioral:** `bash tests/run_tests.sh` passes with zero failures
- [ ] **Behavioral:** Adding a new `_FILE` variable to config_defaults.sh with a root-relative default would cause the root cleanliness test to fail
- [ ] No shellcheck warnings on modified test files
