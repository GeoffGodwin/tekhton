#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# init_config_test_cmd.sh — m42. Ecosystem TEST_CMD fallback for Smart Init.
#
# Sourced by lib/init_config.sh — do not run directly.
#
# Runs only when the upstream detect pipeline returned an empty test command.
# Probes a small set of canonical ecosystem manifests in priority order:
#
#  1. Cargo.toml      → cargo test
#  2. go.mod          → go test ./...
#  3. package.json    → npm test (when scripts.test is present and not the
#                       npm-init placeholder "no test specified")
#  4. pyproject.toml  → pytest
#  5. Gemfile         → bundle exec rspec (only when rspec is referenced)
#  6. mix.exs         → mix test
#  7. pubspec.yaml    → flutter test / dart test
#
# Returns the inferred command on stdout (empty when no manifest is present).
# Confidence is set to "medium" by the caller — the operator should still
# review the value, but it is materially safer than the silent
# `TEST_CMD="true"` default that prompted m42 to exist.
# =============================================================================

# _m42_test_cmd_fallback — Emit the inferred TEST_CMD for a project_dir.
_m42_test_cmd_fallback() {
    local proj="$1"
    if [[ -f "${proj}/Cargo.toml" ]]; then
        echo "cargo test"; return 0
    fi
    if [[ -f "${proj}/go.mod" ]]; then
        echo "go test ./..."; return 0
    fi
    if [[ -f "${proj}/package.json" ]]; then
        # Require scripts.test to be present but not the npm-init placeholder
        # "Error: no test specified". The `.*` after the colon swallows any
        # JSON-escaped quoting (`echo \"Error: no test specified\"`).
        if grep -q '"test"[[:space:]]*:' "${proj}/package.json" 2>/dev/null \
           && ! grep -q '"test"[[:space:]]*:.*no test specified' \
                   "${proj}/package.json" 2>/dev/null; then
            echo "npm test"; return 0
        fi
    fi
    if [[ -f "${proj}/pyproject.toml" ]] \
       || [[ -f "${proj}/setup.py" ]] \
       || [[ -f "${proj}/requirements.txt" ]]; then
        echo "pytest"; return 0
    fi
    if [[ -f "${proj}/Gemfile" ]] && grep -q "rspec" "${proj}/Gemfile" 2>/dev/null; then
        echo "bundle exec rspec"; return 0
    fi
    if [[ -f "${proj}/mix.exs" ]]; then
        echo "mix test"; return 0
    fi
    if [[ -f "${proj}/pubspec.yaml" ]]; then
        if grep -q "^flutter:" "${proj}/pubspec.yaml" 2>/dev/null; then
            echo "flutter test"; return 0
        fi
        echo "dart test"; return 0
    fi
    return 0
}

# _m42_test_cmd_fallback_source — Names the manifest that drove the fallback.
# Re-walks the same precedence list as _m42_test_cmd_fallback; kept as a
# sibling function so the fallback path returns a single value and we don't
# redirect stdout into the config emit.
_m42_test_cmd_fallback_source() {
    local proj="$1"
    [[ -f "${proj}/Cargo.toml"     ]] && { echo "Cargo.toml (m42 fallback)";     return 0; }
    [[ -f "${proj}/go.mod"         ]] && { echo "go.mod (m42 fallback)";         return 0; }
    [[ -f "${proj}/package.json"   ]] && { echo "package.json (m42 fallback)";   return 0; }
    [[ -f "${proj}/pyproject.toml" ]] && { echo "pyproject.toml (m42 fallback)"; return 0; }
    [[ -f "${proj}/setup.py"       ]] && { echo "setup.py (m42 fallback)";       return 0; }
    [[ -f "${proj}/requirements.txt" ]] && { echo "requirements.txt (m42 fallback)"; return 0; }
    [[ -f "${proj}/Gemfile"        ]] && { echo "Gemfile (m42 fallback)";        return 0; }
    [[ -f "${proj}/mix.exs"        ]] && { echo "mix.exs (m42 fallback)";        return 0; }
    [[ -f "${proj}/pubspec.yaml"   ]] && { echo "pubspec.yaml (m42 fallback)";   return 0; }
    return 0
}
