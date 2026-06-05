#!/usr/bin/env bash
# TIMEOUT_SECS=120
# =============================================================================
# tests/test_intake_parity.sh — m36.3 parity gate for the intake stage.
#
# Drives `tekhton run-stage intake --request-file <fixture>` against eight
# frozen scenarios covering all four verdicts (PASS, TWEAKED,
# SPLIT_RECOMMENDED, NEEDS_CLARITY) plus the cached-run branch, the
# HUMAN_MODE skip branch, the no-content branch, and the
# disabled-agent branch.
#
# The agent supervisor seam is wired to /bin/false so every claude
# invocation exits immediately — the stage falls through to its
# best-effort parse path against a pre-seeded INTAKE_REPORT.md. The
# parity gate asserts (verdict, exit_reason) for each scenario.
#
# Scenarios:
#   pass                      — PASS verdict → exit_reason=pass
#   tweaked                   — TWEAKED verdict → exit_reason=tweaked
#   split-recommended         — SPLIT_RECOMMENDED → exit_reason=split_recommended
#   needs-clarity-complete    — NEEDS_CLARITY in COMPLETE_MODE → block verdict
#   cached-run                — INTAKE_CACHED=true + PASS report → pass
#   human-mode-skip           — HUMAN_MODE=true → skip/human_mode
#   disabled                  — INTAKE_AGENT_ENABLED=false → skip/disabled
#   no-content                — empty TASK + no milestone → skip/no_content
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME
TEKHTON_BIN="${TEKHTON_HOME}/bin/tekhton"

if [[ ! -x "$TEKHTON_BIN" ]]; then
    (cd "$TEKHTON_HOME" && go build -o "$TEKHTON_BIN" ./cmd/tekhton) || {
        echo "SKIP: cannot build $TEKHTON_BIN (go toolchain missing?)" >&2
        exit 0
    }
fi

FAIL=0
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t intake_parity)
trap 'rm -rf "$WORK"' EXIT

# write_report PROJECT_DIR VERDICT [CONFIDENCE] [EXTRA_BLOCK]
write_report() {
    local dir="$1" verdict="$2" conf="${3:-85}" extra="${4:-}"
    mkdir -p "$dir/.tekhton"
    {
        printf '# Intake Report\n\n## Verdict\n%s\n\n## Confidence\n%s\n' \
            "$verdict" "$conf"
        if [[ -n "$extra" ]]; then
            printf '\n%s\n' "$extra"
        fi
    } > "$dir/.tekhton/INTAKE_REPORT.md"
}

# drive_intake PROJECT_DIR TASK_TEXT
# Runs the intake stage subprocess and emits "verdict|exit_reason" to stdout.
# Sets TASK explicitly so parent-env TASK values can't bleed in.
drive_intake() {
    local project_dir="$1" task_text="$2"
    local request_file="$WORK/request.json"
    local result_file="$WORK/result.json"
    cat > "$request_file" <<JSON
{
  "proto": "tekhton.stage.request.v1",
  "stage": "intake",
  "task": "$task_text",
  "result_file": "$result_file"
}
JSON
    export PROJECT_DIR="$project_dir"
    export TEKHTON_SESSION_DIR="$project_dir/.tekhton/session"
    mkdir -p "$TEKHTON_SESSION_DIR"
    # /bin/false → supervisor's exec always exits 1, stage falls through to
    # best-effort report parse against the pre-seeded INTAKE_REPORT.md.
    export TEKHTON_AGENT_BINARY=/bin/false
    # Force TASK / _CURRENT_MILESTONE / MILESTONE_MODE to the scenario
    # values so parent-shell env can't override the request payload.
    TASK="$task_text" \
    _CURRENT_MILESTONE="" \
    MILESTONE_MODE="${MILESTONE_MODE:-false}" \
    timeout 20s "$TEKHTON_BIN" run-stage intake \
        --request-file "$request_file" \
        --tekhton-home "$TEKHTON_HOME" \
        --project-dir "$project_dir" \
        >"$WORK/stage.stdout" 2>"$WORK/stage.stderr" || true
    # The Go verdict handler prints user-facing messages to stdout BEFORE
    # the result envelope is marshalled. Parse the LAST JSON object found
    # so split/needs-clarity scenarios (which print headers) don't trip
    # the parser.
    python3 -c "
import json, re
with open('$WORK/stage.stdout') as f:
    body = f.read()
# Find the last '{' that starts a valid JSON object.
last_open = body.rfind('{')
if last_open < 0:
    print('parse_error|no JSON object in stdout')
else:
    try:
        data = json.loads(body[last_open:])
        print('%s|%s' % (data.get('verdict', '?'), data.get('exit_reason', '?')))
    except Exception as e:
        print('parse_error|%s' % e)
"
}

