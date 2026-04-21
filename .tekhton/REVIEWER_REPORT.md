# Reviewer Report — M112: Pre-Run Dedup Coverage Hardening

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `stages/coder_prerun.sh:69` and `stages/tester_fix.sh:164` — new dedup skip-event guards use `command -v emit_event &>/dev/null` while every other emit_event check in both files uses `declare -f emit_event &>/dev/null`. Both succeed for bash functions but `declare -f` is canonical and is the pattern used throughout the codebase. Align for consistency.

## Coverage Gaps
- None

## Drift Observations
- `stages/coder_prerun.sh:69`, `stages/tester_fix.sh:164` — `command -v` used to guard a shell function call; all other guard sites in the same files use `declare -f`. Mixed idioms for the same pattern accumulate over time and signal an implicit convention question worth resolving in a cleanup pass.
