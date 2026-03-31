# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-31 | "M42"] `lib/notes_acceptance.sh:259-264` — `local _code` and `local _msg` declared inside `while` loop body. `local` is function-scoped in bash so this is valid, but placing declarations inside a loop is unconventional. Move declarations before the loop.
- [ ] [2026-03-31 | "M42"] `lib/dashboard_emitters.sh:625-637` — `reviewer_skipped` per-note metadata is extracted from note HTML comments, but `_store_acceptance_result` only writes the `acceptance` key. Nothing in M42 writes `reviewer_skipped` to note metadata, so this dashboard field will always be empty string. The run-level `REVIEWER_SKIPPED` env var is correctly captured in metrics.jsonl; only the per-note dashboard display is missing this signal.
- [ ] [2026-03-31 | "M42"] `lib/notes_acceptance.sh:95-111` — `check_feat_acceptance()` uses `grep -qF "$_dir"` to check directory presence. `-F` matches as a substring, so `_dir="cli"` would match a line `"src/cli"` in `_common_dirs` (false negative). Rare edge case.
- [ ] [2026-03-31 | "M42"] `lib/notes_acceptance.sh:60-65` — `_new_files` concatenation from `git ls-files --others` and `git diff --cached --name-only --diff-filter=A` can produce duplicates. A `sort -u` before the while loop would prevent duplicate warnings.
- [ ] [2026-03-30 | "M41"] `lib/notes_triage.sh` is 589 lines — nearly 2x the 300-line soft ceiling. The file is logically partitioned (heuristics, agent escalation, promotion flow, pipeline integration, report) and could be split into `notes_triage_core.sh` + `notes_triage_flow.sh`.
- [ ] [2026-03-30 | "M41"] `lib/notes_triage.sh:170` — `$(date +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)` falls back to the identical command. The fallback is a no-op; if the intent is a timezone-safe fallback, the two calls should differ.
- [ ] [2026-03-30 | "M41"] `lib/notes_triage.sh:226-229` — Template variables (`TRIAGE_NOTE_TEXT`, `TRIAGE_NOTE_TAG`, etc.) are exported into the environment and never unset after agent escalation. Consistent with the pipeline's existing pattern, but worth noting for future cleanup.

## Resolved
