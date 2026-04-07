#### Milestone 23: Dry-Run & Preview Mode
<!-- milestone-meta
id: "23"
status: "done"
-->

Add a `--dry-run` execution mode that runs the scout and intake agents,
shows what the pipeline WOULD do, and caches the results. The next actual
run can continue from the cached dry-run instead of re-running scout and
intake, ensuring the preview matches the execution. This builds trust with
new users and helps experienced users scope work before committing turns.

Files to create:
- `lib/dry_run.sh` — Dry-run orchestration and caching:
  **Execution** (`run_dry_run(task)`):
  1. Run intake gate (M10) → produce INTAKE_REPORT.md with verdict + confidence
  2. Run scout agent → produce SCOUT_REPORT.md with file list + estimates
  3. Summarize: estimated files to modify, estimated complexity, intake verdict,
     security-relevant files flagged, milestone scope assessment
  4. Cache results to `${TEKHTON_SESSION_DIR}/dry_run_cache/`:
     - INTAKE_REPORT.md (cached copy)
     - SCOUT_REPORT.md (cached copy)
     - DRY_RUN_META.json: task hash, git HEAD sha, timestamp, cache TTL
  5. Print formatted preview to terminal:
  ```
  ══════════════════════════════════════
    Tekhton — Dry Run Preview
  ══════════════════════════════════════
    Task:       Add user authentication
    Intake:     PASS (confidence 85)

    Scout identified 14 files:
      Modified:  src/api/routes.ts, src/middleware/auth.ts, ...
      New:       src/services/auth-service.ts, tests/auth.test.ts
      Estimated: ~20 turns (coder), 2 review cycles

    Security-relevant: YES (auth, middleware changes)

    Continue with full run? [y/n]
  ══════════════════════════════════════
  ```
  6. If user says yes: set DRY_RUN_CONTINUE=true, return to main flow
  7. If user says no: save state for later `tekhton --continue-preview`

  **Cache validation** (`validate_dry_run_cache(task)`):
  Returns 0 (valid) when ALL conditions met:
  - Cache exists and is non-empty
  - Task hash matches (same task string)
  - Git HEAD sha matches (no code changes since dry-run)
  - Cache age < DRY_RUN_CACHE_TTL (default: 1 hour)
  Returns 1 (invalid) and logs reason when any condition fails.

  **Cache consumption** (`consume_dry_run_cache()`):
  Called at the start of a real run when valid cache exists:
  - Copy cached SCOUT_REPORT.md to the active session directory
  - Copy cached INTAKE_REPORT.md to the active session directory
  - Set SCOUT_CACHED=true so the coder stage skips re-running scout
  - Set INTAKE_CACHED=true so the intake gate skips re-running
  - Log: "Using cached dry-run results (scout + intake from Xm ago)"
  - Delete cache after consumption (one-use)

Files to modify:
- `tekhton.sh` — Add flag handling:
  - `--dry-run` → Run `run_dry_run(task)` instead of `_run_pipeline_stages`
  - `--continue-preview` → Load cached dry-run, skip to coder stage
  At pipeline startup (before stage execution), call
  `validate_dry_run_cache()`. If valid, offer to use it:
  "Found cached dry-run from 12m ago. Use cached scout results? [y/n/fresh]"
  If yes: `consume_dry_run_cache()`. If no/fresh: discard cache, run normally.
  Source lib/dry_run.sh.

- `stages/coder.sh` — When SCOUT_CACHED=true, skip scout agent invocation
  and read SCOUT_REPORT.md directly. Log: "Scout: using cached results."
  The coder prompt assembly reads SCOUT_REPORT.md the same way regardless
  of whether it came from cache or a live run.

- `stages/intake.sh` (M10) — When INTAKE_CACHED=true, skip intake agent
  invocation and read INTAKE_REPORT.md directly. If cached verdict was
  NEEDS_CLARITY, still pause (user may have answered clarifications since
  the dry-run). If cached verdict was TWEAKED, apply the tweaks.

- `lib/config_defaults.sh` — Add:
  DRY_RUN_CACHE_TTL=3600 (seconds, default 1 hour),
  DRY_RUN_CACHE_DIR="${TEKHTON_SESSION_DIR}/dry_run_cache".

- `lib/state.sh` — Add dry-run state to pipeline state persistence.
  `--continue-preview` loads the cached state and resumes.

- `lib/dashboard.sh` (M13) — Emit dry-run results to Watchtower data
  when a dry-run completes.

Acceptance criteria:
- `tekhton --dry-run "task"` runs scout + intake only, no coder/security/review/test
- Terminal preview shows: task, intake verdict, file list, estimates, security flag
- Results cached to session directory with task hash + git sha + timestamp
- Cache validated on next actual run: task match, git HEAD match, TTL check
- Valid cache consumed by next run: scout and intake skip re-running
- Invalid cache (code changed, task changed, expired) is discarded with log message
- `--continue-preview` loads cached dry-run and starts from coder stage
- Interactive "Continue with full run? [y/n]" at end of dry-run
- Cache is one-use: consumed and deleted after real run starts
- When M10 (intake) not yet enabled, dry-run shows scout results only
- When no stages produce meaningful preview data, dry-run says so and suggests
  running the full pipeline instead of silently producing empty output
- All existing tests pass
- `bash -n lib/dry_run.sh` passes
- `shellcheck lib/dry_run.sh` passes

Watch For:
- The scout is non-deterministic — the whole point of caching is that the
  preview matches the execution. The cache MUST be invalidated on ANY code
  change (git HEAD check), not just task changes.
- Cache TTL is 1 hour by default. For fast-moving repos with frequent
  commits, this may be too long. The git HEAD check handles this naturally
  (any commit invalidates), but branch switches should also invalidate.
- `--dry-run` in --milestone mode should preview the ACTIVE milestone,
  not require a task string. Detect milestone mode and read the milestone
  file as the task context.
- The scout's estimated complexity (turns, review cycles) is a rough
  heuristic. Label it clearly as "estimated" to set expectations.
- `--dry-run` should NOT count against quota or autonomous loop limits.
  It's a preview, not a pipeline run.

Seeds Forward:
- Dry-run cache pattern is reusable for other pre-computation (e.g.,
  caching repo map generation for fast startup)
- The preview format feeds into Watchtower's "upcoming work" view
- `--continue-preview` pattern seeds future "staged execution" where
  users approve each stage before it runs

Migration impact:
- New config keys: DRY_RUN_CACHE_TTL, DRY_RUN_CACHE_DIR
- New files in .claude/: dry_run_cache/ directory (transient, auto-cleaned)
- Breaking changes: NONE
- Migration script update required: NO — new feature only
