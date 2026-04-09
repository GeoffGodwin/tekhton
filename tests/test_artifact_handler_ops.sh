#!/usr/bin/env bash
# Test: artifact_handler_ops.sh — archive, tidy, ignore, reinit paths
#       and gitignore cleanup logic (Milestone 11)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging and interactive functions
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }
# prompt_confirm: stub always says "no" by default (exit 1); override per-test as needed
prompt_confirm()      { return 1; }
prompt_artifact_menu(){ echo "ignore"; return 0; }

# Stub color variables expected by artifact_handler display helpers
BOLD="" CYAN="" GREEN="" YELLOW="" RED="" NC=""

# Source required libs
# shellcheck source=../lib/artifact_handler_ops.sh
source "${TEKHTON_HOME}/lib/artifact_handler_ops.sh"

# Helper: fresh project directory
make_proj() {
    local name="$1"
    local dir="${TEST_TMPDIR}/${name}"
    mkdir -p "$dir"
    echo "$dir"
}

# =============================================================================
# _archive_artifact_group — file artifact archived correctly
# =============================================================================
echo "=== _archive_artifact_group: file artifact ==="

ARCH_PROJ=$(make_proj "archive_file")
touch "${ARCH_PROJ}/.cursorrules"
ARTIFACT_ARCHIVE_DIR=".claude/archived-ai-config"

_archive_artifact_group "$ARCH_PROJ" "Cursor" ".cursorrules|rules|high"

# Original file should be removed
if [[ -f "${ARCH_PROJ}/.cursorrules" ]]; then
    fail ".cursorrules should be removed from project root after archive"
else
    pass ".cursorrules removed from project root after archive"
fi

# Archive directory should exist
if [[ -d "${ARCH_PROJ}/.claude/archived-ai-config" ]]; then
    pass "Archive directory created"
else
    fail "Archive directory NOT created"
fi

# MANIFEST.md should exist and contain the tool name
if [[ -f "${ARCH_PROJ}/.claude/archived-ai-config/MANIFEST.md" ]]; then
    pass "MANIFEST.md created in archive dir"
else
    fail "MANIFEST.md NOT created in archive dir"
fi

if grep -q "Cursor" "${ARCH_PROJ}/.claude/archived-ai-config/MANIFEST.md"; then
    pass "MANIFEST.md contains tool name 'Cursor'"
else
    fail "MANIFEST.md missing tool name"
fi

# =============================================================================
# _archive_artifact_group — directory artifact archived correctly
# =============================================================================
echo "=== _archive_artifact_group: directory artifact ==="

ARCH_DIR_PROJ=$(make_proj "archive_dir")
mkdir -p "${ARCH_DIR_PROJ}/.cursor"
echo '{"model":"gpt-4"}' > "${ARCH_DIR_PROJ}/.cursor/settings.json"

_archive_artifact_group "$ARCH_DIR_PROJ" "Cursor" ".cursor/|config|high"

# Original directory should be removed
if [[ -d "${ARCH_DIR_PROJ}/.cursor" ]]; then
    fail ".cursor/ should be removed from project root after archive"
else
    pass ".cursor/ removed from project root after archive"
fi

# Archive dir should contain the moved directory (tr '/' '_' → ".cursor_")
dest_name=$(printf '%s' ".cursor/" | tr '/' '_')
if [[ -d "${ARCH_DIR_PROJ}/.claude/archived-ai-config/${dest_name}" ]]; then
    pass ".cursor/ archived as ${dest_name}"
else
    fail ".cursor/ not found in archive as ${dest_name}"
fi

# =============================================================================
# _archive_artifact_group — nonexistent artifact is skipped gracefully
# =============================================================================
echo "=== _archive_artifact_group: nonexistent artifact ==="

ARCH_MISSING_PROJ=$(make_proj "archive_missing")
# Should not error
_archive_artifact_group "$ARCH_MISSING_PROJ" "Cursor" ".cursorrules|rules|high"
pass "_archive_artifact_group handles nonexistent artifact without error"

# =============================================================================
# _archive_artifact_group — multiple calls append to MANIFEST.md
# =============================================================================
echo "=== _archive_artifact_group: MANIFEST.md append ==="

