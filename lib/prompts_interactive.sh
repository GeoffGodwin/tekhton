#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# prompts_interactive.sh — Interactive prompt helpers
#
# Provides prompt_confirm, prompt_choice, and prompt_input for user interaction.
# All functions support /dev/tty interaction with non-interactive fallbacks.
#
# Sourced by init.sh
# =============================================================================

# _can_prompt — Check whether interactive prompts are possible.
# Returns 0 if /dev/tty is both present and readable (i.e. there is a real
# controlling terminal). The previous check `[[ -c /dev/tty ]]` always
# succeeds on Linux because the device node exists regardless of whether
# the process has a controlling terminal.
_can_prompt() {
    [[ -t 0 ]] && return 0
    # /dev/tty exists as a device but may not be openable (CI, piped stdin, etc.)
    [[ -r /dev/tty ]] && [[ -w /dev/tty ]] 2>/dev/null && return 0
    return 1
}

# prompt_confirm — Ask a yes/no question with a default. Reads from /dev/tty.
# Args: $1 = question, $2 = default ("y" or "n", default: "y")
# Returns: 0 for yes, 1 for no
# Falls back to default when /dev/tty is unavailable (non-interactive mode)
# or when TEKHTON_NON_INTERACTIVE=true (e.g. during tests).
prompt_confirm() {
    local question="$1"
    local default="${2:-y}"
    local hint="[Y/n]"
    [[ "$default" = "n" ]] && hint="[y/N]"

    # Non-interactive fallback — use default
    if [[ "${TEKHTON_NON_INTERACTIVE:-}" = "true" ]] || ! _can_prompt; then
        [[ "${default,,}" = "y" ]]
        return $?
    fi

    local answer
    printf '%s %s ' "$question" "$hint" >/dev/tty
    read -r answer </dev/tty || answer=""
    answer="${answer:-$default}"
    [[ "${answer,,}" = "y" || "${answer,,}" = "yes" ]]
}

# prompt_choice — Present a numbered menu and return the selection.
# Args: $1 = question, $2... = options
# Prints: the selected option text to stdout
# Returns: 0 on valid selection
# Falls back to first option when /dev/tty is unavailable (non-interactive mode).
prompt_choice() {
    local question="$1"
    shift
    local options=("$@")
    local count=${#options[@]}

    # Non-interactive fallback — return first option
    if [[ "${TEKHTON_NON_INTERACTIVE:-}" = "true" ]] || ! _can_prompt; then
        echo "${options[0]}"
        return 0
    fi

    echo "$question" >/dev/tty
    local i
    for i in "${!options[@]}"; do
        printf '  %d) %s\n' "$(( i + 1 ))" "${options[$i]}" >/dev/tty
    done

    local selection
    while true; do
        printf 'Choice [1-%d]: ' "$count" >/dev/tty
        read -r selection </dev/tty || { echo "${options[0]}"; return 0; }
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le "$count" ]]; then
            echo "${options[$(( selection - 1 ))]}"
            return 0
        fi
        echo "  Invalid choice. Enter a number between 1 and ${count}." >/dev/tty
    done
}

# prompt_input — Ask for free-text input with an optional default. Reads from /dev/tty.
# Args: $1 = prompt text, $2 = default value (optional)
# Prints: user input (or default) to stdout
# Falls back to default when /dev/tty is unavailable (non-interactive mode).
prompt_input() {
    local prompt_text="$1"
    local default="${2:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" [${default}]"

    # Non-interactive fallback — use default
    if [[ "${TEKHTON_NON_INTERACTIVE:-}" = "true" ]] || ! _can_prompt; then
        echo "${default}"
        return 0
    fi

    local answer
    printf '%s%s: ' "$prompt_text" "$hint" >/dev/tty
    read -r answer </dev/tty || answer=""
    echo "${answer:-$default}"
}
