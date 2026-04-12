# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in ${REVIEWER_REPORT_FILE}.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-12 | "[BUG] Add early bash version guard in tekhton.sh. Insert a"] `tekhton.sh:64` — Guard checks `BASH_VERSINFO[0] -lt 4` but the error message and CLAUDE.md state the requirement is bash 4.3+. Users with bash 4.0–4.2 (major == 4, minor < 3) will pass the guard and then crash on `declare -gA` (added in bash 4.2; `declare -g` added in bash 4.2, full associative support stable in 4.3). The missing minor-version check means the guard doesn't fully enforce the stated requirement. Bash 4.0–4.2 is a decade old and essentially nonexistent in the wild, but the condition and the error message are inconsistent. A fix: `[ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }`.
- [x] [2026-04-12 | "[BUG] Add early bash version guard in tekhton.sh. Insert a"] `install.sh:129,137` — `check_bash_version()` error messages say "Tekhton requires bash 4+" while `tekhton.sh` says "bash 4.3+". Minor inconsistency introduced by this change — both should state the same minimum.
- [ ] [2026-04-12 | "M73"] `_normalize_markdown_blank_runs()` (`lib/notes_core_normalize.sh:30`) silently drops a single blank line that appears immediately before a fenced code block: `blank_pending = 0` is set by the fence handler before the pending blank is emitted, so a lone blank before ``` is lost. The spec says "collapse runs of ≥ 2 blank lines to one" — a single blank should survive. Low-risk edge case in practice (carried from cycle 1).
<!-- Items added here by the pipeline. Mark [x] when addressed. -->

## Resolved