ARCH_MULTI_PROJ=$(make_proj "archive_multi")
touch "${ARCH_MULTI_PROJ}/.cursorrules"
touch "${ARCH_MULTI_PROJ}/.windsurfrules"

_archive_artifact_group "$ARCH_MULTI_PROJ" "Cursor" ".cursorrules|rules|high"
_archive_artifact_group "$ARCH_MULTI_PROJ" "Windsurf" ".windsurfrules|rules|high"

manifest="${ARCH_MULTI_PROJ}/.claude/archived-ai-config/MANIFEST.md"
cursor_count=$(grep -c "Cursor" "$manifest" || true)
windsurf_count=$(grep -c "Windsurf" "$manifest" || true)

if [[ "$cursor_count" -ge 1 ]] && [[ "$windsurf_count" -ge 1 ]]; then
    pass "MANIFEST.md contains entries for both Cursor and Windsurf"
else
    fail "MANIFEST.md missing entries: cursor=${cursor_count} windsurf=${windsurf_count}"
fi

# =============================================================================
# _tidy_artifact_group — removes file in non-interactive mode
# =============================================================================
echo "=== _tidy_artifact_group: non-interactive removal ==="

TIDY_PROJ=$(make_proj "tidy_file")
touch "${TIDY_PROJ}/.cursorrules"

# Non-interactive: ARTIFACT_HANDLING_DEFAULT set skips per-artifact confirmation
ARTIFACT_HANDLING_DEFAULT="tidy"

_tidy_artifact_group "$TIDY_PROJ" "Cursor" ".cursorrules|rules|high"

if [[ ! -f "${TIDY_PROJ}/.cursorrules" ]]; then
    pass ".cursorrules removed by _tidy_artifact_group in non-interactive mode"
else
    fail ".cursorrules should be removed in non-interactive tidy mode"
fi

unset ARTIFACT_HANDLING_DEFAULT

# =============================================================================
# _tidy_artifact_group — removes directory in non-interactive mode
# =============================================================================
echo "=== _tidy_artifact_group: directory removal ==="

TIDY_DIR_PROJ=$(make_proj "tidy_dir")
mkdir -p "${TIDY_DIR_PROJ}/.cursor"
echo '{}' > "${TIDY_DIR_PROJ}/.cursor/settings.json"

ARTIFACT_HANDLING_DEFAULT="tidy"

_tidy_artifact_group "$TIDY_DIR_PROJ" "Cursor" ".cursor/|config|high"

if [[ ! -d "${TIDY_DIR_PROJ}/.cursor" ]]; then
    pass ".cursor/ directory removed by _tidy_artifact_group"
else
    fail ".cursor/ should be removed in non-interactive tidy mode"
fi

unset ARTIFACT_HANDLING_DEFAULT

# =============================================================================
# _tidy_artifact_group — skips nonexistent artifact gracefully
# =============================================================================
echo "=== _tidy_artifact_group: nonexistent artifact ==="

TIDY_MISSING_PROJ=$(make_proj "tidy_missing")
ARTIFACT_HANDLING_DEFAULT="tidy"

# Should not error
_tidy_artifact_group "$TIDY_MISSING_PROJ" "Cursor" ".cursorrules|rules|high"
pass "_tidy_artifact_group handles nonexistent artifact without error"

unset ARTIFACT_HANDLING_DEFAULT

# =============================================================================
# _tidy_gitignore_entry — removes matching entry in interactive mode
# =============================================================================
echo "=== _tidy_gitignore_entry: removes matching entry (interactive) ==="

GI_PROJ=$(make_proj "gitignore_remove")
cat > "${GI_PROJ}/.gitignore" << 'EOF'
node_modules/
dist/
.cursorrules
.env
EOF

# Interactive mode: ARTIFACT_HANDLING_DEFAULT must be empty; prompt_confirm says yes
unset ARTIFACT_HANDLING_DEFAULT 2>/dev/null || true
prompt_confirm() { return 0; }  # Always yes

_tidy_gitignore_entry "$GI_PROJ" ".cursorrules"

if grep -q "\.cursorrules" "${GI_PROJ}/.gitignore"; then
    fail ".cursorrules should be removed from .gitignore in interactive mode"
else
    pass ".cursorrules removed from .gitignore in interactive mode"
fi

