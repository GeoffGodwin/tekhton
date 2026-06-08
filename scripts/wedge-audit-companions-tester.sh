#!/usr/bin/env bash
# scripts/wedge-audit-companions-tester.sh — m38 tester-arc presence checks.
#
# Sourced by scripts/wedge-audit-companions.sh. Extracted to keep the parent
# file under the 300-line bash ceiling (CLAUDE.md Rule 8). Holds the m38.4
# (test_audit family), m38.5 (test_baseline), and m38.6 (tester stage)
# violation gates — together the m38 closure assertions.
#
# Sourced — do not run directly. Caller (wedge-audit-companions.sh) is
# already under `set -euo pipefail` and runs from the repo root.

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
    # shellcheck disable=SC2016  # backticks in error text are literal strings, not subshells
    printf '`tekhton test-audit run|run-standalone`.\n' >&2
    companion_failures=$(( companion_failures + 1 ))
fi
unset _ta_re

# m38.5: lib/test_baseline.sh ported to internal/test_baseline/. Re-introducing
# the bash file silently forks the baseline contract (M92 PassOnPreexisting=false).
if [[ -f lib/test_baseline.sh ]]; then
    printf 'wedge-audit: m38.5 violation — lib/test_baseline.sh was ported in m38.5.\n' >&2
    printf 'Baseline subsystem lives in internal/test_baseline/; CLI: tekhton baseline.\n' >&2
    companion_failures=$(( companion_failures + 1 ))
fi

# m38.6 (Phase 5, tester-arc): the six stages/tester*.sh files ported to
# internal/stages/tester/. Re-introducing any of them silently forks the
# tester-stage contract and breaks the StageDef.GoImpl dispatch precedence
# the m38 arc closes. The TDD pre-flight (m38.2), validation/timing
# helpers (m38.1), fix + continuation loops (m38.3), test_audit (m38.4),
# and test_baseline (m38.5) all reach into internal/tester,
# internal/test_audit, and internal/test_baseline in-process.
_tester_re=$(find stages -maxdepth 1 -name 'tester*.sh' -print 2>/dev/null)
if [[ -n "$_tester_re" ]]; then
    printf 'wedge-audit: m38.6 violation — stages/tester*.sh file(s) re-introduced:\n' >&2
    printf '%s\n' "$_tester_re" >&2
    printf 'The tester stage lives in internal/stages/tester/; sub-stage helpers in\n' >&2
    printf 'internal/tester/ (timing, validation, fix, continuation) and the TDD\n' >&2
    printf 'pre-flight in internal/tester/tdd/. Bash callers reach it via the\n' >&2
    printf 'StageDef.GoImpl dispatch wedge in internal/stagerunner/.\n' >&2
    companion_failures=$(( companion_failures + 1 ))
fi
unset _tester_re

# m38.6 (Phase 5): assert StageTester carries GoImpl and NOT Helpers. A
# Helpers entry would cause a 127 exit if any fallback path ever reaches
# bash (the six bash files are deleted).
if grep -nE 'StageTester' internal/stagerunner/helpers.go | grep -E 'Script:|Helpers:' >/dev/null 2>&1; then
    printf 'wedge-audit: m38.6 violation — DefaultStageDefs[StageTester] still lists Script or Helpers.\n' >&2
    printf '  Tester is Go-native — drop both fields; GoImpl is the only valid entry.\n' >&2
    companion_failures=$(( companion_failures + 1 ))
fi
