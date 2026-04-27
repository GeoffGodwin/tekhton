# Coder Summary

## Status: COMPLETE

## What Was Implemented

M135 — Resilience Arc Artifact Lifecycle Management. Four hygiene fixes
for transient failure artifacts produced by m128–m131:

**Goal 1 — `PREFLIGHT_BAK_DIR` registered in `artifact_defaults.sh`.**
Added a `:=` line so the path is overridable via `pipeline.conf`. The
value is gated on `PROJECT_DIR` being set (`${PROJECT_DIR:+...}`) so
that when `artifact_defaults.sh` is sourced very early (via `common.sh`)
with `PROJECT_DIR` unset, the variable stays empty and m131's existing
`${PREFLIGHT_BAK_DIR:-${proj}/.claude/preflight_bak}` fallback resolves
correctly per-project. Re-sourcing after `load_config` populates it.

**Goal 2 — `.gitignore` entries.** Added `.tekhton/BUILD_FIX_REPORT.md`
and `.claude/preflight_bak/` to the `_gi_entries` array in
`_ensure_gitignore_entries` (`lib/common.sh`). The function's existing
`grep -qF` guard preserves idempotency.

**Goal 3 — `_clear_arc_artifacts_on_success`.** Removes
`LAST_FAILURE_CONTEXT.json`, `BUILD_FIX_REPORT.md`, and
`BUILD_RAW_ERRORS.txt` when a run succeeds, so stale failure context
cannot contaminate `--diagnose` on the next run. Failure runs preserve
all three (they are the primary input to recovery routing). Called from
`_hook_emit_run_summary` on the success branch.

**Goal 4 — `_trim_preflight_bak_dir`.** Caps the size of
`.claude/preflight_bak/` by deleting the lexicographically-oldest
backups, keeping the `${PREFLIGHT_BAK_RETAIN_COUNT:-5}` newest. Setting
`PREFLIGHT_BAK_RETAIN_COUNT=0` disables trimming. The
`<YYYYMMDD_HHMMSS>_<filename>` prefix from m131 makes lexicographic sort
chronological, so no date parsing is needed. m131's existing
`declare -f` guard automatically activates the trim once the function
exists.

## Plan Deviations

**1. Helper placement: `_clear_arc_artifacts_on_success` lives in
`finalize_summary_collectors.sh`, not `finalize_summary.sh`.** The
design said to add it to `finalize_summary.sh` "before
`_hook_emit_run_summary`". Adding it there pushed the file from 287 → 302
lines, breaching the 300-line ceiling (a non-negotiable rule from
`CLAUDE.md`). The collectors sibling already exists for this exact
reason — its header comment states "kept separate so this file stays
under the 300-line ceiling". The function is sourced via the existing
`source finalize_summary_collectors.sh` line in `finalize_summary.sh`,
so the call from `_hook_emit_run_summary` works unchanged. Final sizes:
`finalize_summary.sh` 290, `finalize_summary_collectors.sh` 191 — both
under 300.

**2. `PREFLIGHT_BAK_DIR` `:=` form.** The design's literal form
`: "${PREFLIGHT_BAK_DIR:=${PROJECT_DIR:-.}/.claude/preflight_bak}"`
fails when `artifact_defaults.sh` is sourced with `PROJECT_DIR` set to
an unrelated value (e.g., the tekhton repo root inherited via env, as
happens in the resilience-arc test harness). The variable gets baked to
the wrong path and m131 uses it verbatim. Used `${PROJECT_DIR:+...}`
instead so the variable stays empty until `PROJECT_DIR` is meaningfully
set, allowing m131's existing fallback to resolve correctly. The
m120 self-heal pattern (re-source after `load_config`) populates the
final value once `PROJECT_DIR` is the project's actual root.

**3. Test harness fix in `test_resilience_arc_integration.sh`.** Added
`unset PROJECT_DIR PREFLIGHT_BAK_DIR` at the top of the test file
(before sourcing `common.sh`). Without this, the test's parent shell
inherits `PROJECT_DIR` from the user's environment, baking the wrong
path into `PREFLIGHT_BAK_DIR` at source time. This is a fixture-level
hermiticity fix directly motivated by m135's new `:=` line.

## Files Modified

- `lib/artifact_defaults.sh` — added `PREFLIGHT_BAK_DIR` `:=` line.
- `lib/common.sh` — added 2 new entries to the `_gi_entries` array in
  `_ensure_gitignore_entries`.
- `lib/finalize_summary.sh` — added 1-line call to
  `_clear_arc_artifacts_on_success` on the success branch of
  `_hook_emit_run_summary`; added a 2-line comment pointer to the
  collectors sibling.
- `lib/finalize_summary_collectors.sh` — added
  `_clear_arc_artifacts_on_success` function (per Plan Deviation 1).
- `lib/preflight_checks.sh` — added `_trim_preflight_bak_dir` function
  under a new "Check 5: Preflight backup retention (m135)" header.
- `tests/test_ensure_gitignore_entries.sh` — added 2 entries to
  `EXPECTED_ENTRIES` (T1–T2 of the milestone).
- `tests/test_resilience_arc_integration.sh` — sourced
  `lib/preflight_checks.sh`; added Scenario group 8 (T3–T9) for
  artifact lifecycle and preflight_bak retention; added top-of-file
  `unset PROJECT_DIR PREFLIGHT_BAK_DIR` for hermeticity (per Plan
  Deviation 3).

## Human Notes Status

N/A — no human notes for this task.

## Docs Updated

None — no public-surface changes in this task. `PREFLIGHT_BAK_DIR` is a
new artifact-path config key but the design assigns its `pipeline.conf`
documentation to m136 ("Resilience Arc Config Defaults & Validation
Hardening"). Same for `PREFLIGHT_BAK_RETAIN_COUNT` registration in
`config_defaults.sh`. `_trim_preflight_bak_dir` and
`_clear_arc_artifacts_on_success` are private helpers (no leading
public function); they do not appear in `ARCHITECTURE.md`.

## Verification

- `shellcheck tekhton.sh lib/*.sh stages/*.sh` — clean (exit 0).
- `bash tests/test_resilience_arc_integration.sh` — 71 passed, 0 failed.
- `bash tests/test_ensure_gitignore_entries.sh` — 47 passed, 0 failed.
- `bash tests/test_preflight_ui_config.sh` — 46 passed, 0 failed.
- `bash tests/test_finalize_run.sh` — 108 passed, 0 failed.
- `bash tests/test_m132_run_summary_enrichment.sh` — 16 passed, 0 failed.
- `bash tests/run_tests.sh` — 467 shell + 247 python passed, 0 failed
  (one initial flake on `test_watchtower_parallel_groups_datalist.sh`
  that resolved on re-run; the test passes standalone and is unrelated
  to the changes here).
- File line counts: `artifact_defaults.sh` 58, `common.sh` 251,
  `finalize_summary.sh` 290, `finalize_summary_collectors.sh` 191,
  `preflight_checks.sh` 254 — all under 300.
