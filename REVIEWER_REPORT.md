# Reviewer Report — M36: Watchtower Interactive Controls

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/inbox.sh:86-88` — The guard `[[ "$basename" == manifest_append_* ]]` in `_process_milestone()` is dead code: the function is only called from the `milestone_*.md` glob loop, which cannot match `manifest_append_*`. Safe to remove.
- `lib/dashboard_emitters.sh:303` — Similarly, `[[ "$basename" != manifest_append_* ]]` in `emit_dashboard_inbox()` is dead code for the same reason (the enclosing glob is `milestone_*.md`).
- `lib/inbox.sh:65-75` — `_process_note()` silently drops the description, priority, and source fields when calling `add_human_note()`. Only the title is written to HUMAN_NOTES.md. This is consistent with how the flat checklist works, but worth documenting as a known limitation.
- `lib/dashboard_emitters.sh:280-331` — `emit_dashboard_inbox()` does not enumerate `manifest_append_*.cfg` files in the pending display. When a milestone is submitted via the UI, users will see the `.md` entry but not the associated `.cfg` entry. Minor UX gap; acceptable since they are submitted as a pair.
- `tools/watchtower_server.py:45` — The 100KB payload limit is a hard-coded magic number; could be a CLI arg for future extensibility, but acceptable at this scope.

## Coverage Gaps
- `shellcheck` and `bash -n` passes for `lib/inbox.sh` were not independently verified during review (tool execution was unavailable). The tester should run `shellcheck lib/inbox.sh` and `bash -n lib/inbox.sh` as part of acceptance gating.
- `tools/watchtower_server.py` smoke test: tester should verify `python3 tools/watchtower_server.py --help` runs without error and the `/api/ping` endpoint returns `{"ok": true}` when the server is running.
- No test covers the `_process_note()` → `add_human_note()` integration path (note file read from fixture inbox dir and appended to HUMAN_NOTES.md). A unit test for `process_watchtower_inbox()` with a populated fixture inbox would close this gap.

## ACP Verdicts
- ACP: Watchtower Inbox Directory — **ACCEPT** — The `.claude/watchtower_inbox/` convention is well-motivated, backward compatible (no-op when absent), and follows the existing `.claude/` staging pattern. ARCHITECTURE.md update needed as noted.
- ACP: New `lib/inbox.sh` Library — **ACCEPT** — Correctly scoped single-entry-point library. Source order in `tekhton.sh` is correct (`notes_cli.sh` at line 699, `inbox.sh` at line 749), so `add_human_note()` is always available. The `command -v` guard provides safe fallback. ARCHITECTURE.md Layer 3 update needed.

## Drift Observations
- `lib/inbox.sh:103`, `lib/dashboard_emitters.sh:85`, and `lib/milestone_dag.sh` all independently construct the manifest path as `${MILESTONE_DIR:-...}/${MILESTONE_MANIFEST:-MANIFEST.cfg}`. This same two-part path expression is repeated in at least three files. A shared `_manifest_path()` helper would eliminate the drift in a future cleanup pass.
