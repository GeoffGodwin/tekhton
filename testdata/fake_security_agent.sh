#!/usr/bin/env bash
# =============================================================================
# testdata/fake_security_agent.sh — m35.3 fake supervisor binary for the
# security parity gate (tests/test_security_parity.sh).
#
# Drives `tekhton run-stage security` without an upstream model. Emits two
# turn events to stdout (so the Go supervisor sees activity and exits clean),
# then optionally writes SECURITY_REPORT.md content based on three env vars:
#
#   FAKE_SECURITY_SCENARIO   — pass-no-findings | fixable-cycle-1-resolved
#                              | unfixable-escalate
#   FAKE_SECURITY_REPORT     — absolute path to SECURITY_REPORT.md
#                              (default: <cwd>/.tekhton/SECURITY_REPORT.md)
#   FAKE_SECURITY_COUNTER    — absolute path to a counter file the fake
#                              increments on each invocation, used by the
#                              fixable-cycle-1-resolved scenario to know
#                              "this is call N, write the cycle-N content".
#                              (default: <cwd>/.tekhton/_fake_sec_counter)
#
# Scenario behavior (post-event-emission):
#   pass-no-findings           — does NOT write the report; the Go stage's
#                                ParseReport sees a missing file → noFindings.
#   unfixable-escalate         — writes a HIGH unfixable finding; default
#                                policy=escalate → HumanAction emission.
#   fixable-cycle-1-resolved   — call 1: writes HIGH fixable; call 2+: writes
#                                an empty `## Findings` block so the loop
#                                exits clean after the post-rework re-scan.
#
# All output is line-buffered for the supervisor's bufio.Scanner.
# =============================================================================
set -euo pipefail

scenario="${FAKE_SECURITY_SCENARIO:-pass-no-findings}"
report="${FAKE_SECURITY_REPORT:-$PWD/.tekhton/SECURITY_REPORT.md}"
counter_file="${FAKE_SECURITY_COUNTER:-$PWD/.tekhton/_fake_sec_counter}"

emit() {
    printf '%s\n' "$1"
}

# Two-turn happy event stream — matches testdata/fake_agent.sh shape so the
# supervisor's decoder treats each call as a successful "happy" agent run.
emit '{"type":"turn_started","turn":1}'
emit '{"type":"turn_ended","turn":1}'
emit '{"type":"turn_started","turn":2}'
emit '{"type":"turn_ended","turn":2}'

# Increment the counter file so the fixable scenario can branch on call#.
mkdir -p -- "$(dirname -- "$counter_file")"
n=0
if [[ -f "$counter_file" ]]; then
    n=$(cat -- "$counter_file" 2>/dev/null || printf '0')
fi
n=$(( n + 1 ))
printf '%s' "$n" > "$counter_file"

mkdir -p -- "$(dirname -- "$report")"

case "$scenario" in
    pass-no-findings)
        # Do NOT write SECURITY_REPORT.md. The Go stage's ParseReport returns
        # (nil, nil) on a missing file → noFindings=true → exit=no_findings.
        :
        ;;
    unfixable-escalate)
        cat > "$report" <<'EOF'
# Security Review

## Findings

- [HIGH] [fixable:no] hardcoded credential in src/auth/keys.go:42

## Notes

This is a fake-agent fixture for the m35.3 parity gate.
EOF
        ;;
    fixable-cycle-1-resolved)
        if (( n <= 1 )); then
            cat > "$report" <<'EOF'
# Security Review

## Findings

- [HIGH] [fixable:yes] missing input validation in src/api/handler.go:88

## Notes

Cycle 1 — fixable HIGH that the rework agent will address.
EOF
        else
            cat > "$report" <<'EOF'
# Security Review

## Findings

## Notes

Cycle 2 — prior fix verified; no remaining findings.
EOF
        fi
        ;;
    *)
        printf 'fake_security_agent.sh: unknown scenario %q\n' "$scenario" >&2
        exit 64
        ;;
esac

exit 0
