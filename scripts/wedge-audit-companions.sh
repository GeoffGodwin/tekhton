#!/usr/bin/env bash
# scripts/wedge-audit-companions.sh — m27.3 companion-tool presence checks.
#
# Sourced by scripts/wedge-audit.sh at the end of its main pass. Extracted
# from wedge-audit.sh to keep that file under the 300-line bash ceiling.
#
# m27.3 adds the env-contract static audit (scripts/audit-bash-env.sh) and
# the set -u parity test (tests/test_stage_env_setu.sh), both wired into
# `make dogfood`. A future cleanup pass that removes either side silently
# degrades the env-contract gate. Catch that at wedge-audit time so the
# regression surfaces in the same place every other shim-loss regression
# does.
#
# Sourced — do not run directly. Caller (wedge-audit.sh) is already under
# `set -euo pipefail` and runs from the repo root.

companion_failures=0

_assert_file_exists() {
    local path="$1" label="$2"
    if [[ ! -f "$path" ]]; then
        printf 'wedge-audit: missing companion file: %s (%s)\n' "$path" "$label" >&2
        companion_failures=$(( companion_failures + 1 ))
    fi
}

_assert_grep_in_file() {
    local needle="$1" haystack="$2" label="$3"
    if [[ ! -f "$haystack" ]]; then
        printf 'wedge-audit: cannot check %s — %s is missing\n' "$label" "$haystack" >&2
        companion_failures=$(( companion_failures + 1 ))
        return
    fi
    if ! grep -qF -- "$needle" "$haystack"; then
        printf 'wedge-audit: %s no longer references %q (%s)\n' \
            "$haystack" "$needle" "$label" >&2
        companion_failures=$(( companion_failures + 1 ))
    fi
}

_assert_file_exists "scripts/audit-bash-env.sh" \
    "m27.1 env audit script"
_assert_grep_in_file "scripts/audit-bash-env.sh" "Makefile" \
    "make dogfood wires the audit gate"
_assert_file_exists "tests/test_stage_env_setu.sh" \
    "m27.3 set -u parity test"
_assert_grep_in_file "tests/test_stage_env_setu.sh" "Makefile" \
    "make dogfood wires the parity test"

if (( companion_failures > 0 )); then
    printf 'wedge-audit: %d companion-tool assertion(s) failed.\n' "$companion_failures" >&2
    exit 1
fi
