# Reviewer Report

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/notes_core.sh` is 327 lines — reduced from 399 by the extraction but still over the 300-line soft ceiling. Further extraction opportunity exists (e.g. the claim/resolve API into a separate `notes_claim.sh`).
- `lib/dashboard_emitters.sh` is 623 lines — the new `emit_dashboard_notes` function adds ~100 lines to a file already well over the ceiling. Consider extracting the new function to a `dashboard_emitters_notes.sh` companion in a future cleanup pass.
- `emit_dashboard_notes` (dashboard_emitters.sh:573): `local j=$(( i + 1 ))` combines declaration and arithmetic — shellcheck SC2155 may flag this. Prefer `local j; j=$(( i + 1 ))`.
- `emit_dashboard_notes` (dashboard_emitters.sh:576): `(( j++ ))` in a `set -e` context is safe here because `j` starts at `i + 1 >= 1`, but the pattern is subtle. A brief comment would help the next reader.

## Coverage Gaps
- None

## Drift Observations
- `lib/finalize.sh:_hook_resolve_notes` (lines 114–129): when `CLAIMED_NOTE_IDS` is non-empty AND orphan `[~]` notes remain after the first `resolve_notes_batch` call, the legacy fallback path calls `resolve_human_notes`, which calls `resolve_notes_batch` a second time with the same IDs. The second call is a no-op (those notes are already transitioned) but the double invocation is redundant. Harmless, low priority.
