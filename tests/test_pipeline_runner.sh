#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_pipeline_runner.sh — m18 smoke test for `tekhton pipeline run-attempt`.
#
# Builds a small fake stage harness:
#   * A throwaway TEKHTON_HOME with stub stages/intake.sh and stages/coder.sh.
#     Each stub writes a stage.result.v1 envelope and exits 0.
#   * A throwaway PROJECT_DIR.
#   * A pipeline.attempt.request.v1 JSON request.
#
# Invokes `tekhton pipeline run-attempt --request-file …` and asserts the
# attempt result envelope has verdict=pass and stages.length == 2.
# =============================================================================

TEKHTON_HOME_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEKHTON_BIN="${TEKHTON_HOME_REAL}/bin/tekhton"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass
    else
        fail "${name}: expected '${expected}', got '${actual}'"
    fi
}

# Build the binary if it's not already present. Skip the test gracefully if Go
# isn't available — the test runner respects exit 0.
if [[ ! -x "$TEKHTON_BIN" ]]; then
    if command -v go &>/dev/null; then
        (cd "$TEKHTON_HOME_REAL" && make build >/dev/null 2>&1) || true
    fi
fi

if [[ ! -x "$TEKHTON_BIN" ]]; then
    echo "SKIP: tekhton binary unavailable (go not installed?)"
    exit 0
fi

# Build a minimal fake TEKHTON_HOME with stub stages.
FAKE_HOME=$(mktemp -d)
FAKE_PROJ=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME" "$FAKE_PROJ"' EXIT

mkdir -p "$FAKE_HOME/lib" "$FAKE_HOME/stages"

# Real stage_envelope.sh + a no-op common.sh.
cp "${TEKHTON_HOME_REAL}/lib/stage_envelope.sh" "$FAKE_HOME/lib/stage_envelope.sh"
cat > "$FAKE_HOME/lib/common.sh" <<'COMMON'
# stub common.sh
log() { :; }
warn() { :; }
error() { echo "$@" >&2; }
success() { :; }
header() { :; }
COMMON

# Stub intake stage. Writes envelope manually so we don't need the wrapper.
cat > "$FAKE_HOME/stages/intake.sh" <<'INTAKE'
run_stage_intake() {
    "${TEKHTON_BIN:-tekhton}" stage emit \
        --stage intake \
        --verdict pass \
        --exit-reason "intake-ok" \
        --agent-calls 1 \
        --duration 1 \
        --next-action accept \
        --to-result-file
}
INTAKE

# Stub coder stage.
cat > "$FAKE_HOME/stages/coder.sh" <<'CODER'
run_stage_coder() {
    "${TEKHTON_BIN:-tekhton}" stage emit \
        --stage coder \
        --verdict pass \
        --exit-reason "coder-ok" \
        --agent-calls 2 \
        --duration 3 \
        --to-result-file
}
CODER

# Build the pipeline request envelope.
RESULT_DIR=$(mktemp -d)
LOG_DIR=$(mktemp -d)
REQUEST_FILE="${FAKE_PROJ}/req.json"
cat > "$REQUEST_FILE" <<JSON
{
  "proto": "tekhton.pipeline.attempt.request.v1",
  "task": "smoke",
  "order": ["intake", "coder"],
  "review_cycle": 1,
  "build_attempt": 0,
  "max_review_cycles": 3,
  "max_build_retries": 0,
  "project_dir": "${FAKE_PROJ}"
}
JSON

# Invoke the binary.
export TEKHTON_BIN
RESULT_OUT=$(TEKHTON_HOME="$FAKE_HOME" "$TEKHTON_BIN" pipeline run-attempt \
    --request-file "$REQUEST_FILE" \
    --tekhton-home "$FAKE_HOME" \
    --project-dir "$FAKE_PROJ" \
    --result-dir "$RESULT_DIR" \
    --log-dir "$LOG_DIR" 2>&1) || PIPE_EXIT=$?
PIPE_EXIT=${PIPE_EXIT:-0}

if [[ "$PIPE_EXIT" -ne 0 ]]; then
    fail "pipeline run-attempt exited $PIPE_EXIT — output: $RESULT_OUT"
else
    pass
fi

# Verify the result envelope.
if [[ -z "$RESULT_OUT" ]]; then
    fail "no output from pipeline run-attempt"
else
    pass
fi

# Strip stderr lines (emit_event etc.) and extract the JSON block.
JSON_OUT=$(echo "$RESULT_OUT" | awk '/^{/{found=1} found{print}')

JSON_FILE="${FAKE_PROJ}/result.json"
printf '%s' "$JSON_OUT" > "$JSON_FILE"

if command -v python3 &>/dev/null; then
    py_exit=0
    python3 - "$JSON_FILE" <<'PY' || py_exit=$?
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
assert data.get("proto") == "tekhton.pipeline.attempt.result.v1", "wrong proto: " + str(data.get("proto"))
assert data.get("verdict") == "pass", "wrong verdict: " + str(data.get("verdict"))
assert len(data.get("stages", [])) == 2, "expected 2 stages, got " + str(data.get("stages"))
assert data["stages"][0]["stage"] == "intake"
assert data["stages"][1]["stage"] == "coder"
print("OK")
PY
    if [[ "$py_exit" -eq 0 ]]; then
        pass
        pass  # 2 envelope assertions
    else
        fail "envelope shape check failed (exit $py_exit)"
    fi
else
    # Lightweight smoke check.
    if [[ "$JSON_OUT" == *'"verdict": "pass"'* ]] || [[ "$JSON_OUT" == *'"verdict":"pass"'* ]]; then
        pass
    else
        fail "envelope missing verdict=pass; got: $JSON_OUT"
    fi
fi

echo
echo "════════════════════════════════════════"
echo "  Pipeline Runner Tests: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
