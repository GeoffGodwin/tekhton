# Milestone 95: `lib/test_audit.sh` File Split
<!-- milestone-meta
id: "95"
status: "done"
-->

## Overview

`lib/test_audit.sh` is 574 lines — 274 lines over the 300-line soft ceiling. The
file's seven exported symbols fall into two natural clusters that warrant
independent extraction into companion modules, leaving the parent focused on
orchestration only.

**Target extraction clusters (from M92 architect audit):**

- **Detection helpers** (`_detect_orphaned_tests`, `_detect_test_weakening`) →
  `lib/test_audit_detection.sh`. These are pure shell analysis functions with no
  verdict routing dependencies — natural standalone extraction.

- **Verdict layer** (`_parse_audit_verdict`, `_route_audit_verdict`) →
  `lib/test_audit_verdict.sh`. Report parsing and downstream dispatch, cleanly
  separable from detection logic.

Extracting these two clusters will remove approximately 200 lines from the
parent. If the parent remains above 300 lines after this extraction, the
implementation agent should also move the pre-audit file collection helpers
(`_collect_audit_context`, `_discover_all_test_files`, `_build_test_audit_context`)
to a third file (`lib/test_audit_helpers.sh`) to meet the acceptance criterion.

## Design Decisions

### 1. Each extracted file is self-contained

Each new file follows the established pattern:
```bash
#!/usr/bin/env bash
set -euo pipefail
# FILENAME — <one-line description>
# Sourced by tekhton.sh — do not run directly.
# Expects: common.sh, test_audit.sh sourced first.
```

No circular dependencies. `test_audit_detection.sh` has zero runtime dependencies
on `test_audit_verdict.sh` and vice versa.

### 2. Parent file retains orchestration only

After the split, `lib/test_audit.sh` retains:
- `run_test_audit` — main pipeline integration entry point
- `run_standalone_test_audit` — `--audit-tests` standalone entry point
- Any context assembly logic that directly drives these two functions

Pure analysis/detection/verdict helpers belong in the companion files.

### 3. Source order in tekhton.sh

The extraction files must be sourced before `test_audit.sh` in `tekhton.sh`:
```bash
source "${TEKHTON_HOME}/lib/test_audit_detection.sh"
source "${TEKHTON_HOME}/lib/test_audit_verdict.sh"
source "${TEKHTON_HOME}/lib/test_audit.sh"
```
(and `test_audit_helpers.sh` if created).

### 4. No behavioral changes

This is a pure structural refactoring. Function signatures, exported variables,
and all observable behavior remain identical. Callers (`stages/tester.sh`,
`stages/tester_validation.sh`, and any other consumer) require no changes beyond
the sourcing order.

### 5. ARCHITECTURE.md update

Add the new files to the ARCHITECTURE.md module inventory with one-line
descriptions. Update the entry for `lib/test_audit.sh` to note the companion
modules.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Shell files created | 2–3 | `lib/test_audit_detection.sh`, `lib/test_audit_verdict.sh`, optionally `lib/test_audit_helpers.sh` |
| Shell files modified | 2 | `lib/test_audit.sh` (functions removed), `tekhton.sh` (source order) |
| Docs files modified | 1 | `ARCHITECTURE.md` (module inventory) |
| Shell tests added | 1 | `tests/test_test_audit_split.sh` — confirms each function callable from its new home |

## Implementation Plan

### Step 1 — Extract `lib/test_audit_detection.sh`

Move `_detect_orphaned_tests` and `_detect_test_weakening` (with their section
headers and inline comments) into the new file. Remove from `lib/test_audit.sh`.

### Step 2 — Extract `lib/test_audit_verdict.sh`

Move `_parse_audit_verdict` and `_route_audit_verdict` (with their section
headers and inline comments) into the new file. Remove from `lib/test_audit.sh`.

### Step 3 — Optional: extract `lib/test_audit_helpers.sh`

If `lib/test_audit.sh` is still above 300 lines after Steps 1–2, move
`_collect_audit_context`, `_discover_all_test_files`, and
`_build_test_audit_context` to `lib/test_audit_helpers.sh`.

### Step 4 — Update `tekhton.sh` source order

Add source lines for the new files before `lib/test_audit.sh`.

### Step 5 — Update ARCHITECTURE.md and CLAUDE.md

Add new files to the module inventory tables. Update the `lib/test_audit.sh`
entry to reference its companion modules.

### Step 6 — Add split tests

Write `tests/test_test_audit_split.sh` that sources each new file in isolation
and asserts the expected functions are defined and callable with stub inputs.

### Step 7 — Full shellcheck pass

Run `shellcheck lib/test_audit.sh lib/test_audit_detection.sh
lib/test_audit_verdict.sh` (and `lib/test_audit_helpers.sh` if created) and
resolve all warnings before marking done.

## Acceptance Criteria

- [ ] `lib/test_audit.sh` is ≤ 300 lines
- [ ] `lib/test_audit_detection.sh` exists and defines `_detect_orphaned_tests` and `_detect_test_weakening`
- [ ] `lib/test_audit_verdict.sh` exists and defines `_parse_audit_verdict` and `_route_audit_verdict`
- [ ] `tekhton.sh` sources the new files before `lib/test_audit.sh`
- [ ] All seven extracted functions pass a direct call test in `tests/test_test_audit_split.sh`
- [ ] `shellcheck` is clean on all modified and created `.sh` files
- [ ] ARCHITECTURE.md lists the new companion modules
- [ ] Existing test suite passes unchanged