# Other entries should be preserved
if grep -q "node_modules/" "${GI_PROJ}/.gitignore" && \
   grep -q "\.env" "${GI_PROJ}/.gitignore"; then
    pass "Other .gitignore entries preserved after tidy"
else
    fail "Other .gitignore entries were incorrectly removed"
fi

# Restore stub
prompt_confirm() { return 1; }

# =============================================================================
# _tidy_gitignore_entry — non-interactive mode skips gitignore cleanup
# =============================================================================
echo "=== _tidy_gitignore_entry: skips cleanup in non-interactive mode ==="

GI_NONINTERACTIVE_PROJ=$(make_proj "gitignore_noninteractive")
cat > "${GI_NONINTERACTIVE_PROJ}/.gitignore" << 'EOF'
node_modules/
.cursorrules
EOF

# Non-interactive mode: ARTIFACT_HANDLING_DEFAULT set → gitignore cleanup is skipped
ARTIFACT_HANDLING_DEFAULT="tidy"

_tidy_gitignore_entry "$GI_NONINTERACTIVE_PROJ" ".cursorrules"

if grep -q "\.cursorrules" "${GI_NONINTERACTIVE_PROJ}/.gitignore"; then
    pass "Gitignore cleanup skipped in non-interactive mode (.cursorrules preserved)"
else
    fail "Gitignore cleanup should be skipped when ARTIFACT_HANDLING_DEFAULT is set"
fi

unset ARTIFACT_HANDLING_DEFAULT

# =============================================================================
# _tidy_gitignore_entry — handles /path prefix in .gitignore (interactive)
# =============================================================================
echo "=== _tidy_gitignore_entry: handles /path prefix ==="

GI_SLASH_PROJ=$(make_proj "gitignore_slash")
cat > "${GI_SLASH_PROJ}/.gitignore" << 'EOF'
node_modules/
/.cursor
.env
EOF

unset ARTIFACT_HANDLING_DEFAULT 2>/dev/null || true
prompt_confirm() { return 0; }  # Always yes

_tidy_gitignore_entry "$GI_SLASH_PROJ" ".cursor/"

# The entry "/.cursor" should be cleaned up (trailing / stripped for pattern)
if grep -q "^/\.cursor" "${GI_SLASH_PROJ}/.gitignore"; then
    fail "/.cursor should be removed from .gitignore"
else
    pass "/.cursor entry removed from .gitignore"
fi

# Restore stub
prompt_confirm() { return 1; }

# =============================================================================
# _tidy_gitignore_entry — no .gitignore present (no-op)
# =============================================================================
echo "=== _tidy_gitignore_entry: no .gitignore ==="

NO_GI_PROJ=$(make_proj "no_gitignore")
touch "${NO_GI_PROJ}/.cursorrules"

# Should not error when .gitignore doesn't exist (regardless of mode)
_tidy_gitignore_entry "$NO_GI_PROJ" ".cursorrules"
pass "_tidy_gitignore_entry no-ops gracefully when .gitignore absent"

# =============================================================================
# _tidy_gitignore_entry — entry NOT in .gitignore (no change)
# =============================================================================
echo "=== _tidy_gitignore_entry: entry not present ==="

GI_NOOP_PROJ=$(make_proj "gitignore_noop")
cat > "${GI_NOOP_PROJ}/.gitignore" << 'EOF'
node_modules/
dist/
EOF

original_content=$(cat "${GI_NOOP_PROJ}/.gitignore")
unset ARTIFACT_HANDLING_DEFAULT 2>/dev/null || true
prompt_confirm() { return 0; }  # Would say yes, but no prompt should fire

_tidy_gitignore_entry "$GI_NOOP_PROJ" ".cursorrules"

new_content=$(cat "${GI_NOOP_PROJ}/.gitignore")
if [[ "$original_content" == "$new_content" ]]; then
    pass ".gitignore unchanged when artifact entry not present"
else
    fail ".gitignore was modified when artifact entry was not present"
fi

# Restore stub
prompt_confirm() { return 1; }

# =============================================================================
# _ignore_artifact_group — produces warning (no files changed)
# =============================================================================
echo "=== _ignore_artifact_group: warning only ==="

IGNORE_PROJ=$(make_proj "ignore_test")
touch "${IGNORE_PROJ}/.cursorrules"

WARN_CALLED=false
warn() { WARN_CALLED=true; }

_ignore_artifact_group "Cursor"

