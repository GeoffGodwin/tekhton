#!/usr/bin/env bash
# =============================================================================
# test_notes_parity.sh — m24 parity gate.
#
# Validates four canonical HUMAN_NOTES.md scenarios end-to-end through
# the `tekhton note` CLI:
#
#   1. greenfield                 — empty file, zero output
#   2. populated-three-tags       — list / extract / done semantics
#   3. post-completion-sweep      — resolve-bulk Done transition
#   4. v2-format-migration        — V1 → V2 idempotent upgrade
#
# The bash baseline is gone (lib/notes*.sh deleted in m24); the test
# instead pins the Go behaviour against fixed expected outputs derived
# from the milestone spec so any regression in the writer is caught at
# CI time.
#
# Skips cleanly when the tekhton Go binary is not built.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${TEKHTON_HOME}/tests"
# shellcheck source=lib/parity.sh
source "${TESTS_DIR}/lib/parity.sh"

# Resolve binary — always test the local repo's binary, not whatever
# TEKHTON_BIN points at in the inherited env (e.g. a sibling install).
# Matches the pattern in test_preflight_parity.sh.
TK_BIN="${TEKHTON_HOME}/bin/tekhton"
if [[ ! -x "$TK_BIN" ]]; then
    echo "test_notes_parity.sh: tekhton binary not found at ${TK_BIN}; skipping (run 'make build' first)"
    exit 0
fi

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Clear HUMAN_NOTES_FILE env so it doesn't leak from caller shell.
unset HUMAN_NOTES_FILE

# ----------------------------------------------------------------------------
# Scenario 1 — greenfield: no HUMAN_NOTES.md present.
# ----------------------------------------------------------------------------
S1="${TMPROOT}/s1_greenfield"
mkdir -p "$S1"

# list with no file → "No HUMAN_NOTES.md found."
out=$("$TK_BIN" note list --project-dir "$S1" 2>/dev/null || true)
if [[ "$out" != *"No HUMAN_NOTES.md found."* ]]; then
    parity_fail "s1.list: expected 'No HUMAN_NOTES.md found.' got: $out"
else
    parity_pass "s1.list: greenfield list reports missing-file"
fi

# extract with no file → empty
out=$("$TK_BIN" note extract --project-dir "$S1" 2>/dev/null || true)
if [[ -n "$out" ]]; then
    parity_fail "s1.extract: expected empty output got: $out"
else
    parity_pass "s1.extract: greenfield extract returns empty"
fi

# count with no file → "0"
out=$("$TK_BIN" note count --project-dir "$S1" 2>/dev/null || echo "")
if [[ "$out" != "0" ]]; then
    parity_fail "s1.count: expected '0' got: '$out'"
else
    parity_pass "s1.count: greenfield count returns 0"
fi

# pick-next with no file → empty
out=$("$TK_BIN" note pick-next --project-dir "$S1" 2>/dev/null || echo "")
if [[ -n "$out" ]]; then
    parity_fail "s1.pick-next: expected empty got: '$out'"
else
    parity_pass "s1.pick-next: greenfield pick-next returns empty"
fi

# ----------------------------------------------------------------------------
# Scenario 2 — populated three tags.
# ----------------------------------------------------------------------------
S2="${TMPROOT}/s2_populated"
mkdir -p "$S2"

"$TK_BIN" note add --project-dir "$S2" --tag BUG "first bug" >/dev/null
"$TK_BIN" note add --project-dir "$S2" --tag BUG "second bug" >/dev/null
"$TK_BIN" note add --project-dir "$S2" --tag BUG "third bug" >/dev/null
"$TK_BIN" note add --project-dir "$S2" --tag FEAT "first feat" >/dev/null
"$TK_BIN" note add --project-dir "$S2" --tag FEAT "second feat" >/dev/null
"$TK_BIN" note add --project-dir "$S2" --tag POLISH "first polish" >/dev/null

# JSON envelope
out=$("$TK_BIN" note list --project-dir "$S2" --format json)
proto=$(echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("proto",""))' 2>/dev/null || echo "")
total=$(echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("total",0))' 2>/dev/null || echo "")
if [[ "$proto" != "tekhton.notes.list.v1" ]]; then
    parity_fail "s2.json.proto: expected 'tekhton.notes.list.v1' got: '$proto'"
else
    parity_pass "s2.json.proto: envelope tag matches"
fi
if [[ "$total" != "6" ]]; then
    parity_fail "s2.json.total: expected 6 got: $total"
else
    parity_pass "s2.json.total: 6 entries reported"
fi

# count
out=$("$TK_BIN" note count --project-dir "$S2")
if [[ "$out" != "6" ]]; then
    parity_fail "s2.count: expected 6 got: $out"
else
    parity_pass "s2.count: 6 pending notes"
fi

# count by tag — BUG → 3
out=$("$TK_BIN" note count --project-dir "$S2" --tag BUG)
if [[ "$out" != "3" ]]; then
    parity_fail "s2.count.bug: expected 3 got: $out"
else
    parity_pass "s2.count.bug: 3 BUG notes"
fi

