# Drift Log

## Metadata
- Last audit: 2026-03-30
- Runs since audit: 5

## Unresolved Observations
- [2026-03-31 | "M42"] `stages/coder.sh:115` and `stages/coder.sh:527` — both independently use `grep -oP 'est_turns:K[0-9]+'` to read triage metadata from HUMAN_NOTES.md. M41 introduced this pattern; M42 duplicates it. A `_read_note_metadata_field()` helper in `lib/notes_core.sh` would centralize this.
- [2026-03-30 | "M41"] `lib/notes_triage.sh:46-48` — Uses `echo "$lower_text" | grep -qE "$ind"` for regex matching. The `printf '%s ' "$lower_text"` form is the shellcheck-preferred pattern for piping variables (avoids edge cases where `$lower_text` starts with `-`). Low-impact given typical note text, but worth noting for consistency with the rest of the codebase.
- [2026-03-30 | "Address all 4 open non-blocking notes in NON_BLOCKING_LOG.md. Fix each item and note what you changed."] `lib/finalize.sh:_hook_resolve_notes` (lines 114–129): when `CLAIMED_NOTE_IDS` is non-empty AND orphan `[~]` notes remain after the first `resolve_notes_batch` call, the legacy fallback path calls `resolve_human_notes`, which calls `resolve_notes_batch` a second time with the same IDs. The second call is a no-op (those notes are already transitioned) but the double invocation is redundant. Harmless, low priority.
- [2026-03-30 | "M40"] `notes.sh:claim_human_notes` (line 67) archives HUMAN_NOTES.md to `${LOG_DIR}/${TIMESTAMP}_HUMAN_NOTES.md` immediately before calling `claim_notes_batch()`, which performs the identical `cp` to the same destination internally (notes_core.sh:277-279). The double archive is harmless but dead — the first copy is always overwritten by the second. The archive logic should live exclusively in `claim_notes_batch()` and the duplicate `cp` in `claim_human_notes()` should be removed.
- [2026-03-30 | "architect audit"] **`lib/dashboard_parsers.sh:236–239` and shell fallback — duration estimation dead code (obs 1 and 3)** The observation is explicitly conditional: "worth a cleanup note *when `_STAGE_DURATION` coverage is confirmed complete*." That condition is not yet met. Current coverage of `_STAGE_DURATION`:
- [2026-03-30 | "architect audit"] **Populated:** `intake`, `scout`, `coder`, `security`, `reviewer`, `tester_write`, `tester`
- [2026-03-30 | "architect audit"] **Not populated:** `build_gate`, `architect`, `cleanup` The turn-proportional estimation fallback in `dashboard_parsers.sh:236–239` (Python) and lines `~326–336` (shell) exists for legacy JSONL records that predate per-stage duration tracking. It remains correct behavior for any run that did not emit `*_duration_s` fields. Removing it now would corrupt historical trend data. When `_STAGE_DURATION` coverage is confirmed complete (all active stages emit durations every run), re-open this as a dead code removal. At that point it is a two-block deletion with a corresponding test update in `test_duration_estimation_jsonl.sh` and `test_duration_estimation_shell_fallback.sh`. **Note:** `lib/finalize_summary.sh:153` and `lib/finalize_summary.sh:169` contain the same hardcoded stage list pattern as `metrics.sh:107` and also omit `tester_write`. This is a related staleness issue not reported in the current drift log. It can be bundled with the `metrics.sh` fix in the same jr coder pass since the files are adjacent and the fix is identical in structure.
(none)

## Resolved
