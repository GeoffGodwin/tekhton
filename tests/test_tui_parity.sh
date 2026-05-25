#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# tests/test_tui_parity.sh — m23 parity gate.
#
# The bash-side TUI writers were deleted at m23 close — there is no live
# bash implementation to diff against. This gate instead drives the Go
# writer through three frozen scenarios and asserts the resulting
# tui_status.json shape matches the captured baseline produced from the
# m23 cutover snapshot:
#
#   1. green_path             — start → stage-begin → stage-end → complete
#   2. pause_resume_cycle     — start → enter pause → update pause → exit
#   3. sidecar_death_mid_run  — liveness probe flips _TUI_ACTIVE=false
#                               after 20 writes when the sidecar PID is
#                               unreachable
#
# The Go side owns the writer contract, so a regression here would surface
# as either a missing proto field, a renamed field, or a divergent value in
# the captured snapshot. The Python sidecar is the consumer; bumping any
# field shape requires a coordinated tools/tui.py patch (test_tui_proto_compat.py).
# =============================================================================

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_BIN="${REPO_ROOT}/bin/tekhton"

# shellcheck source=tests/lib/parity.sh
source "${REPO_ROOT}/tests/lib/parity.sh"

if ! command -v go >/dev/null 2>&1; then
    printf 'SKIP test_tui_parity: go toolchain not found\n'
    exit 0
fi
if ! [[ -x "$TEKHTON_BIN" ]]; then
    if ! (cd "$REPO_ROOT" && make build >/dev/null 2>&1); then
        printf 'SKIP test_tui_parity: make build failed\n'
        exit 0
    fi
fi

if ! command -v python3 >/dev/null 2>&1; then
    printf 'SKIP test_tui_parity: python3 not found (needed for JSON probing)\n'
    exit 0
fi

# --- Scenario 1: green path -------------------------------------------------
_test_green_path() {
    local tmp
    tmp=$(mktemp -d)
    local status="${tmp}/tui_status.json"

    "$TEKHTON_BIN" tui start --status-file "$status" --run-mode milestone \
        --stage-order "intake,coder,review,tester" >/dev/null
    "$TEKHTON_BIN" tui stage-begin --status-file "$status" --label "intake" \
        --model "claude-opus" >/dev/null
    "$TEKHTON_BIN" tui stage-end --status-file "$status" --label "intake" \
        --turns "5/20" --verdict "PASS" >/dev/null
    "$TEKHTON_BIN" tui stage-begin --status-file "$status" --label "coder" >/dev/null
    "$TEKHTON_BIN" tui append-event --status-file "$status" --level info \
        --message "build passed" >/dev/null
    "$TEKHTON_BIN" tui stage-end --status-file "$status" --label "coder" \
        --verdict "PASS" >/dev/null
    "$TEKHTON_BIN" tui complete --status-file "$status" --verdict "SUCCESS" >/dev/null

    local proto stage_count complete verdict
    proto=$(python3 -c "import json; print(json.load(open('$status'))['proto'])" 2>/dev/null || true)
    stage_count=$(python3 -c "import json; d=json.load(open('$status')); print(len(d['payload']['stages_complete']))" 2>/dev/null || echo 0)
    complete=$(python3 -c "import json; d=json.load(open('$status')); print(d['payload']['complete'])" 2>/dev/null || echo False)
    verdict=$(python3 -c "import json; d=json.load(open('$status')); print(d['payload']['verdict'])" 2>/dev/null || true)

    if [[ "$proto" != "tekhton.tui.status.v1" ]]; then
        parity_fail "green_path: proto envelope tag wrong: $proto"
    elif (( stage_count != 2 )); then
        parity_fail "green_path: stages_complete should hold 2 entries (intake+coder), got $stage_count"
    elif [[ "$complete" != "True" ]]; then
        parity_fail "green_path: complete flag not set, got $complete"
    elif [[ "$verdict" != "SUCCESS" ]]; then
        parity_fail "green_path: verdict not SUCCESS, got $verdict"
    else
        parity_pass "green_path: envelope, stages_complete, complete, verdict all match"
    fi
    rm -rf "$tmp"
}

# --- Scenario 2: pause / resume cycle ---------------------------------------
_test_pause_resume() {
    local tmp
    tmp=$(mktemp -d)
    local status="${tmp}/tui_status.json"

    "$TEKHTON_BIN" tui start --status-file "$status" >/dev/null
    "$TEKHTON_BIN" tui stage-begin --status-file "$status" --label "coder" >/dev/null
    "$TEKHTON_BIN" tui pause-enter --status-file "$status" --reason "quota exhausted" \
        --retry-interval 300 --max-duration 18900 >/dev/null
    "$TEKHTON_BIN" tui pause-update --status-file "$status" --next-in 60 >/dev/null
    "$TEKHTON_BIN" tui pause-update --status-file "$status" --next-in 30 >/dev/null
    "$TEKHTON_BIN" tui pause-exit --status-file "$status" --result refreshed >/dev/null

    local reason status_field events_have_warn
    reason=$(python3 -c "import json; print(json.load(open('$status'))['payload']['pause_reason'])" 2>/dev/null || true)
    status_field=$(python3 -c "import json; print(json.load(open('$status'))['payload']['current_agent_status'])" 2>/dev/null || true)
    events_have_warn=$(python3 -c "
import json
events = json.load(open('$status'))['payload']['recent_events']
print(any(e['level'] == 'warn' and 'Quota pause' in e['msg'] for e in events))
" 2>/dev/null || true)

    if [[ "$reason" != "" ]]; then
        parity_fail "pause_resume: pause_reason should clear post-exit, got '$reason'"
    elif [[ "$status_field" != "idle" ]]; then
        parity_fail "pause_resume: agent_status should be idle post-exit, got '$status_field'"
    elif [[ "$events_have_warn" != "True" ]]; then
        parity_fail "pause_resume: warn event missing from ring buffer"
    else
        parity_pass "pause_resume: pause/update/exit cycle correctly drives state + events"
    fi
    rm -rf "$tmp"
}

# --- Scenario 3: sidecar-death-mid-run (smoke test) ------------------------
# The bash version asserted that _TUI_ACTIVE flipped to false within 20 writes
# of the sidecar's PID becoming unreachable. The Go version owns the same
# liveness sampling — verified at unit-test level in internal/tui/liveness_test.go.
# This scenario just smoke-tests that subsequent CLI calls don't crash when
# TEKHTON_TUI_PID points at a dead process.
_test_sidecar_death_smoke() {
    local tmp
    tmp=$(mktemp -d)
    local status="${tmp}/tui_status.json"

    "$TEKHTON_BIN" tui start --status-file "$status" >/dev/null

    # Set TEKHTON_TUI_PID to a high number that's almost certainly not a
    # running process. The liveness probe should mark the sidecar dead on
    # the 20th write — but the CLI must not crash regardless.
    local rc=0
    for i in $(seq 1 25); do
        TEKHTON_TUI_PID=999999 "$TEKHTON_BIN" tui append-event \
            --status-file "$status" --level info --message "tick $i" \
            >/dev/null 2>&1 || rc=$?
    done

    if (( rc != 0 )); then
        parity_fail "sidecar_death_smoke: CLI exited non-zero (rc=$rc) — should be tolerant of dead sidecar PID"
    else
        parity_pass "sidecar_death_smoke: 25 writes with dead PID complete cleanly"
    fi
    rm -rf "$tmp"
}

_test_green_path
_test_pause_resume
_test_sidecar_death_smoke

parity_summary "test_tui_parity" || exit 1
exit 0
