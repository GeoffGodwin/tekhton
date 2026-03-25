# Reviewer Report — Milestone 25: Human Notes UX Enhancement (Cycle 2)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/notes_cli.sh` remains ~395 lines, exceeding the 300-line soft ceiling. Consider extracting file-write helpers into `notes_cli_write.sh` in a future cleanup pass.
- `list_human_notes_cli()` still uses `output+="...\n"` / `echo -e "$output"`. A direct `printf` per line would be more portable and avoid the large single-variable allocation.

## Coverage Gaps
- No self-tests for `notes_cli.sh` functions. At minimum, `get_notes_summary` (pipe-delimited contract relied on by `finalize_display.sh` and `dashboard_emitters.sh`) and `add_human_note` section-insertion logic should have tests in `tests/`.

## Drift Observations
- `lib/notes_cli.sh:98-121` and `lib/notes_cli.sh:300-311` create tmpfiles via `mktemp` with no `trap ... EXIT INT TERM` cleanup guard. Mirrors the `init_config.sh` pattern flagged by the security agent — worth addressing both together in a future cleanup pass.
- `lib/finalize_display.sh` and `lib/dashboard_emitters.sh` guard `get_notes_summary` with `command -v get_notes_summary &>/dev/null`. Since `notes_cli.sh` is always sourced via tekhton.sh, this guard is never false — a short comment explaining the defensive intent would help future readers.

## Prior Blocker Resolution
- FIXED: `lib/notes_cli.sh` double-increment of `total` for untagged notes. Lines 180–182 no longer contain a second `total` increment — the `*` branch now only appends to the output string. Count is correct.
