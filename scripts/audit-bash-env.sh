#!/usr/bin/env bash
# scripts/audit-bash-env.sh — m27.1 unguarded-env-read audit.
#
# Scans `.sh` files for bash variable reads of the m26 StageEnvV1 contract
# that are NOT defaulted under `set -u`. A bare `${VAR}` or `$VAR` will
# trigger `unbound variable` if the producer hasn't exported it; `${VAR:-}`,
# `${VAR-}`, `${VAR:+}`, `${VAR+}`, `${VAR:=}`, `${VAR=}`, `${VAR:?}`, and
# `${VAR?}` are all safe.
#
# The allowlist of names we flag is the union of:
#   1. The `StageEnvV1` runtime-flag + log-channel fields hand-emitted by
#      `internal/runner/env.go:AsKV` — captured below as `_STAGE_ENV_KEYS`.
#   2. Every pipeline.conf key declared in `internal/config/defaults.go`,
#      fetched dynamically via `tekhton config defaults --emit shell` so
#      this audit stays in sync automatically when new defaults land.
# A `# WARNING:` line is emitted on stderr and a hardcoded fallback set
# is used when the `tekhton` binary is not on PATH (fresh clone, etc).
#
# Output format — one finding per line, grep-able:
#   <file>:<line>:<varname>
#
# Exit codes:
#   0 = no findings (clean)
#   1 = one or more unguarded reads detected
#
# Usage:
#   scripts/audit-bash-env.sh                   # scan lib/ + stages/
#   scripts/audit-bash-env.sh path/to/file.sh   # scan a single file
#   scripts/audit-bash-env.sh dir1/ dir2/       # scan multiple targets
#
# Portability:
#   The matcher is implemented in `awk` for portability (BSD awk on macOS
#   does not support `grep -P` either, but POSIX awk is universal). No
#   `pcregrep` or `grep -P` is required.

set -euo pipefail

# --- Resolve repo root + binary -------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

