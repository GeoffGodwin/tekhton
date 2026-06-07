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

# m34.1 (Phase 5, stage-port arc): stages/docs.sh + lib/docs_agent.sh ported
# to internal/stages/docs/. Re-introducing either file silently forks the
# docs-stage contract and breaks the StageDef.GoImpl dispatch precedence the
# m34 arc inherits.
if [[ -f stages/docs.sh ]] || [[ -f lib/docs_agent.sh ]]; then
    printf 'wedge-audit: m34.1 violation — docs stage was ported in m34.1:\n' >&2
    [[ -f stages/docs.sh ]] && printf '  stages/docs.sh re-introduced\n' >&2
    [[ -f lib/docs_agent.sh ]] && printf '  lib/docs_agent.sh re-introduced\n' >&2
    printf 'The docs stage lives in internal/stages/docs/. Bash callers reach\n' >&2
    printf 'it via the StageDef.GoImpl dispatch wedge in internal/stagerunner/.\n' >&2
    companion_failures=$(( companion_failures + 1 ))
fi

# m34.2 (Phase 5, stage-port arc): stages/cleanup.sh ported to
# internal/stages/cleanup/. Re-introducing the file silently forks the
# cleanup-stage contract and breaks the StageDef.GoImpl dispatch
# precedence. The four helpers it called (select_cleanup_batch,
# mark_note_resolved, mark_note_deferred, count_unresolved_notes) live
# in internal/notes/cleanup.go as Go functions.
if [[ -f stages/cleanup.sh ]]; then
    printf 'wedge-audit: m34.2 violation — cleanup stage was ported in m34.2:\n' >&2
    printf '  stages/cleanup.sh re-introduced\n' >&2
    printf 'The cleanup stage lives in internal/stages/cleanup/. Bash callers reach\n' >&2
    printf 'it via the StageDef.GoImpl dispatch wedge in internal/stagerunner/.\n' >&2
    companion_failures=$(( companion_failures + 1 ))
fi

# m35.3 (Phase 5, stage-port arc): stages/security.sh + lib/security_helpers.sh
# ported to internal/stages/security/ + internal/security/ across m35.1 and
# m35.2. Re-introducing either file silently forks the security-stage
# contract and breaks the StageDef.GoImpl dispatch precedence. The nine
# helper functions (_parse_security_findings, _severity_meets_threshold,
# _build_fixable_block, _build_unfixable_block, _build_notes_block,
# _handle_unfixable_findings, _write_security_notes, _security_is_docs_only,
# _has_blocking_findings) are Go functions in internal/security/.
if [[ -f stages/security.sh ]] || [[ -f lib/security_helpers.sh ]]; then
    printf 'wedge-audit: m35.3 violation — security stage was ported in m35.1/m35.2:\n' >&2
    [[ -f stages/security.sh ]] && printf '  stages/security.sh re-introduced\n' >&2
    [[ -f lib/security_helpers.sh ]] && printf '  lib/security_helpers.sh re-introduced\n' >&2
    printf 'The security stage lives in internal/stages/security/; helpers in\n' >&2
    printf 'internal/security/. Bash callers reach it via the StageDef.GoImpl\n' >&2
    printf 'dispatch wedge in internal/stagerunner/.\n' >&2
    companion_failures=$(( companion_failures + 1 ))
fi

# m35.3 (Phase 5): the nine deleted security helper function names. Any
# lib/ or stages/ file that mentions them risks silently resurrecting the
# pre-m35 logic. Files needing to reference the names in comments may opt
# out by including the literal marker `--m35-allowlist` anywhere.
_sec_fns='_parse_security_findings|_severity_meets_threshold|_build_fixable_block'
_sec_fns+='|_build_unfixable_block|_build_notes_block|_handle_unfixable_findings'
_sec_fns+='|_write_security_notes|_security_is_docs_only|_has_blocking_findings'
_sec_fn_hits=$(grep -rEl "($_sec_fns)" lib stages 2>/dev/null || true)
if [[ -n "$_sec_fn_hits" ]]; then
    _sec_fn_violations=""
    while IFS= read -r _hit; do
        [[ -z "$_hit" ]] && continue
        if ! grep -qF -- '--m35-allowlist' "$_hit" 2>/dev/null; then
            _sec_fn_violations+="  $_hit"$'\n'
        fi
    done <<< "$_sec_fn_hits"
    if [[ -n "$_sec_fn_violations" ]]; then
        printf 'wedge-audit: m35.3 violation — deleted security bash function name(s) reappeared:\n' >&2
        printf '%s' "$_sec_fn_violations" >&2
        printf 'Use the Go helpers in internal/security/ in process, or the operator CLI\n' >&2
        # shellcheck disable=SC2016  # backticks/markers are literal strings, not subshells
        printf 'tekhton security <sub> (parse-findings, meets-threshold). If a comment\n' >&2
        # shellcheck disable=SC2016
        printf 'legitimately needs the function name, add `# --m35-allowlist` to the file.\n' >&2
        companion_failures=$(( companion_failures + 1 ))
    fi
    unset _sec_fn_violations _hit
