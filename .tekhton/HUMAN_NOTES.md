# Human Notes
<!-- notes-format: v2 -->
<!-- IDs are auto-managed by Tekhton. Do not remove note: comments. -->

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.

Prefix each note with a priority tag so the pipeline can scope runs correctly:
- `[BUG]` — something is broken, needs fixing before new features
- `[FEAT]` — new mechanic or system, architectural work
- `[POLISH]` — visual/UX improvement, no logic changes

## Features

## Bugs
- [ ] [BUG] `tekhton --report` prints literal ANSI escape sequences (e.g. `\033[0;32msuccess\033[0m`, `\033[1;33m2 finding(s)...\033[0m`) instead of colorized text on the Outcome / Coder / Security / Reviewer / Tester lines. The Banner ("Last run: ..."), Scout (no color), and Action items lines render correctly. Repro: `cd <any project with a completed run>; tekhton --report`. Root cause: color constants in `lib/common.sh:21-26` are stored as literal 7-character strings (`RED='\033[0;31m'`, `GREEN='\033[0;32m'`, etc.) — they need `echo -e` or `printf '%b'` to be interpreted as actual ESC bytes. `_out_color` in `lib/output_format.sh:22-25` returns these literals via `printf '%s'`, and `out_msg` in `lib/output_format.sh:55-65` then re-emits them via `printf '%s\n'`, so the literal `\033...` characters reach the terminal unchanged. The other helpers work because they use `echo -e` (`out_banner`) or `printf '%b...%b'` (`out_action_item`, `_out_kv_print`), which interpret the backslash sequences. Affected call sites are all in `lib/report.sh`: `out_msg "  Outcome:   ${outcome_color}${outcome}${nc}"` (line 76), and the analogous lines inside `_report_stage_coder` (193), `_report_stage_security` (217, 219), `_report_stage_reviewer` (235), and `_report_stage_tester` (261, 263). Fix proposal — pick one and apply consistently: (1) change `_out_color` to use `printf '%b'` so it always emits real ESC bytes, which is forward-compatible with both `%s` and `%b`/`echo -e` consumers (lowest-blast-radius change, but verify no caller currently relies on the literal form); (2) change `out_msg` itself to use `printf '%b\n'` (riskier — any legitimate `\` in messages would now be interpreted); or (3) convert the affected `report.sh` call sites to use `out_kv` / `_out_kv_print` (which already use `%b`) or to call `printf '%b...\n'` directly, leaving `out_msg` as a strict plain-text helper. Option (1) is preferred because it fixes the bug at the boundary where color is resolved, without changing the semantics of the generic `out_msg` helper. Add a regression test that runs `tekhton --report` against a fixture run and greps the output for the literal substring `\033[` — should be zero matches.

## Polish
- [ ] [POLISH] The top status bar of Tekhton currently lists the mode (milestone, nb, drift), the pass number (1/5) and the Task. What it doesn't show is the current directory it's working in (project). Let's add the immediate directory name it's being run from next to the Pass count so that we go from the form "fix-nb  ·  Pass 1/5" to the form "fix-nb  ·  Pass 1/5  ·  /name-of-folder" 