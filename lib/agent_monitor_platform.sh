#!/usr/bin/env bash
# =============================================================================
# agent_monitor_platform.sh — Platform detection and Windows process management
#
# Extracted from agent_monitor.sh. Detects whether claude is a Windows-native
# binary (WSL interop or MSYS2/MINGW) and provides _kill_agent_windows() for
# reliable process termination via taskkill.exe.
#
# Sourced by agent.sh before agent_monitor.sh.
# =============================================================================
set -euo pipefail

# GNU coreutils timeout supports --kill-after; macOS/BSD does not. Detect once.
_TIMEOUT_KILL_AFTER_FLAG=""
if command -v timeout &>/dev/null && timeout --help 2>&1 | grep -q 'kill-after'; then
    _TIMEOUT_KILL_AFTER_FLAG="--kill-after=60"
fi

# Windows-native claude.exe doesn't receive POSIX signals from MSYS2/WSL interop.
# When detected, the abort handler uses taskkill.exe to terminate the process.
_AGENT_WINDOWS_CLAUDE=false
_claude_path="$(command -v claude 2>/dev/null || true)"

if grep -qiE 'microsoft|WSL' /proc/version 2>/dev/null; then
    if echo "${_claude_path:-}" | grep -qiE '(/mnt/c/|\.exe$|AppData|Program)'; then
        _AGENT_WINDOWS_CLAUDE=true
        warn "[agent] WARNING: claude appears to be a Windows binary running via WSL interop."
        warn "[agent] To fix: install claude natively in WSL (npm install -g @anthropic-ai/claude-code)."
    fi
elif uname -s 2>/dev/null | grep -qiE 'MINGW|MSYS'; then
    if [ -n "${_claude_path:-}" ]; then
        _AGENT_WINDOWS_CLAUDE=true
    fi
fi

# taskkill.exe reliably terminates Windows-native processes ignoring POSIX signals.
_kill_agent_windows() {
    if [ "$_AGENT_WINDOWS_CLAUDE" != true ]; then
        return
    fi
    local _tk=""
    if command -v taskkill.exe &>/dev/null; then
        _tk="taskkill.exe"
    elif command -v taskkill &>/dev/null; then
        _tk="taskkill"
    else
        return
    fi

    # Try PID-based kill first (more precise, avoids killing unrelated claude instances)
    if [ -n "${_TEKHTON_AGENT_PID:-}" ]; then
        $_tk //F //PID "$_TEKHTON_AGENT_PID" //T 2>/dev/null || true
    fi
    # Fall back to image-name kill to catch child processes the PID kill might miss
    # //F = force, //T = kill process tree, //IM = by image name.
    $_tk //F //IM claude.exe //T 2>/dev/null || true
}
