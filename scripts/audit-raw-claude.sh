#!/usr/bin/env bash
# scripts/audit-raw-claude.sh — m20 raw-claude-call audit.
#
# Scans lib/, stages/, tekhton.sh, and tekhton-legacy.sh for calls to the
# claude binary in command position (flag, subcommand, and line-continuation
# forms). Every such call must be routed through `tekhton supervise` after m20;
# any unlisted call is a CI gate failure.
#
# Usage:
#   scripts/audit-raw-claude.sh                     # scan the default tree
#   scripts/audit-raw-claude.sh path/to/file_or_dir # scan a single target
#
# Allowlist (temporary — remove each entry when the caller is ported):
#   lib/quota_probe.sh — allowlisted until m21 (probe call predates supervise seam)
#   lib/common.sh      — `claude usage` probe is provider-gated to PROVIDER=claude,
#                        mirroring quota_probe.sh; retire when usage probe ports to Go.
#
# Output format — one finding per line:
#   <file>:<line>:<matched-text>
#
# Exit codes:
#   0 = no findings (clean)
#   1 = one or more raw claude calls found outside the allowlist

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# --- Allowlist ----------------------------------------------------------------
# Files whose raw claude calls are temporarily permitted. Remove each entry
# once the caller is ported to tekhton supervise.
_ALLOWLIST=(
    "lib/quota_probe.sh"
    "lib/common.sh"
)

_is_allowlisted() {
    local file="$1"
    local entry
    for entry in "${_ALLOWLIST[@]}"; do
        if [[ "${file}" == "${entry}" || "${file}" == *"/${entry}" ]]; then
            return 0
        fi
    done
    return 1
}

# --- Resolve scan targets -----------------------------------------------------
# With no args, scan the default tree (lib/, stages/, tekhton.sh,
# tekhton-legacy.sh). With one or more args, scan exactly those paths so the
# unit tests can drive the audit against tmpdir fixtures.
_resolve_targets() {
    cd -- "${REPO_ROOT}"
    local -a inputs=()
    if [[ "$#" -gt 0 ]]; then
        inputs=( "$@" )
    else
        inputs=( lib/ stages/ tekhton.sh tekhton-legacy.sh )
    fi
    local t
    for t in "${inputs[@]}"; do
        if [[ -f "${t}" ]]; then
            printf '%s\n' "${t}"
        elif [[ -d "${t}" ]]; then
            find "${t}" -type f -name '*.sh' -print | sort
        fi
    done
}

# --- Pattern: claude in command position --------------------------------------
# Matches lines where `claude` appears as the command being executed:
#   - Direct call:            ^[[:space:]]*(claude[[:space:]])
#   - After pipe/subshell:    | claude, $( claude, $( ...| claude
#   - After &&/||:            && claude, || claude
#   - Line continuation:      \ newline then claude
#   - Flag passing:           --flag claude (flag value forms excluded — flag
#                             NAMES can't start with claude, so this is safe)
#   - exec/eval:              exec claude, eval "claude ..."
# We use grep -E for portability (no pcregrep / grep -P needed).
_PATTERN='(^|[|;&(])[[:space:]]*(exec[[:space:]]+)?claude[[:space:]]'

# --- Main ---------------------------------------------------------------------
main() {
    cd -- "${REPO_ROOT}"

    local findings=0
    local -a targets=()
    while IFS= read -r line; do
        [[ -n "${line}" ]] && targets+=("${line}")
    done < <(_resolve_targets "$@")

    if [[ "${#targets[@]}" -eq 0 ]]; then
        exit 0
    fi

    local file lineno matched
    for file in "${targets[@]}"; do
        if _is_allowlisted "${file}"; then
            continue
        fi
        if [[ ! -f "${file}" ]]; then
            continue
        fi
        while IFS=: read -r lineno matched; do
            printf '%s:%s:%s\n' "${file}" "${lineno}" "${matched}"
            findings=$(( findings + 1 ))
        done < <(grep -nE "${_PATTERN}" "${file}" 2>/dev/null | grep -v '^[[:space:]]*#' || true)
    done

    exit $(( findings > 0 ? 1 : 0 ))
}

main "$@"