fi
unset _sec_fns _sec_fn_hits

# m36.1 (Phase 5, stage-port arc): stages/architect.sh ported to
# internal/stages/architect/. Re-introducing the file silently forks the
# architect-stage contract and breaks the StageDef.GoImpl dispatch
# precedence. The drift integration (DRIFT_LOG.md / ARCHITECTURE_LOG.md /
# HUMAN_ACTION_REQUIRED.md writes) is owned by internal/drift/ (m25) —
# direct os.WriteFile against those paths from internal/stages/architect/
# bypasses the file-format contract.
if [[ -f stages/architect.sh ]]; then
    printf 'wedge-audit: m36.1 violation — architect stage was ported in m36.1:\n' >&2
    printf '  stages/architect.sh re-introduced\n' >&2
    printf 'The architect stage lives in internal/stages/architect/. Bash callers reach\n' >&2
    printf 'it via the StageDef.GoImpl dispatch wedge in internal/stagerunner/.\n' >&2
    companion_failures=$(( companion_failures + 1 ))
fi

# m36.1 (Phase 5): the architect stage MUST route drift-owned writes
# through internal/drift/ (M25 owns the file format). Direct os.WriteFile
# / os.Create against DRIFT_LOG.md / ARCHITECTURE_LOG.md /
# HUMAN_ACTION_REQUIRED.md from internal/stages/architect/ forks the
# contract.
if [[ -d internal/stages/architect ]]; then
    # Skip _test.go — test fixtures legitimately seed DRIFT_LOG.md in temp
    # dirs. The contract is about *production* writes from the package.
    _arch_drift_hits=$(grep -rlE 'os\.(WriteFile|Create)' internal/stages/architect \
        --include='*.go' --exclude='*_test.go' 2>/dev/null \
        | xargs -r grep -lE 'ARCHITECTURE_LOG|DRIFT_LOG|HUMAN_ACTION_REQUIRED' 2>/dev/null || true)
    if [[ -n "$_arch_drift_hits" ]]; then
        printf 'wedge-audit: m36.1 violation — internal/stages/architect/ writes drift-owned files directly:\n' >&2
        printf '%s\n' "$_arch_drift_hits" >&2
        printf 'Use internal/drift/ entrypoints (M25 owns the file format).\n' >&2
        companion_failures=$(( companion_failures + 1 ))
    fi
    unset _arch_drift_hits
fi

# m36.3 (Phase 5, stage-port arc): stages/intake.sh + lib/intake_helpers.sh +
# lib/intake_verdict_handlers.sh ported to internal/stages/intake/ +
# internal/intake/ across m36.2 and m36.3. Re-introducing any of the three
# bash files silently forks the intake-stage contract and breaks the
# StageDef.GoImpl dispatch precedence. The verdict-handler operator strings
# and the helper API surface live in internal/intake/{helpers,verdict}.go;
# the stage entry lives in internal/stages/intake/intake.go.
for _intake_bash in stages/intake.sh lib/intake_helpers.sh lib/intake_verdict_handlers.sh; do
    if [[ -f "$_intake_bash" ]]; then
        printf 'wedge-audit: m36.3 violation — %s was ported in m36.2/m36.3:\n' "$_intake_bash" >&2
        printf '  %s re-introduced\n' "$_intake_bash" >&2
        printf 'The intake stage lives in internal/stages/intake/; helpers in\n' >&2
        printf 'internal/intake/. Bash callers reach it via the StageDef.GoImpl\n' >&2
        printf 'dispatch wedge in internal/stagerunner/.\n' >&2
        companion_failures=$(( companion_failures + 1 ))
    fi
done
unset _intake_bash

