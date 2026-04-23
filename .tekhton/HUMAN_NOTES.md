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
- [x] [BUG] Acceptance-criteria quality lint is emitted at end-of-run in lib/milestone_acceptance.sh (check_milestone_acceptance) so warnings are non-actionable. Move lint execution earlier to authoring paths: lib/draft_milestones_write.sh (during draft validation) and/or a pre-run validation hook before coder starts; keep milestone acceptance focused on pass/fail gates. Lint implementation is in lib/milestone_acceptance_lint.sh. <!-- note:n01 created:2026-04-21 priority:medium source:cli triage:fit est_turns:3 text_hash:1655021538 triaged:2026-04-23 -->
- [x] [BUG] Auto-advance milestone UI state leak: in --auto-advance, milestone 2+ starts with all TUI pills already green because completed-stage state carries over. Reset per-milestone TUI completion data on transition in lib/orchestrate_helpers.sh (_run_auto_advance_chain) before re-entering run_complete_loop; reset helper/state likely belongs in lib/tui.sh or lib/tui_ops.sh (_TUI_STAGES_COMPLETE and related stage-progress fields). Add/extend coverage in tests/test_tui_multipass_lifecycle.sh. <!-- note:n02 created:2026-04-23 priority:high source:manual triage:fit est_turns:6 text_hash:1965384908 triaged:2026-04-23 -->
- [x] [BUG] GitHub Pages/release workflow checkout fails with `fatal: no url found for submodule path '.claude/worktrees/agent-a049075c' in .gitmodules` because the repo tree contains a committed gitlink at `.claude/worktrees/agent-a049075c` (mode 160000) but no `.gitmodules` entry. Root cause is accidental tracking of a local git worktree under `.claude/worktrees/` (not currently ignored). Triage/fix: remove the gitlink from index/history tip (`git rm --cached .claude/worktrees/agent-a049075c`), add `.claude/worktrees/` to `.gitignore`, and add a CI guard that fails if `git ls-files --stage` contains mode 160000 paths outside approved submodules. <!-- note:n03 created:2026-04-23 priority:high source:manual triage:fit est_turns:3 text_hash:3011429055 triaged:2026-04-23 -->

## Polish
