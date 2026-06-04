# Reviewer Report — m43 (Version-bump completeness)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/project_version_bump_helpers.sh:79–131` — `_bump_single_file`'s `*` catch-all uses `head -c 1` JSON detection to route through `_bump_json_version`, but `_accessor_for_file` (used by `verify_version_files_synced`) returns `plaintext` for the same filename. A user who manually declares a non-conventional JSON filename in VERSION_FILES (e.g. `widget-manifest.json:.version`) would get the file bumped correctly but the post-bump verify would read it back as a raw text blob, compare it to the target version string, and falsely trip the commit gate with `version_files_desynced_*`. All auto-discovered files are named `package.json` and are unaffected. Consider removing the unreachable catch-all (auto-discovery only yields `package.json` files, already handled by the explicit branch) or extending `_accessor_for_file`'s `*` case to return `json` for `.json`-suffixed files.
- `lib/project_version.sh:2` — `set -euo pipefail` is present; the convention for sourced `lib/` files in this codebase is to inherit pipefail from the entry point, not re-set it. Pre-existing violation, not introduced by this PR. Log for cleanup.
- `tekhton-legacy.sh:999` — Explicit `source .../project_version_bump_helpers.sh` is redundant because `project_version_bump.sh` already self-sources it via the sentinel guard at lines 24–28. The double-source is harmless (idempotent) but can be removed for clarity on the next touch.

## Coverage Gaps
- `_bump_single_file` `*` catch-all (JSON detection via `head -c 1`) has no test. Add a fixture with a non-conventional-basename JSON file (e.g. `widget-manifest.json`) to confirm both the bump and the round-trip read succeed without a false commit-gate trip.
- `verify_version_files_synced` HUMAN_ACTION fallback paths (`_append_human_action_entry` branch and `tekhton drift human-action append` branch) are not exercised by the new tests. A targeted test that stubs `trip_commit_gate` as a no-op and captures the human-action call would verify the fallback warning path on desync.

## Drift Observations
- `lib/project_version.sh:2` — `set -euo pipefail` in a sourced lib file. Convention in this repo: only standalone entry points set this; lib files inherit from the entry point. (Also noted in m42 report for `lib/hooks_final_checks.sh` — same class of pre-existing violation.)
