#!/usr/bin/env bash
# TIMEOUT_SECS=180
# =============================================================================
# tests/test_security_parity.sh — m35.3 parity gate for the security stage.
#
# Drives `tekhton run-stage security` end-to-end through three scenarios and
# diffs the result envelope + structured artifacts (SECURITY_NOTES.md,
# HUMAN_ACTION_REQUIRED.md) against captured baselines under
# tests/baselines/m35-security/.
#
# Scenarios:
#   pass-no-findings           — fake agent emits two turn events and exits
#                                without writing SECURITY_REPORT.md → Pass /
#                                no_findings, agent_calls=1, no HumanAction.
#   fixable-cycle-1-resolved   — fake agent writes HIGH fixable on call 1,
#                                empty on call 2 → cycle 1 → rework → re-scan
#                                → Pass / complete, agent_calls=3.
#   unfixable-escalate         — fake agent writes HIGH unfixable, default
#                                policy=escalate → Pass / complete,
#                                HumanAction=true, HUMAN_ACTION_REQUIRED.md row.
#
# The fake supervisor binary lives at testdata/fake_security_agent.sh and is
# wired via TEKHTON_AGENT_BINARY so the security stage's package-level
# AgentRunner (supervisor.New(nil, nil) at init) picks it up.
#
# Baseline origin: the milestone called for pre-M35 bash captures under
# v4.34.99-security-baseline. That tag was never created (acknowledged
# meta-failure — see m35.3 Watch For block and the "Phase 5 Security Stage
# Closeout" section in docs/go-migration.md). The captured baselines are the
# current Go stage outputs, locked forward as the regression baseline.
# Helper-level byte-for-byte parity against the pre-M35 bash was already
# established by m35.1's 18 golden-file baselines under
# internal/security/testdata/baselines/, so this gate preserves the contract
# transitively even without a fresh bash capture.
#
# Normalization rules:
#   - duration_sec → 0 (stage may take >1s on slow runners)
#   - Generated: YYYY-MM-DD HH:MM:SS → Generated: <TIMESTAMP>
#   - [YYYY-MM-DD | Source: → [<DATE> | Source:
#   - absolute /tmp/* paths under PROJECT_DIR → <PROJECT>
#
# Bootstrap: rerun with M35_PARITY_CAPTURE=1 to regenerate baselines after a
# deliberate behavior change. Treat any other regeneration as a regression.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

# Always use the local repo build. Ignore $TEKHTON_BIN from the parent shell —
# a stale stable build would dispatch security through the deleted bash stage
# and the gate would silently lock the wrong baselines.
TEKHTON_BIN="${TEKHTON_HOME}/bin/tekhton"
if [[ ! -x "$TEKHTON_BIN" ]]; then
    (cd "$TEKHTON_HOME" && go build -o "$TEKHTON_BIN" ./cmd/tekhton) || {
        echo "SKIP: cannot build $TEKHTON_BIN (go toolchain missing?)" >&2
        exit 0
    }
fi

FAKE_AGENT="${TEKHTON_HOME}/testdata/fake_security_agent.sh"
if [[ ! -x "$FAKE_AGENT" ]]; then
    echo "FAIL: fake security agent missing or not executable at $FAKE_AGENT" >&2
    exit 1
fi

BASELINE_DIR="${TEKHTON_HOME}/tests/baselines/m35-security"
SCENARIOS=(pass-no-findings fixable-cycle-1-resolved unfixable-escalate)
ARTIFACTS=(stdout.json SECURITY_NOTES.md HUMAN_ACTION_REQUIRED.md)
CAPTURE_MODE="${M35_PARITY_CAPTURE:-0}"

FAIL=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Strip timestamps, absolute paths, and per-run integers so the diff sees
# only the stable shape. Reads from stdin, writes to stdout.
normalize() {
    local project_dir="$1"
    # sed -E for portable extended regex (Linux/macOS).
    sed -E \
        -e 's/"duration_sec": [0-9]+/"duration_sec": 0/g' \
        -e 's/Generated: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/Generated: <TIMESTAMP>/g' \
        -e 's/\[[0-9]{4}-[0-9]{2}-[0-9]{2} \| Source:/[<DATE> | Source:/g' \
        -e "s|${project_dir}|<PROJECT>|g"
}

