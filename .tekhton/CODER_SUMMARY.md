# Coder Summary

## Status: COMPLETE

## What Was Implemented

- Fixed `check_bash_version()` in `install.sh` (lines 122–141) to use the defined `fail()` helper instead of the undefined `error()` function
- Restructured the function to print helpful instructions (Homebrew install steps for macOS, upgrade message for other platforms) before calling `fail()` which prints the error and exits with code 1
- Updated version references from "bash 4+" to "bash 4.3+" in the error messages to match the actual Tekhton requirement
- Removed the dead `exit 1` at the end of the if-block (now unreachable since `fail()` exits)

## Root Cause (bugs only)

`check_bash_version()` at install.sh:122 called `error()` (lines 127, 137) which was never defined. The defined helpers are `info()`, `ok()`, `warn()`, and `fail()` (lines 36–39). Under `set -euo pipefail`, the undefined command caused the script to crash with "error: command not found" instead of displaying the helpful macOS Homebrew instructions and cleanly exiting. The fix replaces `error()` with `fail()` (which prints a formatted error message to stderr and exits 1), with the informational messages printed before the `fail()` call so they're visible to the user.

## Files Modified

- `install.sh` — replaced undefined `error()` calls with `fail()` in `check_bash_version()`, updated version strings to "4.3+"

## Human Notes Status

- COMPLETED: [BUG] README.md lies about macOS being zero-setup. Update — Verified: README.md:102 already says "Bash 4.3+" with macOS warning, `brew install bash`, and link to `docs/getting-started/installation.md#macos`. Quick Start callout at line 115 is present. Bash floor is consistently "4.3+" across README.md, CLAUDE.md, and docs/getting-started/installation.md. All items from this note were addressed in a prior run.

## Observed Issues (out of scope)

- `install.sh` is 558 lines, exceeding the 300-line ceiling. It was already over the limit before this change. A future milestone should split it into logical sections (e.g., extract platform detection, PATH setup, and download functions into separate files).
