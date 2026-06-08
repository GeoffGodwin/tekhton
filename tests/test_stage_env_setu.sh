#!/usr/bin/env bash
# tests/test_stage_env_setu.sh — m27.3 env-contract parity test.
#
# What this catches that scripts/audit-bash-env.sh does not: contract-variable
# reads that the static audit cannot resolve — variables read via `eval`,
# dynamically-constructed names, files only sourced at runtime, helpers
# imported transitively from another sourced file. The static audit greps
# for the literal lexical form; this test exercises real bash subprocesses
# under `set -euo pipefail` and reports any "unbound variable" trip.
#
# Approach
# --------
# Drives `tekhton run-stage <name>` for each stage in
# `internal/runner/single.go::defaultStageOrder()`. Each invocation spawns
# the same bash subprocess the production runner does (lib/common.sh + the
# DefaultLibHelpers source block + per-stage Helpers + lib/stage_envelope.sh
# + the stage script), with `set -euo pipefail` active throughout.
#
# Agent invocations are short-circuited via `TEKHTON_AGENT_BINARY` pointed
# at `testdata/fake_agent.sh` (mode=happy), so the test runs in well under
# 10 seconds even with five stage subprocesses. A stage that exits non-zero
# downstream of the source step is fine — the surface under test is
# subprocess startup. The negative signal is detected two ways:
#
#  1. Subprocess stderr contains "unbound variable" (definitive trip).
#  2. The per-stage env dump file at /tmp/tekhton_stage_env_<stage>_post.txt
#     is absent — that dump runs AFTER the source block, so its absence
#     means `set -u` aborted the wrapper before the dump line executed.
#
# Sanity check (do NOT commit a regression)
# -----------------------------------------
# To validate this test catches what it claims to catch, temporarily revert
# one `${VAR:-default}` guard in a sourced lib file (e.g.
# `lib/hooks_final_checks.sh` — pick any `${VAR:-default}` read and strip the default),
# rerun this test, and verify it exits 1 with the offending file in the
# error message. Restore the guard before committing. The m27.3 milestone's
# acceptance criteria document this check; it is intentionally not
# automated because it would otherwise commit a transient regression.
#
# Stale-file hygiene
# ------------------
# /tmp/tekhton_stage_env_*_post.txt is written by the stagerunner adapter
# (`internal/stagerunner/adapter.go::buildBashScript`) and overwritten on
# each run, but never cleaned between runs. We `rm -f` at start so a stale
# file from a previous run can't mask a missing-post-file signal.

set -euo pipefail

TEKHTON_HOME_RESOLVED="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_BIN="${TEKHTON_BIN:-${TEKHTON_HOME_RESOLVED}/bin/tekhton}"
FIXTURE_ROOT="${TEKHTON_HOME_RESOLVED}/tests/testdata/env_contract"
FAKE_AGENT="${TEKHTON_HOME_RESOLVED}/testdata/fake_agent.sh"

# Skip cleanly when the binary isn't built — contributors who haven't run
# `make build` aren't blocked. CI builds the binary via `make dogfood`
# before this test runs.
if [[ ! -x "$TEKHTON_BIN" ]]; then
    echo "SKIP: tekhton binary not built (run 'make build' first)"
    exit 0
fi
if [[ ! -x "$FAKE_AGENT" ]]; then
    echo "SKIP: testdata/fake_agent.sh missing (unexpected — repo state error)"
    exit 0
fi
if [[ ! -d "$FIXTURE_ROOT" ]]; then
    echo "SKIP: tests/testdata/env_contract fixture missing (unexpected)"
    exit 0
fi

WORKDIR="$(mktemp -d -t tekhton-env-setu-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
cp -R "${FIXTURE_ROOT}/." "${WORKDIR}/"

# Wipe stale stagerunner env dumps so a previous run's data can't mask a
# missing-post-file signal in this run.
rm -f /tmp/tekhton_stage_env_*_post.txt /tmp/tekhton_stage_env_*_pre.txt

