# Coder Summary
## Status: COMPLETE
## What Was Implemented
- Added early bash version guard in `tekhton.sh` (lines 60–79) that runs before any bash 4+ syntax is executed, giving users a clear error message instead of a cryptic `declare: -g: invalid option` crash
- Promoted `install.sh` bash version check from warning to hard fail (`exit 1`) so users cannot complete installation with an incompatible bash
- Updated `README.md` Requirements section to explicitly state macOS requires setup (not zero-config)

## Root Cause (bugs only)
`tekhton.sh` lacked an early bash version guard. When run under bash 3.2 (macOS default), the script would proceed until `lib/common.sh:162` hit `declare -gA`, producing a cryptic `declare: -g: invalid option` error. Additionally, `install.sh` only warned about bash < 4 instead of failing, allowing users to complete installation with an incompatible shell version.

## Files Modified
- `tekhton.sh` — Added 17-line bash version guard after `set -euo pipefail`, before crash diagnostics trap setup. Uses only bash 3.2-compatible syntax. Detects macOS via `uname -s` and provides platform-specific Homebrew instructions.
- `install.sh` — Changed `check_bash_version()` from `warn` to `error` + `exit 1` on bash < 4
- `README.md` — Rewrote Requirements line to say "macOS requires setup" instead of burying the requirement in a parenthetical

## Human Notes Status
- COMPLETED: [BUG] Promote install.sh:125 bash-version warning to a hard
- COMPLETED: [BUG] README.md lies about macOS being zero-setup. Update
