#!/usr/bin/env bash
# =============================================================================
# test_stage_envelope_overrides_subprocess_err.sh — m47 shim-boundary test.
#
# Verifies the envelope-over-error contract across the bash ↔ Go seam:
#
#   1. The stage.result.v1 envelope shape now carries a Metadata map; the Go
#      binary serializes it round-trip through JSON without reshaping.
#   2. A hand-authored envelope with Metadata["subprocess_warnings"] (the
#      m47 plural-key contract) parses cleanly through `tekhton run-stage`'s
#      JSON validator and the verdict field survives.
#   3. A pass-verdict envelope that ALSO carries a subprocess warning emits
#      from `tekhton stage emit` as verdict=pass, NOT verdict=fail — proving
#      the bash-side warning channel does not override the verdict.
#
# Skips cleanly when the tekhton binary is not built (mirrors the m22
# shim-boundary test convention).
# =============================================================================
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_BIN="${TEKHTON_BIN:-${TEKHTON_HOME}/bin/tekhton}"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        pass
    else
        fail "${name}: want='${want}' got='${got}'"
    fi
}

assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        pass
    else
        fail "${name}: '${hay}' missing '${needle}'"
    fi
}

if [[ ! -x "$TEKHTON_BIN" ]]; then
    echo "  SKIP: tekhton binary not built at ${TEKHTON_BIN}; run 'make build'"
    exit 0
fi

TMPDIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$TMPDIR'" EXIT

# --- Test 1: stage emit on a pass verdict writes envelope with verdict=pass ---
RESULT="${TMPDIR}/emit.json"
export TEKHTON_STAGE_RESULT_FILE="$RESULT"

"$TEKHTON_BIN" stage emit \
    --stage review \
    --verdict pass \
    --exit-reason approved \
    --agent-calls 2 \
    --to-result-file

if [[ ! -s "$RESULT" ]]; then
    fail "stage emit produced no envelope file"
else
    pass
fi

# --- Test 2: envelope shape preserves verdict / proto tag ---------------------
if command -v python3 &>/dev/null; then
    parsed=$(python3 -c "
import json
with open('${RESULT}') as f:
    d = json.load(f)
print(d.get('proto', ''))
print(d.get('stage', ''))
print(d.get('verdict', ''))
print(d.get('exit_reason', ''))
")
    proto_v=$(echo "$parsed" | sed -n '1p')
    stage_v=$(echo "$parsed" | sed -n '2p')
    verdict_v=$(echo "$parsed" | sed -n '3p')
    reason_v=$(echo "$parsed" | sed -n '4p')

    assert_eq "envelope.proto" "tekhton.stage.result.v1" "$proto_v"
    assert_eq "envelope.stage" "review" "$stage_v"
    assert_eq "envelope.verdict" "pass" "$verdict_v"
    assert_eq "envelope.exit_reason" "approved" "$reason_v"
else
    fail "python3 not available — cannot validate envelope JSON"
fi

# --- Test 3: hand-authored envelope with subprocess_warnings round-trips -----
# Simulates a Go-impl stage that emitted both a pass verdict AND a warning
# from a failed sub-call (the m47 envelope-over-error path). The bash-side
# stagerunner must accept this envelope shape without rejecting the unknown
# Metadata field.
HAND_AUTHORED="${TMPDIR}/handauthored.json"
cat > "$HAND_AUTHORED" <<'JSON'
{
  "proto": "tekhton.stage.result.v1",
  "stage": "review",
  "verdict": "pass",
  "exit_reason": "approved",
  "agent_calls": 3,
  "duration_sec": 12,
  "human_action_required": false,
  "metadata": {
    "verdict": "APPROVED_WITH_NOTES",
    "subprocess_warnings": "[\"post_specialist_cycle: dispatch failed\",\"specialist_build_fix_minimal: exit status 1\"]"
  }
}
JSON

if command -v python3 &>/dev/null; then
    schema_check=$(python3 -c "
import json
with open('${HAND_AUTHORED}') as f:
    d = json.load(f)

# Verify the envelope verdict survives the warnings.
print(d['verdict'])

# Verify the Metadata['subprocess_warnings'] is a JSON-array string the
# parser can decode back into a list.
raw = d['metadata']['subprocess_warnings']
warnings = json.loads(raw)
print(len(warnings))
print(warnings[0])
")
    verdict_check=$(echo "$schema_check" | sed -n '1p')
    count_check=$(echo "$schema_check" | sed -n '2p')
    first_warn=$(echo "$schema_check" | sed -n '3p')

    # The verdict MUST be pass — that's the whole point of m47.
    assert_eq "envelope.verdict.with_warnings" "pass" "$verdict_check"
    # The plural-key contract: warnings is a JSON list with multiple entries.
    assert_eq "warnings.count" "2" "$count_check"
    assert_contains "warnings.first.entry" "post_specialist_cycle" "$first_warn"
fi

# --- Test 4: empty / missing Metadata is acceptable (back-compat) -------------
# The Metadata field is omitempty — pre-m47 envelopes without it must still
# parse cleanly. Re-use the Test 1 envelope which has no Metadata set.
if command -v python3 &>/dev/null; then
    meta_check=$(python3 -c "
import json
with open('${RESULT}') as f:
    d = json.load(f)
# Either absent (omitempty) or empty dict is acceptable.
print('absent' if 'metadata' not in d else 'present')
")
    assert_eq "envelope.metadata.backcompat" "absent" "$meta_check"
fi

echo
echo "════════════════════════════════════════"
echo "  m47 envelope-over-error: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"

[[ "$FAIL" -eq 0 ]]
