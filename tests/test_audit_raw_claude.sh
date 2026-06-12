#!/usr/bin/env bash
# tests/test_audit_raw_claude.sh — m20 unit tests for scripts/audit-raw-claude.sh.
#
# Tests that the raw-claude audit gate:
#   1. Exits 0 on files with no raw claude calls.
#   2. Catches flag form:               claude -p "x"
#   3. Catches subcommand form:         claude usage
#   4. Catches line-continuation form:  claude \<newline>  (the plan_batch.sh pattern)
#   5. Ignores shell comments mentioning claude.
#   6. Ignores CLAUDE_ variable names.
#   7. Ignores .claude path strings.
#   8. Allowlists lib/quota_probe.sh (real calls exist but are provider-gated).
#
# Fails immediately if the audit script does not exist (m20 not implemented).
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_SCRIPT="${TEKHTON_HOME}/scripts/audit-raw-claude.sh"

PASS=0
FAIL=0
FAILED_CASES=()

_pass() { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
_fail() { local label="$1"; shift; echo "  FAIL: ${label}${*:+ — $*}"; FAIL=$(( FAIL + 1 )); FAILED_CASES+=("$label"); }

# --- existence guard ---------------------------------------------------------
if [[ ! -f "$AUDIT_SCRIPT" ]]; then
    _fail "scripts/audit-raw-claude.sh exists" "file not found — m20 not implemented"
    echo ""
    echo "FAIL: ${FAIL} tests failed (${PASS} passed)"
    exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

_run_audit() {
    local target="$1"
    local _out _rc
    set +e
    _out=$(bash "${AUDIT_SCRIPT}" "${target}" 2>&1)
    _rc=$?
    set -e
    AUDIT_OUTPUT="${_out}"
    AUDIT_RC="${_rc}"
}

_assert_exit() {
    local label="$1" want="$2"
    if [[ "$AUDIT_RC" -eq "$want" ]]; then
        _pass "$label"
    else
        _fail "$label" "want exit ${want}, got ${AUDIT_RC}; output: ${AUDIT_OUTPUT}"
    fi
}

_assert_contains() {
    local label="$1" needle="$2"
    if grep -qF "$needle" <<< "${AUDIT_OUTPUT}"; then
        _pass "$label"
    else
        _fail "$label" "expected '${needle}' in output; got: ${AUDIT_OUTPUT}"
    fi
}

# === fixture 1: clean file (no raw claude calls) ===========================
cat > "${TMPDIR}/clean.sh" << 'EOF'
#!/usr/bin/env bash
# This file is clean — no raw claude calls.
CLAUDE_MODEL="claude-sonnet-4-6"
CONFIG_PATH=".claude/pipeline.conf"
echo "No claude invocations here"
# A comment mentioning claude in passing is fine.
EOF
_run_audit "${TMPDIR}/clean.sh"
_assert_exit "clean file exits 0" 0

# === fixture 2: flag form ===================================================
cat > "${TMPDIR}/flag_form.sh" << 'EOF'
#!/usr/bin/env bash
claude -p "my prompt here"
EOF
_run_audit "${TMPDIR}/flag_form.sh"
_assert_exit "flag form exits non-zero" 1
_assert_contains "flag form hit reported" "flag_form.sh"

# === fixture 3: subcommand form =============================================
cat > "${TMPDIR}/subcommand_form.sh" << 'EOF'
#!/usr/bin/env bash
usage_output=$(claude usage 2>/dev/null || true)
EOF
_run_audit "${TMPDIR}/subcommand_form.sh"
_assert_exit "subcommand form exits non-zero" 1
_assert_contains "subcommand form hit reported" "subcommand_form.sh"

# === fixture 4: line-continuation form =====================================
# This is the exact pattern from lib/plan_batch.sh line 88.
cat > "${TMPDIR}/continuation_form.sh" << 'EOF'
#!/usr/bin/env bash
claude \
    --model "claude-sonnet-4-6" \
    --output-format text \
    --dangerously-skip-permissions \
    -p
EOF
_run_audit "${TMPDIR}/continuation_form.sh"
_assert_exit "line-continuation form exits non-zero" 1
_assert_contains "line-continuation form hit reported" "continuation_form.sh"

# === fixture 5: comment mention only — must NOT be flagged ================
cat > "${TMPDIR}/comment_only.sh" << 'EOF'
#!/usr/bin/env bash
# We used to call: claude --model "..." -p
# claude is mentioned in comments only — not in command position.
: # no claude invocations
EOF
_run_audit "${TMPDIR}/comment_only.sh"
_assert_exit "comment mention exits 0" 0

# === fixture 6: CLAUDE_ variable — must NOT be flagged ====================
cat > "${TMPDIR}/claude_var.sh" << 'EOF'
#!/usr/bin/env bash
CLAUDE_MODEL="claude-sonnet-4-6"
CLAUDE_CODER_MODEL="${CLAUDE_MODEL}"
echo "${CLAUDE_MODEL}"
EOF
_run_audit "${TMPDIR}/claude_var.sh"
_assert_exit "CLAUDE_ variable exits 0" 0

# === fixture 7: .claude path — must NOT be flagged ========================
cat > "${TMPDIR}/claude_path.sh" << 'EOF'
#!/usr/bin/env bash
CONFIG=".claude/pipeline.conf"
MILESTONE_DIR=".claude/milestones"
cat "$CONFIG"
EOF
_run_audit "${TMPDIR}/claude_path.sh"
_assert_exit ".claude path exits 0" 0

# === fixture 8: lib/quota_probe.sh is allowlisted =========================
# quota_probe.sh contains real claude invocations that are provider-gated
# (m21 scope). The audit must NOT flag it (it's in the permanent allowlist).
QUOTA_PROBE="${TEKHTON_HOME}/lib/quota_probe.sh"
if [[ -f "$QUOTA_PROBE" ]]; then
    # Verify quota_probe.sh actually has claude calls (so the allowlist is meaningful)
    if grep -qE '(^|[;&|(` ]|[[:space:]])claude([[:space:]]|\\$)' "$QUOTA_PROBE" 2>/dev/null; then
        _run_audit "$QUOTA_PROBE"
        _assert_exit "quota_probe.sh allowlisted despite claude calls (exits 0)" 0
    else
        _pass "quota_probe.sh allowlist (no claude calls found — allowlist entry is harmless)"
    fi
else
    _fail "quota_probe.sh exists for allowlist test" "not found at ${QUOTA_PROBE}"
fi

# === live tree scan: post-m20 tree exits 0 ================================
# After m20, no file in lib/ or stages/ should have a raw claude call outside
# the allowlist. This is the primary CI gate.
_run_audit "${TEKHTON_HOME}/lib/"
_assert_exit "full lib/ scan exits 0 (no unlisted raw claude calls)" 0

# --- summary -----------------------------------------------------------------
echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "All audit-raw-claude tests passed (${PASS})"
    exit 0
else
    echo "FAIL: ${FAIL} tests failed (${PASS} passed)"
    for c in "${FAILED_CASES[@]}"; do
        echo "  - $c"
    done
    exit 1
fi