# Short-circuit agent invocations: point the supervisor's agent binary
# at the existing fake_agent.sh (happy mode emits two turns + exits 0).
# Even when a stage exits non-zero downstream of the agent call, every
# `lib/*.sh` and `stages/*.sh` is sourced FIRST — that's the surface the
# parity test exercises.
export TEKHTON_AGENT_BINARY="$FAKE_AGENT"
export FAKE_AGENT_MODE=happy

# m47 gated the per-stage env dump behind TEKHTON_DEBUG_ENV (credential
# exposure in /tmp). Signal 2 below depends on the post-source dump file
# existing, so opt in explicitly. The dump path is /tmp/tekhton_stage_env_*
# and is written by internal/stagerunner/adapter.go (dumpStageEnvPreExec +
# the post-source `env | sort > ...` line in buildBashScript).
export TEKHTON_DEBUG_ENV=1

# defaultStageOrder() in internal/runner/single.go, restricted to the
# stages whose adapter is still the BashAdapter. Go-native stages (docs
# m34.1, cleanup m34.2, security m35.2, architect m36.1, intake m36.3,
# review m37.2, tester m38.6) bypass the bash source chain so the
# env-dump signal would never fire for them — they belong in the Go
# stage-port test suites, not here.
# Keep in sync — the milestone Watch For warns about silent coverage
# gaps if a stage isn't exercised here but still has a bash adapter.
STAGES=(coder)
RUN_STDERR="${WORKDIR}/all_stderr.log"
: > "$RUN_STDERR"

for stage in "${STAGES[@]}"; do
    req="${WORKDIR}/.claude/req-${stage}.json"
    res="${WORKDIR}/.claude/res-${stage}.json"
    log="${WORKDIR}/.claude/${stage}.log"
    cat > "$req" <<EOF
{
  "proto": "tekhton.stage.request.v1",
  "stage": "${stage}",
  "task": "m27.3 env-contract parity probe",
  "milestone": "m27test",
  "result_file": "${res}",
  "log_file": "${log}"
}
EOF
    # rc != 0 is expected (e.g. coder exits 1 with no real agent output).
    # The test only fails on unbound-variable trips, not stage failures.
    "$TEKHTON_BIN" run-stage "$stage" \
        --request-file "$req" \
        --project-dir "$WORKDIR" \
        --tekhton-home "$TEKHTON_HOME_RESOLVED" \
        >/dev/null 2>>"$RUN_STDERR" || true
done

# Signal 1: subprocess stderr scanned for the bash "unbound variable" message.
# Use `|| true` because grep returns 1 on zero matches under set -e.
unbound_count=$(grep -c 'unbound variable' "$RUN_STDERR" 2>/dev/null || true)
unbound_count="${unbound_count:-0}"
if (( unbound_count > 0 )); then
    echo "FAIL: detected ${unbound_count} unbound-variable trip(s) across stage subprocesses" >&2
    echo "--- offending lines (from ${RUN_STDERR}) ---" >&2
    grep -n 'unbound variable' "$RUN_STDERR" | head -20 >&2
    exit 1
fi

# Signal 2: every stage reached the env-dump step (post.txt written). If
# any post.txt is missing, the source block tripped `set -u` BEFORE the
# dump line — the dump is the last line of the wrapper before the stage
# entry call.
missing=()
for stage in "${STAGES[@]}"; do
    [[ -f "/tmp/tekhton_stage_env_${stage}_post.txt" ]] || missing+=("$stage")
done
if (( ${#missing[@]} > 0 )); then
    echo "FAIL: stage(s) did not reach env-dump step (source block aborted): ${missing[*]}" >&2
    echo "--- relevant stderr ---" >&2
    tail -50 "$RUN_STDERR" >&2
    exit 1
fi

echo "PASS: no unbound-variable trips across ${#STAGES[@]} stage subprocesses"
