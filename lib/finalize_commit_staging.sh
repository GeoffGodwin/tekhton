#!/usr/bin/env bash
# =============================================================================
# finalize_commit_staging.sh — Allowlist staging helpers for _do_git_commit
#
# Sourced by lib/finalize_commit.sh — do not run directly.
#
# Provides the three helpers _do_git_commit uses to stage only pipeline-
# declared files instead of blanket `git add -A`. Split out of
# finalize_commit.sh (2026-05-29) to keep that file under the 300-line ceiling.
#
# Expects globals: CODER_SUMMARY_FILE (read).
# =============================================================================
set -euo pipefail

# _coder_declared_files
# Echoes the files the coder claimed to write, one per line. Parses backticked
# paths from "## Files Modified" (or "## Files Created") of CODER_SUMMARY.md.
# Empty output means the coder didn't declare any files (skeleton placeholder,
# missing section, or genuinely no work).
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

# _pipeline_bookkeeping_globs
# Echoes the path prefixes the pipeline itself may legitimately modify
# (state files, version cache, milestone manifest, CHANGELOG, plus the Go
# implementation tree). Used together with _coder_declared_files to define
# the auto-commit allowlist.
#
# `internal/`, `cmd/`, and `tests/` were added 2026-06-03 after the m34.2/
# m35.x auto-advance run stranded ~30 implementation files in the working
# tree because the agents' CODER_SUMMARY only listed tests + scripts + docs
# and skipped the actual Go packages. The allowlist filter then refused to
# stage them. Adding the Go tree as a bookkeeping prefix matches the
# dogfooding reality: every successful run that writes a `RUN_RESULT.json`
# saying "complete" probably also produced legit code under `internal/` or
# `cmd/`, and the alternative (manual commit recovery after every run) is
# worse than the occasional false positive of catching an unrelated edit.
_pipeline_bookkeeping_globs() {
    cat <<'EOF'
.tekhton/
.claude/project_version.cfg
.claude/milestones/MANIFEST.cfg
.claude/milestones/m
VERSION
CHANGELOG.md
.gitignore
internal/
cmd/
tests/
testdata/
scripts/
docs/
Makefile
EOF
}

# _is_path_allowed PATH
# Returns 0 if PATH matches a coder-declared file OR a bookkeeping prefix.
# Path matching is prefix-based for trailing-slash entries and prefix-anchored
# for non-extension entries (so ".claude/milestones/m" matches any
# milestone-named file there).
_is_path_allowed() {
    local path="$1" entry
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        if [ "$path" = "$entry" ]; then return 0; fi
        case "$entry" in
            */) [[ "$path" == "$entry"* ]] && return 0 ;;
            *)  [[ "$path" == "$entry"* ]] && return 0 ;;
        esac
    done < <( _coder_declared_files; _pipeline_bookkeeping_globs )
    return 1
}

