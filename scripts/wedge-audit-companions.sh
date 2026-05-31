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

# m29.2 (Phase 5): the detect subsystem ported to internal/detect/. All
# ten lib/detect*.sh files were deleted; the bash surface is now provided
# by lib/common_detect.sh (per-domain `_tk_detect_*` wrappers around
# `tekhton detect summary --json`). Re-introducing any lib/detect*.sh
# file would silently fork the detection contract. The `common_detect.sh`
# name does not match the `lib/detect*.sh` pattern (no leading `detect`).
_detect_re=$(find lib -maxdepth 1 -name 'detect*.sh' -print 2>/dev/null)
if [[ -n "$_detect_re" ]]; then
    printf 'wedge-audit: m29.2 violation — lib/detect*.sh file(s) re-introduced:\n' >&2
    printf '%s\n' "$_detect_re" >&2
    printf 'The detect subsystem lives in internal/detect/. Bash callers use\n' >&2
    printf '_tk_detect_* wrappers from lib/common_detect.sh (sourced via common.sh).\n' >&2
    companion_failures=$(( companion_failures + 1 ))
fi
unset _detect_re

# m32.2 (Phase 5): the diagnose rule registry ported to
# internal/diagnose/rules/. Rules must NOT import "regexp" directly —
# match-evidence regexes belong in internal/errors/patterns.go (or
# evidence.go), and rules call typed helpers from internal/errors. This
# keeps the m17 classification boundary intact and prevents per-rule
# regex sprawl. The regression test in tests/test_wedge_audit_rules.sh
# plants a violation to verify this gate fires.
if [[ -d internal/diagnose/rules ]]; then
    _rules_regex_violations=$(grep -rl '"regexp"' internal/diagnose/rules 2>/dev/null || true)
    if [[ -n "$_rules_regex_violations" ]]; then
        printf 'wedge-audit: m32.2 violation — internal/diagnose/rules/ must not import regexp:\n' >&2
        printf '%s\n' "$_rules_regex_violations" >&2
        printf 'Move the regex to internal/errors/evidence.go (or patterns.go) and call\n' >&2
        printf 'the typed helper from the rule instead.\n' >&2
        companion_failures=$(( companion_failures + 1 ))
    fi
    unset _rules_regex_violations
fi

if (( companion_failures > 0 )); then
    printf 'wedge-audit: %d companion-tool assertion(s) failed.\n' "$companion_failures" >&2
    exit 1
fi