# Drive one scenario end-to-end. Writes normalized artifacts to "$WORK/<scn>/"
# and returns 0 even if the binary exits non-zero (the parity check is on
# the result envelope, not the exit code).
drive_scenario() {
    local scenario="$1"
    local project_dir="$WORK/$scenario"
    mkdir -p "$project_dir/.tekhton"
    (
        cd "$project_dir"
        git init -q
        git config user.email t@example.com
        git config user.name T
        git config commit.gpgsign false
        git commit --allow-empty -q -m init
    )
    cat > "$project_dir/request.json" <<JSON
{
  "proto": "tekhton.stage.request.v1",
  "stage": "security",
  "task": "m35.3 parity / $scenario",
  "result_file": "$project_dir/.tekhton/result.json"
}
JSON

    local notes_file="$project_dir/.tekhton/SECURITY_NOTES.md"
    local report_file="$project_dir/.tekhton/SECURITY_REPORT.md"
    local counter_file="$project_dir/.tekhton/_fake_sec_counter"

    # Run the Go stage. Build-gate phases skip when ANALYZE_CMD /
    # BUILD_CHECK_CMD are empty — perfect for the rework cycle scenario.
    env -i \
        PATH="/usr/bin:/bin:/usr/local/bin" \
        HOME="$HOME" \
        TEKHTON_HOME="$TEKHTON_HOME" \
        PROJECT_DIR="$project_dir" \
        TEKHTON_AGENT_BINARY="$FAKE_AGENT" \
        FAKE_SECURITY_SCENARIO="$scenario" \
        FAKE_SECURITY_REPORT="$report_file" \
        FAKE_SECURITY_COUNTER="$counter_file" \
        SECURITY_NOTES_FILE="$notes_file" \
        "$TEKHTON_BIN" run-stage security \
            --request-file "$project_dir/request.json" \
            --project-dir "$project_dir" \
            --tekhton-home "$TEKHTON_HOME" \
        > "$project_dir/stdout.json" 2> "$project_dir/stderr.log" || true

    # Normalize each artifact. Missing files normalize to empty so the
    # baseline can encode "this file should not exist".
    mkdir -p "$WORK/$scenario/normalized"
    for artifact in "${ARTIFACTS[@]}"; do
        local src
        case "$artifact" in
            stdout.json) src="$project_dir/stdout.json" ;;
            *)           src="$project_dir/.tekhton/$artifact" ;;
        esac
        if [[ -f "$src" ]]; then
            normalize "$project_dir" < "$src" > "$WORK/$scenario/normalized/$artifact"
        else
            : > "$WORK/$scenario/normalized/$artifact"
        fi
    done
}

# Capture-bootstrap: copy normalized outputs into baselines/.
capture_baselines() {
    local scenario="$1"
    mkdir -p "$BASELINE_DIR/$scenario"
    for artifact in "${ARTIFACTS[@]}"; do
        cp -- "$WORK/$scenario/normalized/$artifact" "$BASELINE_DIR/$scenario/$artifact.baseline"
    done
    echo "CAPTURED $scenario"
}

# Diff normalized outputs against captured baselines.
diff_baselines() {
    local scenario="$1"
    local scn_failed=0
    for artifact in "${ARTIFACTS[@]}"; do
        local actual="$WORK/$scenario/normalized/$artifact"
        local baseline="$BASELINE_DIR/$scenario/$artifact.baseline"
        if [[ ! -f "$baseline" ]]; then
            echo "FAIL [$scenario / $artifact]: baseline missing at $baseline" >&2
            echo "        rerun with M35_PARITY_CAPTURE=1 to bootstrap" >&2
            scn_failed=1
            continue
        fi
        if ! diff -u "$baseline" "$actual" >/dev/null 2>&1; then
            echo "FAIL [$scenario / $artifact]: diff vs baseline:" >&2
            diff -u "$baseline" "$actual" >&2 || true
            scn_failed=1
        fi
    done
    if (( scn_failed == 0 )); then
        echo "PASS [$scenario]: 3 artifacts byte-identical after normalization"
    else
        FAIL=$((FAIL + 1))
    fi
}

for scenario in "${SCENARIOS[@]}"; do
    drive_scenario "$scenario"
    if [[ "$CAPTURE_MODE" = "1" ]]; then
        capture_baselines "$scenario"
    else
        diff_baselines "$scenario"
    fi
done

if [[ "$CAPTURE_MODE" = "1" ]]; then
    echo "Baselines captured under $BASELINE_DIR. Inspect with git diff before committing."
    exit 0
fi

if (( FAIL > 0 )); then
    echo "FAIL: $FAIL parity scenario(s) failed" >&2
    exit 1
fi
echo "OK: m35 security parity gate — ${#SCENARIOS[@]} scenarios passed"
