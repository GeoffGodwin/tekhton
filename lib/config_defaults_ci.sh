#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# config_defaults_ci.sh — Runtime CI environment auto-detection (M138)
#
# Sourced by lib/config_defaults.sh immediately before the m136 arc config
# block. Provides three helpers used to default
# TEKHTON_UI_GATE_FORCE_NONINTERACTIVE based on the *current* process env:
#   _detect_runtime_ci_environment  — pure-bash CI signal detector
#   _get_ci_platform_name           — human-readable platform name for logs
#   _apply_ci_ui_gate_defaults      — source-time defaulter; replaces m136's
#                                     simple ":=0" for TEKHTON_UI_GATE_FORCE_NONINTERACTIVE
#
# Lives in its own file so config_defaults.sh remains data-only under the
# 300-line exemption and so future arc milestones can re-invoke
# _apply_ci_ui_gate_defaults from a harness without re-sourcing all defaults.
# =============================================================================

# _detect_runtime_ci_environment
# Returns 0 if the current process is running inside a CI/CD system.
# Returns 1 if no CI signals are found.
# Detection is pure-bash (no subshells, no file I/O, no external commands).
_detect_runtime_ci_environment() {
    [[ "${GITHUB_ACTIONS:-}"          == "true" ]] && return 0
    [[ "${GITLAB_CI:-}"               == "true" ]] && return 0
    [[ "${CIRCLECI:-}"                == "true" ]] && return 0
    [[ "${TRAVIS:-}"                  == "true" ]] && return 0
    [[ "${BUILDKITE:-}"               == "true" ]] && return 0
    [[ -n "${JENKINS_URL:-}"                    ]] && return 0
    [[ -n "${TF_BUILD:-}"                       ]] && return 0   # Azure DevOps
    [[ -n "${TEAMCITY_VERSION:-}"               ]] && return 0
    [[ -n "${BITBUCKET_BUILD_NUMBER:-}"         ]] && return 0
    # Generic fallback: most platforms also export CI=true. Checked last so the
    # named-platform branches above can give callers a precise platform name.
    [[ "${CI:-}" == "true" ]] && return 0
    return 1
}

# _get_ci_platform_name
# Returns a human-readable CI platform name for log messages.
# Caller should invoke _detect_runtime_ci_environment first; this helper
# returns "unknown" when no CI signal is present.
_get_ci_platform_name() {
    [[ "${GITHUB_ACTIONS:-}"          == "true" ]] && echo "GitHub Actions"      && return
    [[ "${GITLAB_CI:-}"               == "true" ]] && echo "GitLab CI"           && return
    [[ "${CIRCLECI:-}"                == "true" ]] && echo "CircleCI"            && return
    [[ "${TRAVIS:-}"                  == "true" ]] && echo "Travis CI"           && return
    [[ "${BUILDKITE:-}"               == "true" ]] && echo "Buildkite"           && return
    [[ -n "${JENKINS_URL:-}"                    ]] && echo "Jenkins"             && return
    [[ -n "${TF_BUILD:-}"                       ]] && echo "Azure DevOps"        && return
    [[ -n "${TEAMCITY_VERSION:-}"               ]] && echo "TeamCity"            && return
    [[ -n "${BITBUCKET_BUILD_NUMBER:-}"         ]] && echo "Bitbucket Pipelines" && return
    [[ "${CI:-}"                      == "true" ]] && echo "CI (generic)"        && return
    echo "unknown"
}

# _apply_ci_ui_gate_defaults
# Source-time defaulter for TEKHTON_UI_GATE_FORCE_NONINTERACTIVE.
#
# Invariant: an explicit pipeline.conf value (including =0) always wins.
# _CONF_KEYS_SET is populated by _parse_config_file before config_defaults.sh
# is sourced, so it lists exactly the keys the user wrote into pipeline.conf.
# Membership check on that set is the authoritative "user-set?" test — do not
# re-read the file.
#
# Side effects:
#   - Exports TEKHTON_UI_GATE_FORCE_NONINTERACTIVE (0 or 1)
#   - Exports TEKHTON_CI_ENVIRONMENT_DETECTED (0 or 1; diagnostic-only)
#   - Emits a single stderr line when VERBOSE_OUTPUT=true and auto-elevation fired
_apply_ci_ui_gate_defaults() {
    if [[ " ${_CONF_KEYS_SET:-} " != *" TEKHTON_UI_GATE_FORCE_NONINTERACTIVE "* ]] \
       && _detect_runtime_ci_environment; then
        TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1
        TEKHTON_CI_ENVIRONMENT_DETECTED=1
        if [[ "${VERBOSE_OUTPUT:-false}" == "true" ]]; then
            echo "[tekhton] CI environment detected ($(_get_ci_platform_name)) — TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 (auto)" >&2
        fi
    else
        : "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:=0}"
        TEKHTON_CI_ENVIRONMENT_DETECTED=0
    fi

    export TEKHTON_UI_GATE_FORCE_NONINTERACTIVE
    export TEKHTON_CI_ENVIRONMENT_DETECTED
}
