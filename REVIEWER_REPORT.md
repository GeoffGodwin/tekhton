# Reviewer Report — Milestone 24: Run Safety Net & Rollback
Review cycle: 2 of 4

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/checkpoint.sh` is 344 lines — 44 over the 300-line soft ceiling. Consider extracting `show_checkpoint_info` into a `checkpoint_display.sh` (following the `finalize_display.sh` pattern) in a future cleanup pass.
- `create_run_checkpoint` (line 99) and `update_checkpoint_commit` (line 136) create tmpfiles via `mktemp` without a `trap ... EXIT` cleanup guard. Under `set -euo pipefail`, a write failure leaves a stale `checkpoint.XXXXXX` file in `.claude/`. Same pattern as the LOW security finding flagged in `init_config.sh`.
- `--rollback` early-exit path in `tekhton.sh` hardcodes `CHECKPOINT_ENABLED` and `CHECKPOINT_FILE` defaults inline rather than sourcing `config_defaults.sh`. If these defaults change in `config_defaults.sh`, the rollback fallback path silently diverges.
- `git checkout -- .` and `git clean -fd` in the no-commit rollback path (lines 212-214) operate on CWD, not explicitly on `PROJECT_DIR`. Consistent with how the stash was created (`-- .`), but requires the user to invoke `--rollback` from the same directory as the original run. A comment would help future readers understand this assumption.

## Coverage Gaps
- No tests for the `rollback_last_run` safety check edge case where `current_head != commit_sha` — the most critical path for this safety-net feature and a regression risk after any fix.
- No test coverage for `show_checkpoint_info` age calculation on macOS/BSD where `date -d` is unavailable. The `2>/dev/null || echo "0"` fallback silently degrades to `age_str="unknown"` — acceptable but undocumented.

## Drift Observations
- `lib/checkpoint.sh` defines `_ckpt_read_field`/`_ckpt_read_bool` helpers to parse CHECKPOINT_META.json, but the `--status` block in `tekhton.sh` duplicates the same JSON extraction inline with its own `sed` patterns. Once `checkpoint.sh` is sourced in the main pipeline path, `--status` should delegate to the shared helpers to avoid two parsing implementations for the same file.

## Prior Blocker Verification
- `lib/checkpoint.sh:189-197` — **FIXED**. The nested two-condition guard (`parent_of_head == commit_sha` loophole) has been collapsed into a single unconditional `if [[ "$current_head" != "$commit_sha" ]]` check. Any commit on top of the pipeline commit — including exactly one user commit — is now rejected and directs the user to `git revert` manually. The fix matches the prescribed resolution exactly.
