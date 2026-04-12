# Coder Summary
## Status: COMPLETE
## What Was Implemented
- Clarified Express Mode "zero-config" description in README.md (two locations) to note that macOS users must still install bash 4.3+ via Homebrew before running Tekhton
- Standardized bash version floor from "4+" to "4.3+" in docs/getting-started/installation.md (three locations: macOS warning note, Linux section, Windows section)
- Standardized bash version floor from "4+" to "4.3+" in docs/troubleshooting/common-errors.md error message heading

## Root Cause (bugs only)
Express Mode was described as "zero-config execution" without noting that macOS users still require bash 4.3+ (via Homebrew) before anything will work — misleading macOS users into thinking no setup is needed. Additionally, several doc pages used "bash 4+" instead of the accurate "bash 4.3+" floor, inconsistent with README.md, CLAUDE.md, and install.sh which all specify 4.3+.

## Files Modified
- `README.md` — Added macOS caveat to both Express Mode mentions (lines 74 and 763)
- `docs/getting-started/installation.md` — Standardized "bash 4+" → "bash 4.3+" in three places (macOS warning, Linux section, Windows section)
- `docs/troubleshooting/common-errors.md` — Standardized error message heading from "bash 4+" to "bash 4.3+"

## Human Notes Status
No human notes were injected for this task.

## Observed Issues (out of scope)
- `.claude/agents/coder.md:14` — says "Bash 4+" instead of "Bash 4.3+"
- `.claude/agents/coder.md:29` — says "Bash 4+ only — no bashisms beyond bash 4" instead of "4.3+"
- `.claude/agents/architect.md:15` — says "Bash 4+" instead of "Bash 4.3+"
- `.claude/agents/jr-coder.md:14` — says "Bash 4+" instead of "Bash 4.3+"
