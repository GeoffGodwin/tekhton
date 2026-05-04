#### Milestone 24: Run Safety Net & Rollback
<!-- milestone-meta
id: "24"
status: "done"
-->

Add a pre-run git checkpoint and `--rollback` command that lets users
cleanly revert the last pipeline run. This is a critical safety net for
new users who aren't comfortable with git recovery, and for experienced
users who want a quick undo when the pipeline produces bad results.

Files to create:
- `lib/checkpoint.sh` — Git checkpoint management:
  **Create checkpoint** (`create_run_checkpoint()`):
  Called at the very start of pipeline execution (before scout/intake).
  1. Check for uncommitted changes. If any exist:
     - `git stash push -m "tekhton-checkpoint-${TIMESTAMP}"` to save them
     - Record stash ref in CHECKPOINT_META.json
  2. Record current HEAD sha in CHECKPOINT_META.json
  3. If previous checkpoint exists and is unused, warn: "Previous checkpoint
     exists — overwriting (only the most recent run is rollback-able)"
  4. Write CHECKPOINT_META.json to `.claude/`:
     ```json
     {
       "timestamp": "2024-03-23T10:45:00Z",
       "head_sha": "abc123",
       "had_uncommitted": true,
       "stash_ref": "stash@{0}",
       "task": "Add user authentication",
       "milestone": "m03",
       "auto_committed": false,
       "commit_sha": null
     }
     ```
  5. Log: "Checkpoint created — use `tekhton --rollback` to undo this run"

  **Update checkpoint** (`update_checkpoint_commit(commit_sha)`):
  Called after auto-commit or manual commit during finalization.
  Updates CHECKPOINT_META.json with `auto_committed: true` and
  `commit_sha`. This is needed so rollback knows to revert the commit.

  **Rollback** (`rollback_last_run()`):
  1. Read CHECKPOINT_META.json. If missing: "No checkpoint found — nothing
     to rollback."
  2. If auto_committed: `git revert --no-edit ${commit_sha}` (creates a
     revert commit, non-destructive). Show what was reverted.
  3. If NOT auto_committed: `git checkout -- .` to discard uncommitted
     changes back to checkpoint HEAD. Warn about unstaged changes.
  4. If stash_ref exists: `git stash pop ${stash_ref}` to restore the
     pre-run uncommitted changes.
  5. Remove CHECKPOINT_META.json (checkpoint consumed).
  6. Clean up pipeline state files (PIPELINE_STATE.md, session dir).
  7. Print summary:
  ```
  ✓ Rollback complete
    Reverted: commit abc123 ("Add user auth middleware")
    Restored: 3 uncommitted files from pre-run state
    Pipeline state: cleared
  ```

  **Checkpoint info** (`show_checkpoint_info()`):
  For `--rollback --check`. Shows what would be rolled back without doing it:
  - What commit would be reverted (if auto-committed)
  - What files would be restored
  - Whether pre-run stash would be restored
  - Age of checkpoint

  **Safety checks:**
  - Rollback refuses if the current HEAD is NOT the commit_sha or its
    immediate successor (someone else committed on top). Prints:
    "Cannot rollback — commits have been made after the pipeline run.
    Use `git revert ${commit_sha}` manually."
  - Rollback refuses if there are uncommitted changes that would be lost.
    Prints: "Uncommitted changes detected. Stash or commit them first."
  - Rollback is ALWAYS a clean git operation (revert, checkout, stash pop).
    NEVER uses `git reset --hard` or any destructive force operation.

Files to modify:
- `tekhton.sh` — Add flag handling:
  - `--rollback` → Run `rollback_last_run()` and exit
  - `--rollback --check` → Run `show_checkpoint_info()` and exit
  Add `create_run_checkpoint()` call at pipeline startup, BEFORE stage
  execution begins (after config load, after argument parsing, before
  scout/intake). Source lib/checkpoint.sh.

- `lib/finalize.sh` — After auto-commit or manual commit, call
  `update_checkpoint_commit($commit_sha)` to record the commit in the
  checkpoint metadata. This enables clean revert.

- `lib/config_defaults.sh` — Add:
  CHECKPOINT_ENABLED=true (enabled by default — safety net should be on),
  CHECKPOINT_FILE=".claude/CHECKPOINT_META.json".

- `lib/state.sh` — Include checkpoint info in `--status` output so the
  user knows a rollback is available.

- `lib/dashboard.sh` (M13) — Include checkpoint status in Watchtower:
  "Last run rollback available: Yes (12m ago, commit abc123)"

Acceptance criteria:
- Checkpoint created automatically at pipeline start (before any agent runs)
- Pre-existing uncommitted changes are stashed with tekhton-specific message
- CHECKPOINT_META.json records: timestamp, HEAD sha, stash ref, task, milestone
- After auto-commit, checkpoint updated with commit sha
- `tekhton --rollback` reverts auto-committed changes via `git revert`
- `tekhton --rollback` restores pre-run uncommitted changes from stash
- `tekhton --rollback --check` shows what would be rolled back without acting
- Rollback refuses when additional commits exist after the pipeline run
- Rollback refuses when uncommitted changes would be lost
- Rollback NEVER uses `git reset --hard` or destructive operations
- Only one checkpoint exists at a time (most recent run only)
- When CHECKPOINT_ENABLED=false, no checkpoint created, --rollback disabled
- `tekhton --status` shows checkpoint availability
- All existing tests pass
- `bash -n lib/checkpoint.sh` passes
- `shellcheck lib/checkpoint.sh` passes

Watch For:
- `git stash` behavior with untracked files: by default `git stash` only
  stashes tracked files. Use `git stash push --include-untracked` to also
  save new files the user created but hasn't committed.
- `git revert` creates a new commit. This is intentional — it's
  non-destructive and preserves history. The user can see what was
  reverted and why.
- The stash ref (`stash@{0}`) may shift if the user manually stashes
  between the checkpoint and rollback. Record the stash message string
  and find it by message, not index: `git stash list | grep tekhton-checkpoint`.
- Monorepo users may have changes in directories outside the project.
  Checkpoint should only stash changes within PROJECT_DIR, not the entire
  repo. Use `git stash push -- .` (current directory scope).
- If the pipeline crashes mid-run (no finalization), the checkpoint still
  exists but auto_committed will be false. Rollback should handle this
  gracefully (just discard uncommitted changes, restore stash).

Seeds Forward:
- Checkpoint metadata feeds into --diagnose (M17): "Last run was rolled back"
- The pattern is reusable for future "safe experiment" mode where the
  pipeline works on a branch and merges only on success
- Watchtower can show rollback history for project health trends

Migration impact:
- New config keys: CHECKPOINT_ENABLED, CHECKPOINT_FILE
- New files in .claude/: CHECKPOINT_META.json (transient, auto-managed)
- Breaking changes: NONE
- Migration script update required: NO — new feature only
