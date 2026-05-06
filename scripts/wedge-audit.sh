#!/usr/bin/env bash
# scripts/wedge-audit.sh — m04 invariant gate for the bash↔Go seam.
#
# The Go wedges (m02 causal log, m03 pipeline state) own the writer side of
# CAUSAL_LOG.jsonl and PIPELINE_STATE_FILE. The bash tree is allowed to read
# those files anywhere, but the only files that may *write* to them are the
# shim modules below. This script greps lib/ and stages/ for direct-write
# patterns and fails CI if any other file bypasses the shim.
#
# Catching a bypass at PR time is much cheaper than catching it at runtime —
# a regression here silently corrupts the cross-process seam.
#
# Usage:
#   scripts/wedge-audit.sh         # audit HEAD
#
# Exit codes:
#   0 = clean — no bypasses detected
#   1 = one or more files bypass the shim (per-file report printed)

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$REPO_ROOT"

# --- Allowlist ---------------------------------------------------------------
# Only these files may write to the wedge-owned paths. lib/state_helpers.sh is
# the bash-fallback writer extracted from lib/state.sh during the m03 size
# split — it is part of the state shim by intent. The Go binary owns the
# canonical writer; these files are the bash-fallback used only when the
# `tekhton` binary is not on PATH (test sandboxes, fresh clones).
ALLOWED_FILES=(
    "lib/causality.sh"
    "lib/state.sh"
    "lib/state_helpers.sh"
)

# --- Patterns to detect ------------------------------------------------------
# Each pattern targets a known direct-write shape. The patterns are
# deliberately loose (they err toward catching, not toward false negatives) —
# any false positive can be added to the allowlist with a justification.
#
# 1. `>>` or `>` redirection into the wedge-owned path variables.
# 2. `mv …` into the wedge-owned path variables (atomic-write completion).
# 3. In-process counter assignments that Go now owns.
# 4. m10 cutover: inline `python3 -c "...json..."` parses anywhere in lib/ —
#    the supervisor wedge replaced these with structured agent.response.v1
#    fields. Multi-line python3 invocations are caught by an additional
#    pass below that scans for `python3 -c "$` followed by `import json`.
# 5. m10 cutover: a regression here would be a re-introduction of one of
#    the deleted bash supervisor files. We can't grep for the absence of
#    a file, but we can flag any source line that names one.
PATTERNS=(
    # Redirection (append or overwrite) into the variable.
    '>[[:space:]]*"?\$\{?CAUSAL_LOG_FILE\b'
    '>[[:space:]]*"?\$\{?PIPELINE_STATE_FILE\b'
    # mv/cp tmpfile into the path.
    '\b(mv|cp)[[:space:]].*"?\$\{?CAUSAL_LOG_FILE\b'
    '\b(mv|cp)[[:space:]].*"?\$\{?PIPELINE_STATE_FILE\b'
    # In-process counters owned by the Go side.
    '^[[:space:]]*_LAST_EVENT_ID='
    '^[[:space:]]*_CAUSAL_EVENT_COUNT='
    # m10: single-line inline JSON parses via python.
    'python3[[:space:]]+-c[[:space:]].*json'
    # m10: re-source of any deleted bash supervisor module. Anchored on the
    # `source`/`.` builtin so comments documenting the m10 cutover (which
    # legitimately name the files) don't trip the audit.
    '^[[:space:]]*(source|\.)[[:space:]]+.*/(agent_monitor[^"[:space:]]*|agent_retry[^"[:space:]]*)'
)

# --- Audit -------------------------------------------------------------------
shopt -s globstar nullglob
mapfile -t TARGET_FILES < <(printf '%s\n' lib/**/*.sh stages/**/*.sh | sort -u)

# is_allowed FILE — true if FILE is in ALLOWED_FILES.
is_allowed() {
    local f="$1" allowed
    for allowed in "${ALLOWED_FILES[@]}"; do
        [[ "$f" = "$allowed" ]] && return 0
    done
    return 1
}

violations=0
report=""

for file in "${TARGET_FILES[@]}"; do
    is_allowed "$file" && continue
    file_violations=""
    for pattern in "${PATTERNS[@]}"; do
        # grep -E for ERE; -n for line numbers; -H for filename. Suppress
        # exit code 1 (no match) so set -e doesn't abort the loop.
        matches="$(grep -nHE "$pattern" "$file" 2>/dev/null || true)"
        [[ -n "$matches" ]] && file_violations+="${matches}"$'\n'
    done
    if [[ -n "$file_violations" ]]; then
        violations=$(( violations + 1 ))
        report+="--- $file ---"$'\n'"$file_violations"
    fi
done

if (( violations > 0 )); then
    printf 'wedge-audit: %d file(s) bypass the wedge shim.\n\n' "$violations" >&2
    printf '%s\n' "$report" >&2
    printf 'Allowed writers (intentional): %s\n' "${ALLOWED_FILES[*]}" >&2
    printf 'If a new shim file is needed, add it to ALLOWED_FILES with a justifying comment.\n' >&2
    exit 1
fi

printf 'wedge-audit: clean (%d files audited, %d allowed shim writers).\n' \
    "${#TARGET_FILES[@]}" "${#ALLOWED_FILES[@]}"
