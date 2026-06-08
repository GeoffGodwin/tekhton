#!/usr/bin/env bash
# scripts/wedge-audit-companions-coder.sh — m39 coder-arc presence checks.
#
# Sourced by scripts/wedge-audit-companions.sh. Extracted to keep the parent
# file under the 300-line bash ceiling (CLAUDE.md Rule 8). Holds the m39.4
# closure assertions for the coder family port: the four bash files must
# stay deleted, the stagerunner default must dispatch Go-native, and the
# pipeline-stage subset of stages/ must be empty.
#
# Sourced — do not run directly. Caller (wedge-audit-companions.sh) is
# already under `set -euo pipefail` and runs from the repo root.

# m39.4 (Phase 5, stage-port arc): the four coder bash files ported to
# internal/stages/coder/ + internal/coder/{prerun,buildfix,scout}/ across
# m39.1-m39.4. Re-introducing any of them silently forks the coder-stage
# contract and breaks the StageDef.GoImpl dispatch precedence the m39 arc
# closes. The orchestrator (run_stage_coder body) lives in
# internal/stages/coder/orchestrator.go; the sub-packages own pre-run,
# build-fix, and scout. The 15-step Run sequence is the contract.
for _coder_bash in \
    stages/coder.sh \
    stages/coder_buildfix.sh \
    stages/coder_buildfix_helpers.sh \
    stages/coder_prerun.sh; do
    if [[ -f "$_coder_bash" ]]; then
        printf 'wedge-audit: m39.4 violation — %s was ported in m39:\n' "$_coder_bash" >&2
        printf '  %s re-introduced\n' "$_coder_bash" >&2
        printf 'The coder stage lives in internal/stages/coder/; sub-packages in\n' >&2
        printf 'internal/coder/{prerun,buildfix,scout}/. Bash callers reach it via\n' >&2
        printf 'the StageDef.GoImpl dispatch wedge in internal/stagerunner/.\n' >&2
        companion_failures=$(( companion_failures + 1 ))
    fi
done
unset _coder_bash

# m39.4 (Phase 5): assert StageCoder carries GoImpl and NOT Helpers / Script.
# A Helpers entry would cause a 127 exit if any fallback path ever reaches
# bash (the four bash files are deleted); a Script entry would silently
# route the coder back through the deleted bash file.
if grep -nE 'StageCoder' internal/stagerunner/helpers.go | grep -E 'Script:|Helpers:' >/dev/null 2>&1; then
    printf 'wedge-audit: m39.4 violation — DefaultStageDefs[StageCoder] still lists Script or Helpers.\n' >&2
    printf '  Coder is Go-native — drop both fields; GoImpl is the only valid entry.\n' >&2
    companion_failures=$(( companion_failures + 1 ))
fi

# m39.4 closeout: the pipeline-stage subset of stages/ MUST be empty after
# m39. Any new bash stage script is a regression — new stages land under
# internal/stages/<name>/ from day one. The planning files
# (stages/plan_*.sh, stages/init_synthesize.sh) are NOT pipeline stages
# and are exempt; the audit allowlists them by pattern.
_stage_bash_unexpected=()
while IFS= read -r _f; do
    [[ -z "$_f" ]] && continue
    case "$(basename -- "$_f")" in
        plan_*.sh|init_synthesize.sh)
            # Planning + init-synthesis helpers — not pipeline stages.
            ;;
        *)
            _stage_bash_unexpected+=("$_f")
            ;;
    esac
done < <(find stages -maxdepth 1 -name '*.sh' 2>/dev/null | sort)
if (( ${#_stage_bash_unexpected[@]} > 0 )); then
    printf 'wedge-audit: m39.4 violation — unexpected pipeline-stage bash file(s) in stages/:\n' >&2
    printf '  %s\n' "${_stage_bash_unexpected[@]}" >&2
    printf 'After m39.4, every pipeline stage lives in internal/stages/<name>/.\n' >&2
    printf 'New stages must NOT land in stages/ — they go straight to Go.\n' >&2
    companion_failures=$(( companion_failures + 1 ))
fi
unset _stage_bash_unexpected _f