_resolve_tekhton_bin() {
    if [[ -n "${TEKHTON_BIN:-}" ]] && [[ -x "${TEKHTON_BIN}" ]]; then
        printf '%s\n' "${TEKHTON_BIN}"
        return 0
    fi
    local candidate
    for candidate in "${REPO_ROOT}/tekhton" "${REPO_ROOT}/bin/tekhton"; do
        if [[ -x "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    if command -v tekhton >/dev/null 2>&1; then
        command -v tekhton
        return 0
    fi
    return 1
}

# --- StageEnvV1 hardcoded keys --------------------------------------------
# Source of truth: internal/runner/env.go:AsKV. Re-sync this list when
# a new field is added there.
_STAGE_ENV_KEYS=(
    MILESTONE_MODE
    _CURRENT_MILESTONE
    TASK
    AUTO_ADVANCE
    AUTO_ADVANCE_LIMIT
    HUMAN_MODE
    HUMAN_NOTES_TAG
    LOG_DIR
    TIMESTAMP
    LOG_FILE
    TEKHTON_SESSION_DIR
)

# --- Pipeline.conf key fetcher --------------------------------------------
# Pulls every key from `tekhton config defaults --emit shell`. Falls back
# to a minimal set of historically-known hot keys on stderr-warning when
# the binary is not on PATH.
_pipeline_conf_keys() {
    local bin
    if bin="$(_resolve_tekhton_bin)"; then
        "${bin}" config defaults --emit shell 2>/dev/null \
            | sed -nE 's/^export ([A-Z_][A-Z0-9_]*)=.*/\1/p' \
            | sort -u
        return 0
    fi
    printf '# WARNING: tekhton binary not found; using hardcoded fallback allowlist\n' >&2
    # Minimal hardcoded fallback — the production allowlist is much larger,
    # but this is enough to make the script exit-code-correct on a fresh
    # clone where `make build` has not been run yet.
    cat <<'EOF'
ARCHITECTURE_FILE
BUILD_ERRORS_FILE
CLAUDE_CODER_MODEL
CLAUDE_STANDARD_MODEL
CODER_MAX_TURNS
DRIFT_LOG_FILE
HUMAN_NOTES_FILE
MAX_REVIEW_CYCLES
MILESTONE_DIR
MILESTONE_MANIFEST
PIPELINE_ORDER
PROJECT_DIR
PROJECT_NAME
REPO_MAP_ENABLED
REVIEWER_REPORT_FILE
TEKHTON_DIR
TEKHTON_HOME
TESTER_REPORT_FILE
TEST_CMD
EOF
}

# --- Build combined allowlist (newline-separated) -------------------------
_build_allowlist() {
    printf '%s\n' "${_STAGE_ENV_KEYS[@]}"
    _pipeline_conf_keys
}

# --- Resolve targets -------------------------------------------------------
# Output paths are printed verbatim — callers can pass relative paths to get
# relative output ("lib/foo.sh:123:VAR") or absolute paths to get absolute
# output. Default-scan resolves `lib/` and `stages/` relative to REPO_ROOT
# (cd into REPO_ROOT) so the default invocation always emits the milestone-
# documented "<dir>/<file>:<line>:<varname>" format.
_resolve_targets() {
    if [[ $# -gt 0 ]]; then
        local t
        for t in "$@"; do
            if [[ -f "${t}" ]]; then
                printf '%s\n' "${t}"
            elif [[ -d "${t}" ]]; then
                find "${t}" -type f -name '*.sh' -print | sort
            else
                printf '# WARNING: target not found: %s\n' "${t}" >&2
            fi
        done
        return 0
    fi
    # Default: lib/ + stages/ relative to REPO_ROOT (cd ensures the output
    # paths are short and grep-friendly even when invoked from elsewhere).
    cd -- "${REPO_ROOT}"
    if [[ -d "lib" ]]; then
        find "lib" -type f -name '*.sh' -print | sort
    fi
    if [[ -d "stages" ]]; then
        find "stages" -type f -name '*.sh' -print | sort
    fi
}

# --- Awk matcher -----------------------------------------------------------
# Reads file paths from argv, allowlist from ALLOWLIST env (newline-sep).
# Tracks single-quoted-heredoc state across lines, skips `#` comment-only
# lines, and inspects each `$NAME` / `${NAME...` occurrence:
#   - `${NAME}` (closing brace immediately after name) → flag if in allow.
#   - `${NAME[:?+=-]...}` (any guard suffix after name) → safe; skip.
#   - `$NAME` (bare, no braces)                        → flag if in allow.
#   - `\$NAME` (backslash-escaped)                     → skip.
_scan_files() {
    awk '
        BEGIN {
            # Read allowlist from environment.
            n = split(ENVIRON["ALLOWLIST"], keys, "\n")
            for (i = 1; i <= n; i++) {
                if (keys[i] != "") allow[keys[i]] = 1
            }
            findings = 0
        }

        # Reset per-file state.
        FNR == 1 {
            in_heredoc = 0
            heredoc_re = ""
        }

        # Inside a single-quoted heredoc — no expansion happens; skip until
        # the closing tag line.
        in_heredoc {
            if ($0 ~ heredoc_re) {
                in_heredoc = 0
                heredoc_re = ""
            }
            next
        }

        {
            line = $0

            # Heredoc-start detection: only single-quoted form skips
            # expansion. <<TAG and <<"TAG" still expand vars.
            if (match(line, /<<-?[ \t]*'\''[A-Za-z_][A-Za-z0-9_]*'\''/)) {
                m = substr(line, RSTART, RLENGTH)
                tag = m
                sub(/^<<-?[ \t]*'\''/, "", tag)
                sub(/'\''$/, "", tag)
                in_heredoc = 1
                # <<- allows leading tabs before the close tag; standard
                # form requires the tag to start at column 1.
                if (substr(m, 1, 3) == "<<-") {
                    heredoc_re = "^[\t]*" tag "[ \t]*$"
                } else {
                    heredoc_re = "^" tag "[ \t]*$"
                }
                # Strip the heredoc opener so we still scan ${VAR} that
                # appears before <<EOF on the same line.
                line = substr(line, 1, RSTART - 1)
            }

            # Comment-only line: first non-whitespace char is `#`.
            if (line ~ /^[ \t]*#/) next

            # Scan the line for variable references.
            scan_pos_offset = 0
            rest = line
            while (1) {
                # Match $NAME or ${NAME (greedy on identifier).
                p = match(rest, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)
                if (p == 0) break
                m = substr(rest, RSTART, RLENGTH)
                m_start = RSTART
                m_end = RSTART + RLENGTH  # 1-based index of char after match

                # Backslash-escaped: \$VAR → literal, no expansion.
                if (m_start > 1 && substr(rest, m_start - 1, 1) == "\\") {
                    rest = substr(rest, m_end)
                    continue
                }

                if (substr(m, 2, 1) == "{") {
                    name = substr(m, 3)
                    after = substr(rest, m_end, 1)
                    if (after == "}") {
                        if (name in allow) {
                            print FILENAME ":" FNR ":" name
                            findings++
                        }
                    }
                    # else: ${NAME:- / ${NAME- / ${NAME+ / ${NAME:= / ...
                    # — all guard forms are safe under set -u.
                } else {
                    name = substr(m, 2)
                    if (name in allow) {
                        print FILENAME ":" FNR ":" name
                        findings++
                    }
                }

                rest = substr(rest, m_end)
            }
        }

        END {
            exit (findings == 0 ? 0 : 1)
        }
    ' "$@"
}

# --- Main ------------------------------------------------------------------
main() {
    local allowlist
    allowlist="$(_build_allowlist)"

    local explicit_args=$#
    local -a targets=()
    while IFS= read -r line; do
        [[ -n "${line}" ]] && targets+=("${line}")
    done < <(_resolve_targets "$@")

    if [[ "${#targets[@]}" -eq 0 ]]; then
        # Nothing to scan — treat as clean.
        exit 0
    fi

    # _resolve_targets ran in a process-substitution subshell so its `cd`
    # didn't leak. For the default-scan case, the emitted paths are
    # relative to REPO_ROOT, so we cd there now to make them resolvable.
    if [[ "${explicit_args}" -eq 0 ]]; then
        cd -- "${REPO_ROOT}"
    fi

    ALLOWLIST="${allowlist}" _scan_files "${targets[@]}"
}

main "$@"