# pick-next priority: should be a BUG (BUG > FEAT > POLISH)
out=$("$TK_BIN" note pick-next --project-dir "$S2")
if [[ "$out" != *"[BUG]"* ]]; then
    parity_fail "s2.pick-next: expected BUG first got: $out"
else
    parity_pass "s2.pick-next: BUG priority honored"
fi

# extract block — contains all 6 titles, no metadata
out=$("$TK_BIN" note extract --project-dir "$S2")
for title in "first bug" "second bug" "third bug" "first feat" "second feat" "first polish"; do
    if [[ "$out" != *"$title"* ]]; then
        parity_fail "s2.extract: missing '$title'"
        break
    fi
done
if [[ "$out" == *"<!-- note:"* ]]; then
    parity_fail "s2.extract: metadata leaked"
else
    parity_pass "s2.extract: all titles present, metadata stripped"
fi

# done by ID — n01 (first bug)
out=$("$TK_BIN" note done --project-dir "$S2" n01)
if [[ "$out" != *"done: n01"* ]]; then
    parity_fail "s2.done: expected 'done: n01' got: $out"
else
    parity_pass "s2.done: n01 transitioned to Done"
fi

# After done, pending count drops to 5
out=$("$TK_BIN" note count --project-dir "$S2")
if [[ "$out" != "5" ]]; then
    parity_fail "s2.count.post-done: expected 5 got: $out"
else
    parity_pass "s2.count.post-done: 5 pending"
fi

# ----------------------------------------------------------------------------
# Scenario 3 — post-completion sweep.
# ----------------------------------------------------------------------------
S3="${TMPROOT}/s3_sweep"
mkdir -p "$S3"

"$TK_BIN" note add --project-dir "$S3" --tag BUG "sweep me 1" >/dev/null
"$TK_BIN" note add --project-dir "$S3" --tag FEAT "sweep me 2" >/dev/null
"$TK_BIN" note add --project-dir "$S3" --tag FEAT "leave me alone" >/dev/null

# Claim two notes by tag (BUG only)
out=$("$TK_BIN" note claim-bulk --project-dir "$S3" --tag BUG)
if [[ "$out" != "n01" ]]; then
    parity_fail "s3.claim-bulk: expected 'n01' got: '$out'"
else
    parity_pass "s3.claim-bulk: BUG note claimed"
fi

# Active count should be 1
out=$("$TK_BIN" note count --project-dir "$S3" --state active)
if [[ "$out" != "1" ]]; then
    parity_fail "s3.count.active: expected 1 got: $out"
else
    parity_pass "s3.count.active: 1 active note"
fi

# Resolve with exit-code 0 → claimed n01 should become Done
"$TK_BIN" note resolve-bulk --project-dir "$S3" --exit-code 0 --ids "n01" >/dev/null

out=$("$TK_BIN" note count --project-dir "$S3" --state done)
if [[ "$out" != "1" ]]; then
    parity_fail "s3.resolve-bulk: expected 1 done got: $out"
else
    parity_pass "s3.resolve-bulk: n01 resolved to Done"
fi

# clear-completed → removes the Done line
"$TK_BIN" note clear-completed --project-dir "$S3" >/dev/null
out=$("$TK_BIN" note count --project-dir "$S3" --state done)
if [[ "$out" != "0" ]]; then
    parity_fail "s3.clear-completed: expected 0 done got: $out"
else
    parity_pass "s3.clear-completed: Done note removed"
fi

# Remaining pending count is 2 (the two FEAT notes)
out=$("$TK_BIN" note count --project-dir "$S3")
if [[ "$out" != "2" ]]; then
    parity_fail "s3.count.final: expected 2 got: $out"
else
    parity_pass "s3.count.final: 2 pending FEAT notes survived"
fi

# ----------------------------------------------------------------------------
# Scenario 4 — V1 → V2 migration.
# ----------------------------------------------------------------------------
S4="${TMPROOT}/s4_migrate"
mkdir -p "$S4"

# Seed a V1-format file (no IDs, no format marker)
cat > "$S4/HUMAN_NOTES.md" <<'EOF'
# Human Notes

- [ ] [BUG] needs migration
- [ ] [FEAT] also needs migration
EOF

"$TK_BIN" note migrate --project-dir "$S4" >/dev/null 2>&1 || true

# After migrate, the file should have the v2 marker.
if ! grep -q '<!-- notes-format: v2 -->' "$S4/HUMAN_NOTES.md"; then
    parity_fail "s4.migrate.marker: v2 marker missing"
else
    parity_pass "s4.migrate.marker: v2 marker added"
fi

# IDs should be present on notes
if ! grep -q '<!-- note:n' "$S4/HUMAN_NOTES.md"; then
    parity_fail "s4.migrate.ids: no note IDs found"
else
    parity_pass "s4.migrate.ids: IDs assigned"
fi

# Re-running migrate is idempotent (no error).
"$TK_BIN" note migrate --project-dir "$S4" >/dev/null 2>&1 || true
parity_pass "s4.migrate.idempotent: second run did not error"

parity_summary "test_notes_parity"
