#!/usr/bin/env bash
# =============================================================================
# finalize_commit_staging.sh — Staging filter helpers for _do_git_commit
#
# Sourced by lib/finalize_commit.sh — do not run directly.
#
# S1 (2026-06-14): switched from an ALLOWLIST to a DENYLIST. The old model
# staged only files matching `_coder_declared_files ∪ _pipeline_bookkeeping_globs`
# and silently dropped everything else. Because the bookkeeping globs listed
# internal/, cmd/, tests/, docs/ but NOT lib/, stages/, prompts/, platforms/,
# any change to the bash pipeline tree the coder didn't explicitly declare was
# stranded in the working tree (observed: lib/quota_probe.sh dropped across two
# "successful" milestone commits). It also made the commit file-set diverge
# from the m27 acceptance file-set — a milestone could be accepted on a change
# that was then never committed.
#
# The denylist commits every dirty path EXCEPT pure transients (logs, the
# session dir, generated venvs). This makes the commit file-set == the
# substantive working-tree set m27 measures, by construction. The targeted
# protection that motivated the old allowlist (a stage agent corrupting
# MANIFEST.cfg) is preserved by _check_manifest_write_guard in finalize_commit.sh.
#
# Expects globals: CODER_SUMMARY_FILE (read), TEKHTON_SESSION_DIR (read).
# =============================================================================
set -euo pipefail

# _coder_declared_files
# Echoes the files the coder claimed to write, one per line. Parses backticked
# paths from "## Files Modified" (or "## Files Created") of CODER_SUMMARY.md.
# Retained for commit-message construction and diagnostics; no longer the
# staging gate. Empty output means the coder didn't declare any files.
_coder_declared_files() {
    local f="${CODER_SUMMARY_FILE:-.tekhton/CODER_SUMMARY.md}"
    [ -f "$f" ] || return 0
    awk '
        /^## Files ([Cc]reated|[Mm]odified)/ { found=1; next }
        found && /^## / { exit }
        found { print }
    ' "$f" 2>/dev/null \
        | grep -oE "\`[^\`]+\`" \
        | sed "s/^\`//;s/\`\$//" \
        | grep -vE '^\(fill|^N\/A$|^None$' \
        | sort -u \
        || return 0
}

# _commit_transient_globs
# Echoes the path prefixes the pipeline writes that must NEVER be auto-committed
# — pure run transients with no source value. Everything NOT matching one of
# these is committable. Kept deliberately small: adding a path here strands it,
# which is the failure mode S1 exists to prevent.
#
# Note: .tekhton/ (run reports/state) and .claude/milestones/ (manifest +
# milestone files) are intentionally NOT here — the pipeline versions those.
# The session dir IS emitted as its repo-relative path prefix (it usually lives
# under .tekhton/, which is otherwise committable) so its scratch files are not
# swept into the commit. An absolute session dir simply never matches a
# repo-relative git path, which is harmless.
_commit_transient_globs() {
    cat <<'EOF'
.claude/logs/
.claude/indexer-venv/
.claude/serena/
EOF
    local sd="${TEKHTON_SESSION_DIR:-}"
    sd="${sd#./}"
    [ -n "$sd" ] && printf '%s/\n' "${sd%/}"
}

# _is_path_committable PATH
# Returns 0 (commit it) UNLESS PATH matches a transient prefix, in which case
# returns 1 (skip). All entries are directory prefixes.
_is_path_committable() {
    local path="$1" entry
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        [[ "$path" == "$entry"* ]] && return 1
    done < <( _commit_transient_globs )
    return 0
}