if [[ "$WARN_CALLED" == "true" ]]; then
    pass "_ignore_artifact_group emits a warning"
else
    fail "_ignore_artifact_group should emit a warning"
fi

# File should be untouched
if [[ -f "${IGNORE_PROJ}/.cursorrules" ]]; then
    pass "_ignore_artifact_group leaves .cursorrules in place"
else
    fail "_ignore_artifact_group should NOT remove .cursorrules"
fi

# Restore warn stub
warn() { :; }

# =============================================================================
# _handle_tekhton_reinit — detects pipeline.conf and emits success
# =============================================================================
echo "=== _handle_tekhton_reinit: with pipeline.conf ==="

REINIT_PROJ=$(make_proj "reinit_with_conf")
mkdir -p "${REINIT_PROJ}/.claude"
touch "${REINIT_PROJ}/.claude/pipeline.conf"

SUCCESS_CALLED=false
success() { SUCCESS_CALLED=true; }

_handle_tekhton_reinit "$REINIT_PROJ" ".claude/pipeline.conf|config|high"

if [[ "$SUCCESS_CALLED" == "true" ]]; then
    pass "_handle_tekhton_reinit emits success when pipeline.conf present"
else
    fail "_handle_tekhton_reinit should emit success for pipeline.conf"
fi

# Restore success stub
success() { :; }

# =============================================================================
# _handle_tekhton_reinit — no pipeline.conf in artifacts (no success message)
# =============================================================================
echo "=== _handle_tekhton_reinit: without pipeline.conf ==="

REINIT_NO_CONF=$(make_proj "reinit_no_conf")

SUCCESS_CALLED=false
success() { SUCCESS_CALLED=true; }

_handle_tekhton_reinit "$REINIT_NO_CONF" ".claude/agents/|agents|high"

if [[ "$SUCCESS_CALLED" == "false" ]]; then
    pass "_handle_tekhton_reinit does not emit false success without pipeline.conf"
else
    fail "_handle_tekhton_reinit should NOT claim pipeline.conf preserved when not present"
fi

# Restore success stub
success() { :; }

# =============================================================================
# _handle_tekhton_reinit — MANIFEST present, no pipeline.conf (post-plan)
# =============================================================================
echo "=== _handle_tekhton_reinit: MANIFEST present, no pipeline.conf ==="

REINIT_PLAN_ONLY=$(make_proj "reinit_plan_only")
mkdir -p "${REINIT_PLAN_ONLY}/.claude/milestones"
echo "m01|Setup|pending||m01.md|" > "${REINIT_PLAN_ONLY}/.claude/milestones/MANIFEST.cfg"
# No pipeline.conf — this simulates post-plan, pre-init state

LOG_CALLED=""
log() { LOG_CALLED+="$*"$'\n'; }

_handle_tekhton_reinit "$REINIT_PLAN_ONLY" ".claude/milestones/|milestones|high"

if echo "$LOG_CALLED" | grep -q "completed --plan output"; then
    pass "_handle_tekhton_reinit emits post-plan message when MANIFEST exists without pipeline.conf"
else
    fail "_handle_tekhton_reinit should emit post-plan message for MANIFEST-only state"
fi

# Restore log stub
log() { :; }

# =============================================================================
# _collect_dir_content — collects .md/.json/.yaml from directory
# =============================================================================
echo "=== _collect_dir_content: collects recognized file types ==="

COLLECT_PROJ=$(make_proj "collect_dir")
mkdir -p "${COLLECT_PROJ}/.cursor"
echo '{"model":"gpt-4"}' > "${COLLECT_PROJ}/.cursor/settings.json"
echo "# Rules" > "${COLLECT_PROJ}/.cursor/rules.md"
printf 'key: val\n' > "${COLLECT_PROJ}/.cursor/config.yaml"
# Non-recognized type — should be ignored
echo "binary data" > "${COLLECT_PROJ}/.cursor/data.bin"

collected=""
_collect_dir_content "${COLLECT_PROJ}/.cursor" ".cursor/" "Cursor" "config" collected

if echo "$collected" | grep -q "settings.json"; then
    pass "_collect_dir_content includes .json files"
else
    fail "_collect_dir_content missed settings.json"
fi

if echo "$collected" | grep -q "rules.md"; then
    pass "_collect_dir_content includes .md files"
