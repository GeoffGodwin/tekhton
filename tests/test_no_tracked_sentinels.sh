#!/usr/bin/env bash
# tests/test_no_tracked_sentinels.sh — m05 regression guard.
#
# Fails if any file under .tekhton/.* is tracked by git. All such files are
# intended to be transient sentinels; tracking any of them inverts their
# safety contracts. The canonical example: m50's manifest write guard reads
# .tekhton/.finalize_active to decide if a MANIFEST.cfg write is legitimate.
# If the sentinel is tracked and stuck at "set" state from a prior commit,
# legitimate finalize writes get blocked and rogue writes get allowed.
#
# See docs/sentinel-hygiene.md for the full convention.

set -euo pipefail

mapfile -t tracked < <(git ls-files '.tekhton/.[!.]*' 2>/dev/null || true)
if [[ "${#tracked[@]}" -gt 0 ]]; then
    printf 'FAIL: the following sentinel files are tracked in git:\n' >&2
    printf '  %s\n' "${tracked[@]}" >&2
    printf '\n' >&2
    printf 'All .tekhton/.* files are transient sentinels per m05.\n' >&2
    printf 'See docs/sentinel-hygiene.md for the convention.\n' >&2
    printf 'Fix: add the file pattern to .gitignore and\n' >&2
    printf '  git rm --cached <file>\n' >&2
    exit 1
fi

printf 'PASS: no tracked sentinel files under .tekhton/.*\n'