assert_outcome() {
    local label="$1" got="$2" want_pat="$3"
    case "$got" in
        $want_pat)
            echo "PASS [$label]: $got" ;;
        *)
            echo "FAIL [$label]: got '$got' want '$want_pat'"
            FAIL=$((FAIL + 1)) ;;
    esac
}

run_scenario() {
    # run_scenario LABEL PROJECT_DIR TASK_TEXT WANT_PAT
    # Caller can also pre-set env vars on the function call line.
    local label="$1" project_dir="$2" task_text="$3" want_pat="$4"
    local out
    out=$(drive_intake "$project_dir" "$task_text")
    assert_outcome "$label" "$out" "$want_pat"
}

# Each scenario runs in a subshell so env-var changes don't leak.

# --- Scenario 1: pass --------------------------------------------------------
(
    SCN="$WORK/pass"
    mkdir -p "$SCN/.tekhton"
    write_report "$SCN" PASS 90
    run_scenario "pass" "$SCN" "verify the build" "pass|*"
) || FAIL=$((FAIL + 1))

# --- Scenario 2: tweaked -----------------------------------------------------
(
    SCN="$WORK/tweaked"
    mkdir -p "$SCN/.tekhton"
    write_report "$SCN" TWEAKED 75 "## Tweaked Content
Verify the production build succeeds end-to-end with all artifacts."
    export INTAKE_CONFIRM_TWEAKS=false
    run_scenario "tweaked" "$SCN" "verify the build" "pass|tweaked"
) || FAIL=$((FAIL + 1))

# --- Scenario 3: split-recommended -------------------------------------------
(
    SCN="$WORK/split-recommended"
    mkdir -p "$SCN/.tekhton"
    write_report "$SCN" SPLIT_RECOMMENDED 50 "## Split Recommendations
This milestone covers two unrelated subsystems and should be split."
    export COMPLETE_MODE=true
    run_scenario "split-recommended" "$SCN" "refactor everything" "pass|split_recommended"
) || FAIL=$((FAIL + 1))

# --- Scenario 4: needs-clarity-complete -------------------------------------
(
    SCN="$WORK/needs-clarity-complete"
    mkdir -p "$SCN/.tekhton"
    write_report "$SCN" NEEDS_CLARITY 30 "## Questions
- What is the timeout?
- Should the retry persist across runs?"
    export COMPLETE_MODE=true
    run_scenario "needs-clarity-complete" "$SCN" "add retry" "block|needs_clarity"
    # Verify CLARIFICATIONS.md was written.
    if [[ ! -f "$SCN/.tekhton/CLARIFICATIONS.md" ]]; then
        echo "FAIL [needs-clarity-complete CLARIFICATIONS.md]: file not written"
        exit 1
    elif ! grep -q "What is the timeout?" "$SCN/.tekhton/CLARIFICATIONS.md"; then
        echo "FAIL [needs-clarity-complete CLARIFICATIONS content]: question missing"
        exit 1
    else
        echo "PASS [needs-clarity-complete CLARIFICATIONS.md present]"
    fi
) || FAIL=$((FAIL + 1))

# --- Scenario 5: cached-run --------------------------------------------------
(
    SCN="$WORK/cached-run"
    mkdir -p "$SCN/.tekhton"
    write_report "$SCN" PASS 88
    export INTAKE_CACHED=true
    run_scenario "cached-run" "$SCN" "verify cached pass" "pass|cached_pass"
) || FAIL=$((FAIL + 1))

# --- Scenario 6: human-mode-skip --------------------------------------------
(
    SCN="$WORK/human-mode-skip"
    mkdir -p "$SCN/.tekhton"
    export HUMAN_MODE=true
    run_scenario "human-mode-skip" "$SCN" "human notes triaged" "skip|human_mode"
) || FAIL=$((FAIL + 1))

# --- Scenario 7: disabled-agent ---------------------------------------------
(
    SCN="$WORK/disabled"
    mkdir -p "$SCN/.tekhton"
    export INTAKE_AGENT_ENABLED=false
    run_scenario "disabled" "$SCN" "disabled" "skip|disabled"
) || FAIL=$((FAIL + 1))

# --- Scenario 8: no-content -------------------------------------------------
# Empty TASK + MILESTONE_MODE=false → milestone-content returns "".
(
    SCN="$WORK/no-content"
    mkdir -p "$SCN/.tekhton"
    export MILESTONE_MODE=false
    run_scenario "no-content" "$SCN" "" "skip|no_content"
) || FAIL=$((FAIL + 1))

if (( FAIL > 0 )); then
    echo "FAIL: $FAIL intake-parity assertion(s) failed" >&2
    exit 1
fi
echo "OK: intake parity gate (m36.3) — 8 scenarios passed"
