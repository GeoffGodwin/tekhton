# Coder Summary

## Status: COMPLETE

## What Was Implemented

Tester-reported BUG against `lib/project_version.sh:82` (`_accessor_for_file`
returning `"plaintext"` for `.json`-suffixed filenames not in its explicit list,
causing a false `version_files_desynced_*` commit-gate trip during the
`verify_version_files_synced` round-trip read) is **already resolved** on the
current working tree by commit `7684b9e` (m43 finalize bump).

The fix is a single-line addition to the `case "$basename"` block in
`_accessor_for_file`, placing a `*.json) echo "json" ;;` glob arm immediately
before the `*) echo "plaintext" ;;` catch-all. Auto-discovered files (all named
`package.json`) were already routed correctly by the explicit `package.json`
arm; this glob covers manually declared non-conventional JSON basenames like
`widget-manifest.json` and re-aligns the bumper and verifier accessor tables
so `_bump_single_file`'s `*` catch-all (which routes by content via `head -c 1`)
and `_accessor_for_file` agree.

This run is therefore a verification-and-bookkeeping pass: confirm the fix
is in place, the failing test from the prior run now passes, and the full
suite is green.

## Root Cause (bugs only)

`_accessor_for_file` and `_bump_single_file` used different routing strategies
for unknown JSON basenames: the bumper sniffed the first byte (`{` → json),
while the accessor used a name-based table whose `*` catch-all returned
`plaintext`. The accessor then passed `plaintext` to `_detect_version_from_file`,
which calls `tr -d '[:space:]' < "$file"` and compares the resulting full-file
blob to the target version string — guaranteed to fail for any JSON file.
The post-bump verify path consequently tripped `trip_commit_gate
"version_files_desynced_<file>"` for a file that had in fact been bumped
correctly.

Fix: add a `*.json) echo "json" ;;` arm to `_accessor_for_file` so the
content-based detection in the bumper and the name-based detection in the
verifier agree on the same routing decision for any `.json`-suffixed file.

## Verification

| Check | Result |
|---|---|
| `bash tests/test_version_bump_coverage.sh` (was 8 PASS / 1 FAIL before fix) | 9 PASS / 0 FAIL |
| `bash tests/run_tests.sh` (full shell suite) | 510 PASS / 0 FAIL |
| Go: `go test ./...` (driven by `run_tests.sh`) | all packages PASS |
| `shellcheck -S warning lib/project_version*.sh tests/test_version_bump_coverage.sh` | clean (exit 0) |

The fix-touching test `tests/test_version_bump_coverage.sh` Test case "verify
round-trip: non-conventional JSON — catch-all accessor gap" is the precise
regression coverage the tester asked for; it now passes against the fixed
accessor.

## Files Modified

None in this run. The fix already exists on the current branch as commit
`7684b9e` (single-line addition at `lib/project_version.sh:82`). This pass
only verifies the resolved state.

## Architecture Change Proposals

None.

## Observed Issues (out of scope)

Carried over from the m43 reviewer report (non-blocking, not in this task's
scope):

- `lib/project_version.sh:2` — `set -euo pipefail` in a sourced lib file
  violates the convention that only entry points set this. Pre-existing,
  not introduced by m43. (Same class of drift as `lib/hooks_final_checks.sh`
  noted in m42.)
- `tekhton-legacy.sh:999` — Explicit `source` of
  `lib/project_version_bump_helpers.sh` is redundant; the parent
  `lib/project_version_bump.sh` self-sources it via a sentinel guard. Harmless
  but worth tidying on the next touch.

## Human Notes Status

No Human Notes block was injected for this run.

## Docs Updated

None — no public-surface changes in this task.
