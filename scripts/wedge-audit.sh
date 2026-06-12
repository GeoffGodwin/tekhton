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
    # m12 (Phase 4) — only the agent shim may shell to `tekhton supervise`.
    # The orchestrate loop reads the supervisor result through the shim.
    "lib/agent.sh"
    "lib/agent_shim.sh"
    # m18 (Phase 4 batch 2) — only the stage-envelope shim writes
    # tekhton.stage.result.v1 envelopes. Other lib/ or stages/ files MUST
    # call emit_stage_envelope rather than printf the JSON inline.
    "lib/stage_envelope.sh"
    # m19 (Phase 4 batch 2) — these three files document the rename from
    # the deleted orchestrate_main.sh / orchestrate_state.sh and reference
    # the legacy filenames in their docstrings only. The function bodies use
    # the new names (_orch_complete_run, _orch_record_save_state).
    "lib/orchestrate.sh"
    "lib/orchestrate_complete.sh"
    "lib/orchestrate_save.sh"
    # m20 (Phase 4 batch 2) — the orchestrate-aux/-classify/-iteration trio
    # is the legacy bash retry loop that tekhton-legacy.sh still uses for
    # any bash-only paths that survived the dispatcher cutover. Comments
    # reference _run_pipeline_stages by name; orchestrate_aux.sh sources
    # orchestrate_save.sh. Phase 5 deletes all three when tekhton-legacy.sh
    # is dismantled.
    "lib/orchestrate_aux.sh"
    "lib/orchestrate_classify.sh"
    "lib/orchestrate_iteration.sh"
    # m19 (Phase 4 batch 2) — the planning batch helper routes through the
    # supervise seam to pick up provider-aware routing (PROVIDER_<LABEL>
    # overrides for plan_interview / plan_generate / replan). It is the
    # planning-stage analog of lib/agent.sh's run_agent — it builds an
    # agent.request.v1 envelope via _shim_write_request and shells to
    # `"$_bin" supervise --request-file`. Allowlisted alongside agent.sh
    # so the planning stages stay on the same provider seam as the main
    # pipeline; tekhton-legacy.sh's --plan path is the only caller chain.
    "lib/plan_batch.sh"
)

# --- Patterns to detect ------------------------------------------------------
# The PATTERNS array is defined in scripts/wedge-audit-patterns.sh. It was
# extracted into a sibling data-only file to keep this audit script under
# the 300-line bash ceiling (CLAUDE.md Rule 8). The patterns file is exempt
# from the ceiling per the same rule (data-only: a single array assignment,
# no function bodies, no conditional logic).
# shellcheck source=scripts/wedge-audit-patterns.sh
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/wedge-audit-patterns.sh"

# --- Audit -------------------------------------------------------------------
shopt -s globstar nullglob
mapfile -t TARGET_FILES < <(printf '%s\n' lib/**/*.sh stages/**/*.sh | sort -u)

# WEDGE_AUDIT_EXTRA_FILES lets the test harness add files outside lib/+stages
# to the scan list — the wedge tests use this to drop deliberate violation
# files into a per-process mktemp dir instead of polluting the real lib/,
# which would race with concurrent test suites scanning the same directory.
if [[ -n "${WEDGE_AUDIT_EXTRA_FILES:-}" ]]; then
    # shellcheck disable=SC2206  # intentional word-splitting on whitespace
    _extra=( ${WEDGE_AUDIT_EXTRA_FILES} )
    TARGET_FILES+=( "${_extra[@]}" )
fi

# is_allowed FILE — true if FILE is in ALLOWED_FILES.
is_allowed() {
    local f="$1" allowed
    for allowed in "${ALLOWED_FILES[@]}"; do
        [[ "$f" = "$allowed" ]] && return 0
    done
    return 1
}

# Write all patterns to a temp file so each source file needs only one grep
# pass — O(N) subprocess calls instead of O(N×M), critical for WSL2 performance.
_pat_file=$(mktemp)
trap 'rm -f "$_pat_file"' EXIT
printf '%s\n' "${PATTERNS[@]}" > "$_pat_file"

violations=0
report=""

for file in "${TARGET_FILES[@]}"; do
    is_allowed "$file" && continue
    # grep -E for ERE; -n for line numbers; -H for filename; -f for pattern
    # file. Suppress exit code 1 (no match) so set -e doesn't abort the loop.
    file_violations="$(grep -nHEf "$_pat_file" "$file" 2>/dev/null || true)"
    if [[ -n "$file_violations" ]]; then
        violations=$(( violations + 1 ))
        report+="--- $file ---"$'\n'"${file_violations}"$'\n'
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

# m27.3 companion-tool presence checks. Extracted to a sibling file so the
# main audit stays under the 300-line bash ceiling.
# shellcheck source=scripts/wedge-audit-companions.sh
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/wedge-audit-companions.sh"
