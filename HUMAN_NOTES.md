# Human Notes

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.

Prefix each note with a priority tag so the pipeline can scope runs correctly:
- `[BUG]` — something is broken, needs fixing before new features
- `[FEAT]` — new mechanic or system, architectural work
- `[POLISH]` — visual/UX improvement, no logic changes


## Features
None currently.

## Bugs
- [ ] [BUG] Fix Watchtower Reports and Trends tabs (three bugs)
  1. `lib/dashboard_emitters.sh:155-156` — `grep -c ... || echo "0"` produces `"0\n0"` when zero matches found (grep -c outputs "0" but exits 1, triggering the fallback which appends a second "0"). Fix: use `|| true` instead of `|| echo "0"` and add `: "${var:=0}"` fallback, matching the pattern already used on line 149 for audit_verdict.
  2. `lib/dashboard_parsers.sh:159-163` — `_parse_run_summaries` Python parser reads `total_turns` and `total_time_s` but RUN_SUMMARY.json uses `total_agent_calls` and `wall_clock_seconds`. Fix: fall back to the actual field names: `d.get('total_turns', d.get('total_agent_calls', 0))` and `d.get('total_time_s', d.get('wall_clock_seconds', 0))`. Apply same fix to the grep fallback on lines 175-177.
  3. Both the Python path and grep fallback in `_parse_run_summaries` also miss the `milestone` and `stages` fields from the actual JSON — the grep fallback doesn't extract them at all. Low priority since the Python path covers most environments.
- [ ] [BUG] Fix the failing Tekhton self test: test_coder_stage_split_wiring.sh