else
    fail "_collect_dir_content missed rules.md"
fi

if echo "$collected" | grep -q "config.yaml"; then
    pass "_collect_dir_content includes .yaml files"
else
    fail "_collect_dir_content missed config.yaml"
fi

if echo "$collected" | grep -q "data.bin"; then
    fail "_collect_dir_content should NOT include .bin files"
else
    pass "_collect_dir_content ignores .bin files"
fi

if echo "$collected" | grep -q "BEGIN: .cursor/"; then
    pass "_collect_dir_content uses BEGIN: delimiters with relative path"
else
    fail "_collect_dir_content should use BEGIN: delimiters"
fi

# =============================================================================
# _collect_dir_content — empty directory produces no output
# =============================================================================
echo "=== _collect_dir_content: empty directory ==="

EMPTY_DIR_PROJ=$(make_proj "collect_empty")
mkdir -p "${EMPTY_DIR_PROJ}/empty_dir"

collected=""
_collect_dir_content "${EMPTY_DIR_PROJ}/empty_dir" "empty_dir/" "SomeTool" "config" collected

if [[ -z "$collected" ]]; then
    pass "_collect_dir_content produces no output for empty directory"
else
    fail "_collect_dir_content should produce no output for empty dir: got: $collected"
fi

# =============================================================================
# _merge_artifact_group — lazy-load guard fires when render_prompt not in scope
# =============================================================================
echo "=== _merge_artifact_group: render_prompt lazy-load guard ==="

MERGE_PROJ=$(make_proj "merge_guard")
mkdir -p "${MERGE_PROJ}/.cursor"
cat > "${MERGE_PROJ}/.cursor/rules.md" << 'EOF'
# Cursor Rules
Follow best practices.
EOF

# Mock _call_planning_batch to avoid invoking Claude
# We're testing that the guard correctly loads prompts.sh, not the full merge flow
_call_planning_batch() {
    local _model="$1"
    local _max_turns="$2"
    local _prompt="$3"
    local _log_file="$4"
    # Verify that render_prompt was called (by checking if we got a non-empty prompt)
    if [[ -n "$_prompt" ]]; then
        echo "Merge output: extracted useful content"
        return 0
    else
        return 1
    fi
}

# Call _merge_artifact_group WITHOUT having sourced prompts.sh beforehand
# This tests that the lazy-load guard inside _merge_artifact_group fires
_merge_artifact_group "$MERGE_PROJ" "Cursor" ".cursor/|config|high"

# Verify MERGE_CONTEXT.md was created (proves render_prompt was called successfully)
if [[ -f "${MERGE_PROJ}/MERGE_CONTEXT.md" ]]; then
    pass "_merge_artifact_group creates MERGE_CONTEXT.md when render_prompt lazy-load guard fires"
else
    fail "_merge_artifact_group should create MERGE_CONTEXT.md"
fi

# Verify MERGE_CONTEXT.md contains the merge output
if grep -q "Merge output" "${MERGE_PROJ}/MERGE_CONTEXT.md" 2>/dev/null; then
    pass "_merge_artifact_group appends merge output to MERGE_CONTEXT.md"
else
    fail "_merge_artifact_group merge output not found in MERGE_CONTEXT.md"
fi

# Verify log file was created
log_count=$(find "${MERGE_PROJ}/.claude/logs" -name "*artifact-merge.log" 2>/dev/null | wc -l)
if [[ "$log_count" -ge 1 ]]; then
    pass "_merge_artifact_group creates log file in .claude/logs/"
else
    fail "_merge_artifact_group should create log file"
fi

# =============================================================================
# _merge_artifact_group — handles empty artifact gracefully
# =============================================================================
echo "=== _merge_artifact_group: empty artifact handling ==="

MERGE_EMPTY_PROJ=$(make_proj "merge_empty")
mkdir -p "${MERGE_EMPTY_PROJ}/.cursor"
# Empty directory, no files to collect

# Mock again for this test
_call_planning_batch() {
    return 0
}

_merge_artifact_group "$MERGE_EMPTY_PROJ" "Cursor" ".cursor/|config|high"
# Should skip merge gracefully without creating MERGE_CONTEXT.md
# because no readable content was found
pass "_merge_artifact_group skips merge gracefully for empty artifact"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
