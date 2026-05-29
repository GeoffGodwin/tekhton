# Reviewer Report — m28.3 (Stale-Config Migration + Tests)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/mcp_resolve.sh` (new file, line 14) carries `set -euo pipefail` despite being a sourced `lib/` file. The shell quality rule is explicit: sourced files in `lib/` do not include `set -euo pipefail` — they inherit from the caller. The line is functionally redundant here (already set by the time `mcp.sh` sources this file) but is technically a rule violation for a new file. Pre-existing in `mcp.sh` too; a future hygiene pass should sweep both files.
- `tests/test_serena_template_substitution.sh::count_backups` (lines 71–74): the `# shellcheck disable=SC2010` comment refers to `ls | grep` but the implementation uses `find | wc -l`. SC2010 would never trigger here; the disable comment is stale. Harmless but misleading to a future reader.

## Coverage Gaps
- None

## Drift Observations
- `lib/mcp_resolve.sh:14` — new sourced lib file carries `set -euo pipefail`, same pre-existing pattern as `lib/mcp.sh:18`. Convention reserves this for standalone entry points. Two instances now in the same module family; a hygiene sweep should clear both.
