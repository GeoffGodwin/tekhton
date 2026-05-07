#!/usr/bin/env bash
# =============================================================================
# scripts/error-classify-parity-check.sh — m17 parity gate.
#
# Drives every fixture in tests/fixtures/error_classification/ through the Go
# classifier (`tekhton diagnose classify`) and asserts the M127 routing token
# matches the expected value. Each fixture is paired with an .expected file
# containing the routing token (or `-` to skip empty inputs).
#
# Exits 0 when every fixture matches, 1 otherwise.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="${TEKHTON_HOME}/tests/fixtures/error_classification"
BIN="${TEKHTON_HOME}/bin/tekhton"

if [[ ! -x "$BIN" ]]; then
    echo "[parity] tekhton binary missing at $BIN — run 'go build -o bin/tekhton ./cmd/tekhton'" >&2
    exit 2
fi

declare -A EXPECTED=(
    ["01_pure_code"]="code_dominant"
    ["02_pure_noncode"]="noncode_dominant"
    ["03_mixed_uncertain"]="mixed_uncertain"
    ["04_unknown_only"]="unknown_only"
    ["05_code_with_noise"]="code_dominant"
    ["06_bifl_shape"]="unknown_only"
    ["07_ui_timeout_noisy"]="noncode_dominant"
    ["08_empty"]="unknown_only"
)

declare -A EXPECTED_HAS_CODE=(
    ["01_pure_code"]="0"
    ["02_pure_noncode"]="1"
    ["03_mixed_uncertain"]="0"
    ["04_unknown_only"]="1"
    ["05_code_with_noise"]="0"
    ["06_bifl_shape"]="1"
    ["07_ui_timeout_noisy"]="1"
    ["08_empty"]="1"
)

declare -A EXPECTED_HAS_ONLY_NONCODE=(
    ["01_pure_code"]="1"
    ["02_pure_noncode"]="0"
    ["03_mixed_uncertain"]="1"
    ["04_unknown_only"]="1"
    ["05_code_with_noise"]="1"
    ["06_bifl_shape"]="0"
    ["07_ui_timeout_noisy"]="0"
    ["08_empty"]="1"
)

PASS=0
FAIL=0
report() {
    local name="$1" got="$2" want="$3" what="$4"
    if [[ "$got" == "$want" ]]; then
        echo "  [✓] ${name} ${what} = ${got}"
        PASS=$((PASS + 1))
    else
        echo "  [✗] ${name} ${what} = ${got}, want ${want}"
        FAIL=$((FAIL + 1))
    fi
}

for log in "${FIXTURE_DIR}"/*.log; do
    name=$(basename "$log" .log)
    routing=$("$BIN" diagnose classify --mode routing --input "$log")
    report "$name" "$routing" "${EXPECTED[$name]:-}" "routing"

    rc=0
    "$BIN" diagnose classify --has-code --input "$log" >/dev/null 2>&1 || rc=$?
    report "$name" "$rc" "${EXPECTED_HAS_CODE[$name]:-}" "has-code(rc)"

    rc=0
    "$BIN" diagnose classify --has-only-noncode --input "$log" >/dev/null 2>&1 || rc=$?
    report "$name" "$rc" "${EXPECTED_HAS_ONLY_NONCODE[$name]:-}" "has-only-noncode(rc)"
done

echo
echo "Parity check: ${PASS} pass, ${FAIL} fail"
[[ "$FAIL" -eq 0 ]] || exit 1