# m36.3 (Phase 5): assert StageIntake carries GoImpl and NOT Helpers. A
# Helpers entry would cause a 127 exit if any fallback path ever reaches
# bash (the three bash helpers are deleted).
if grep -nE 'StageIntake' internal/stagerunner/helpers.go | grep -E 'Script:|Helpers:' >/dev/null 2>&1; then
    printf 'wedge-audit: m36.3 violation — DefaultStageDefs[StageIntake] still lists Script or Helpers.\n' >&2
    printf '  Intake is Go-native — drop both fields; GoImpl is the only valid entry.\n' >&2
    companion_failures=$(( companion_failures + 1 ))
fi

# m36.3 (Phase 5): INTAKE_CLARITY_THRESHOLD must NOT be enforced by
# Go-side gate logic — the threshold goes into the prompt template only.
# A `<` or `>=` comparison would double-gate and break the agent contract.
if [[ -d internal/stages/intake ]] || [[ -d internal/intake ]]; then
    _intake_threshold_hits=$(grep -rEl 'INTAKE_CLARITY_THRESHOLD' internal/stages/intake internal/intake 2>/dev/null || true)
    if [[ -n "$_intake_threshold_hits" ]]; then
        printf 'wedge-audit: m36.3 violation — INTAKE_CLARITY_THRESHOLD referenced in Go intake code:\n' >&2
        printf '%s\n' "$_intake_threshold_hits" >&2
        printf 'The threshold belongs in the intake_scan prompt template only;\n' >&2
        printf 'Go-side gate enforcement would double-gate the agent contract.\n' >&2
        companion_failures=$(( companion_failures + 1 ))
    fi
    unset _intake_threshold_hits
fi

# m37.2 (Phase 5, stage-port arc): stages/review.sh + stages/review_helpers.sh
# ported to internal/stages/review/ on top of the m37.1 internal/review/ leaf
# package. Re-introducing either bash file silently forks the review-stage
# contract and breaks the StageDef.GoImpl dispatch precedence the m37 arc
# closes. The parser, cycle budget, and specialist helpers live in
# internal/review/ (m37.1); the stage entry + cycle loop + rework matrix +
# post-loop specialist branch live in internal/stages/review/ (m37.2).
for _review_bash in stages/review.sh stages/review_helpers.sh; do
    if [[ -f "$_review_bash" ]]; then
        printf 'wedge-audit: m37.2 violation — %s was ported in m37.2:\n' "$_review_bash" >&2
        printf '  %s re-introduced\n' "$_review_bash" >&2
        printf 'The review stage lives in internal/stages/review/; pure-logic helpers in\n' >&2
        printf 'internal/review/. Bash callers reach it via the StageDef.GoImpl\n' >&2
        printf 'dispatch wedge in internal/stagerunner/.\n' >&2
        companion_failures=$(( companion_failures + 1 ))
    fi
done
unset _review_bash

# m37.2 (Phase 5): assert StageReview carries GoImpl and NOT Helpers. A
# Helpers entry would cause a 127 exit if any fallback path ever reaches
# bash (both bash files are deleted).
if grep -nE 'StageReview' internal/stagerunner/helpers.go | grep -E 'Script:|Helpers:' >/dev/null 2>&1; then
    printf 'wedge-audit: m37.2 violation — DefaultStageDefs[StageReview] still lists Script or Helpers.\n' >&2
    printf '  Review is Go-native — drop both fields; GoImpl is the only valid entry.\n' >&2
    companion_failures=$(( companion_failures + 1 ))
fi

# m38.4 (Phase 5, tester-arc): the six lib/test_audit*.sh files ported
# to internal/test_audit/. Re-introducing any of them silently forks the
# test-audit contract and bypasses the native Go orchestrator. The
# bash callers (run_test_audit shim in tekhton-legacy.sh, --audit-tests
# CLI block) exec the Go binary; reintroducing the bash subsystem would
# create a duplicate path with no guarantee of parity.
_ta_re=$(find lib -maxdepth 1 -name 'test_audit*.sh' -print 2>/dev/null)
if [[ -n "$_ta_re" ]]; then
    printf 'wedge-audit: m38.4 violation — lib/test_audit*.sh file(s) re-introduced:\n' >&2
    printf '%s\n' "$_ta_re" >&2
    printf 'The test-audit subsystem lives in internal/test_audit/. Bash callers\n' >&2
    printf 'reach it via the run_test_audit shim (tekhton-legacy.sh) which execs\n' >&2
    printf '`tekhton test-audit run|run-standalone`.\n' >&2
    companion_failures=$(( companion_failures + 1 ))
fi
unset _ta_re

if (( companion_failures > 0 )); then
    printf 'wedge-audit: %d companion-tool assertion(s) failed.\n' "$companion_failures" >&2
    exit 1
fi
