# Coder Summary

## Status: COMPLETE

## What Was Implemented

m43 — Version-bump completeness: sync all version files and validate after
bump. All three goals and all five acceptance criteria are implemented.

### Goal 1 — Multi-file + JSON-aware detection and bump

**New file `lib/project_version_bump_helpers.sh`** holds the per-file
write logic + multi-file parsing seam, extracted from
`lib/project_version_bump.sh` (which was at 301 lines and needed breathing
room for new logic per the 300-line bash ceiling).

- `_parse_version_files_list LIST [OUT_VAR]` — splits the VERSION_FILES
  config value into per-entry `path:selector` strings. Accepts `;` and
  newline separators (or a mix), trims surrounding whitespace, skips
  empties. Optional nameref output (`out_var=...`) so callers can
  `readarray`-style consume without forking a subshell.
- `_bump_json_version FILE OLD NEW` — format-preserving JSON `"version"`
  field replacement. Uses `sed` against the single matched line, never
  reserialises the file. Preserves key order, indentation, trailing
  whitespace. Safe across single-line (`{"version":"X"}`) and indented
  multi-line shapes. **Replaces the previous `python3 json.dump(...,
  indent=2)` path** that reordered keys and rewrote whitespace — the bug
  the milestone's gap section calls out.
- `_bump_single_file` (moved from `project_version_bump.sh`) — routes
  `package.json` / `composer.json` through `_bump_json_version`; the
  other ecosystem branches (`Cargo.toml`, `pyproject.toml`, `setup.py`,
  `setup.cfg`, `gradle.properties`, `Chart.yaml`, `pubspec.yaml`,
  `VERSION`) are unchanged. A catch-all branch routes JSON-looking files
  (first non-space char is `{`) through the JSON bumper too, so an
  auto-discovered `bindings/foo/package.json` at a non-conventional
  basename pattern still bumps correctly.

**`bump_version_files`** (in `lib/project_version_bump.sh`) now parses
VERSION_FILES via `_parse_version_files_list` (so multi-line config
values work) and, after the per-file write pass, invokes
`verify_version_files_synced` if the function is present. The
`command -v` guard means the verify module is optional — installations
that haven't sourced it (e.g. tests that only need the compute helpers)
keep working.

**Auto-discovery** (`lib/project_version.sh::_discover_package_json_files`
+ wiring in `detect_project_version_files`): walks tracked
`package.json` files via `git ls-files -- '*package.json'` when in a git
repo, falls back to `find` with `node_modules` / `.git` / `dist` /
`build` / `.tekhton` pruned. Filters to files that actually declare a
`"version"` field (so empty workspace-member manifests don't pollute the
list). The root `package.json` is excluded (it's already caught by the
main ecosystem loop) and duplicate paths are skipped. Each discovered
file is added to VERSION_FILES with `:.version` selector. This catches
the milestone's motivating case (`bindings/sdivi-wasm/pkg-template/
package.json`) and any analogous workspace / template manifests.

### Goal 2 — Post-bump consistency self-check

**New file `lib/project_version_verify.sh`** —
`verify_version_files_synced TARGET_VERSION ENTRY [ENTRY ...]` reads
every declared/detected version file back via
`_detect_version_from_file` + `_accessor_for_file` and asserts the
on-disk version matches the bump target. On divergence:

- Calls `trip_commit_gate "version_files_desynced_<sanitised_path>"` —
  the existing `.final_check_result` sentinel mechanism that `_hook_commit`
  reads. The desynced bump never reaches the commit step regardless of
  TEST_CMD (the m42 no-op-TEST_CMD path would have masked this otherwise).
- Emits a `HUMAN_ACTION_REQUIRED.md` entry via
  `tekhton drift human-action append --source project_version_bump`,
  falling back to `_append_human_action_entry` if a future port exposes
  it as a bash function. Best-effort — missing CLI or write failure
  fails open so the bump itself isn't broken.

Missing declared files are intentionally non-blocking: operator templates
may legitimately declare files that don't materialise on every branch
(e.g. a binding only built on certain platforms), so a missing path
doesn't trip the gate. The post-bump verify still catches the real
desync case — file present, version doesn't match target.

### Goal 3 — Document VERSION_FILES syntax

`docs/reference/configuration.md` gains a new "Project Versioning"
section (placed before "Other Settings") covering:

- Auto-detection ecosystems + non-root `package.json` walk
- `VERSION_FILES` syntax (path:selector entries, `;` or newline
  separators) with TOML / JSON / plaintext selector vocabulary
- The full Cargo + non-root JSON example from the milestone gap
- Post-bump consistency self-check + commit-gate trip semantics
- The six PROJECT_VERSION_* config keys with defaults

## Acceptance Criteria — predicate-by-predicate

- ✅ **AC1.** A `VERSION_FILES` with both a Cargo TOML selector and a
  `package.json` JSON selector bumps both to the same version:
  `tests/test_version_bump_multifile.sh::"multi-file bump: Cargo + package.json"`
  drives `Cargo.toml:.workspace.package.version;bindings/wasm/
  pkg-template/package.json:.version` and asserts both files reach
  `0.4.3` from `0.4.2`.
- ✅ **AC2.** Auto-discovery catches a `package.json` with a `version`
  at a non-root path even if unlisted:
  `tests/test_version_bump_json.sh::"_discover_package_json_files: non-root scan"`
  + `"detect_project_version_files: auto-discovered binding listed in
  VERSION_FILES"`. Asserts the non-root binding is found, `node_modules`
  is excluded, version-less `package.json` entries are skipped, and the
  config doesn't contain duplicate root entries.
- ✅ **AC3.** After a bump, if any declared/detected version file
  diverges, the commit gate trips with `version_files_desynced_*` + a
  HUMAN_ACTION entry: `tests/test_version_bump_multifile.sh::
  "desync detection"` asserts the gate is tripped with a
  `version_files_desynced_<file>` reason when the second file's old
  version doesn't match the bumper's expectation.
- ✅ **AC4.** JSON bump preserves file formatting (no whole-file
  reserialization / key reordering): four assertions in
  `tests/test_version_bump_json.sh::"_bump_json_version: format
  preservation"` cover (i) only the version line changes (diff isolation
  check), (ii) key order preserved, (iii) 4-space indent preserved,
  (iv) trailing newline preserved.
- ✅ **AC5.** Existing single-file `VERSION_FILES` projects keep
  working unchanged: every assertion in
  `tests/test_project_version_bump.sh` (34 / 34) still passes;
  `tests/test_project_version_detect.sh` (18 / 18) still passes;
  `tests/test_version_bump_multifile.sh::"single-file backward compat"`
  asserts the single-entry `VERSION:.` config still bumps cleanly with
  no commit gate trip.

## Watch For — predicate-by-predicate

- ✅ "JSON editing must be format-preserving — naive `jq` reserialization
  reorders keys and rewrites whitespace, producing noisy diffs":
  `_bump_json_version` uses `sed` against the single matched
  `"version"\s*:\s*"X"` line, escaping regex special characters in the
  old version. No `jq` / no `json.dump`. Verified by the four
  format-preservation assertions in `test_version_bump_json.sh` against
  a 4-space-indented multi-line file with custom key order.
- ✅ "The self-check runs on the post-bump tree before commit; it must
  not itself require the project's full (possibly no-op, see m42)
  `TEST_CMD`": `verify_version_files_synced` reads version files
  directly via `_detect_version_from_file` (the same accessor table the
  detector and bumper use) and trips the commit gate via the existing
  `.final_check_result` sentinel mechanism. No invocation of TEST_CMD or
  any project-defined command.
- ✅ "Keep the no-op-bump short-circuit
  (`PROJECT_VERSION_ENABLED` / no-changes gate) intact": the
  `PROJECT_VERSION_ENABLED != true` short-circuit at the top of both
  `bump_version_files` and `verify_version_files_synced` is preserved;
  `_hook_project_version_bump` continues to short-circuit on
  `git status --porcelain` empty.

## Verification

| Test | Result |
|---|---|
| `tests/test_version_bump_multifile.sh` (NEW) | 14 PASS / 0 FAIL |
| `tests/test_version_bump_json.sh` (NEW) | 13 PASS / 0 FAIL |
| `tests/test_project_version_bump.sh` (existing) | 34 PASS / 0 FAIL |
| `tests/test_project_version_detect.sh` (existing) | 18 PASS / 0 FAIL |
| `tests/test_project_version_hint.sh` (existing) | 6 PASS / 0 FAIL |
| `bash tests/run_tests.sh` full suite | 509 shell PASS / 0 FAIL + Go PASS |
| `shellcheck -S warning` on modified .sh files | clean |
| File-length ceiling (300 lines on lib/, soft on tests/) | all lib files ≤ 268 lines |

## Files Modified

- `lib/project_version_bump.sh` — extracted `_bump_single_file` into the
  new helpers file; replaced `IFS=';' read -ra` with
  `_parse_version_files_list` (now supports newline-separated values);
  wired in the post-bump `verify_version_files_synced` call;
  self-sources the helpers file via a sentinel-guarded `source` so the
  bump shim is callable from any context. 264 lines (was 301).
- `lib/project_version_bump_helpers.sh` (NEW) —
  `_parse_version_files_list`, `_bump_json_version`, `_bump_single_file`.
  132 lines.
- `lib/project_version_verify.sh` (NEW) — `verify_version_files_synced`
  with `trip_commit_gate` + `drift human-action append` integration.
  107 lines.
- `lib/project_version.sh` — added `_discover_package_json_files`
  (git-aware bounded walk, falls back to find with prunes); wired into
  `detect_project_version_files` to merge auto-discovered non-root
  `package.json` entries into VERSION_FILES. 268 lines.
- `tekhton-legacy.sh` — source the two new lib files immediately after
  `lib/project_version_bump.sh` (before `lib/finalize.sh`).
- `internal/stagerunner/helpers.go` — added the two new lib files to
  `DefaultLibHelpers` to keep the bash↔Go parity test
  (`TestDefaultLibHelpersParityWithLegacy`) green.
- `tests/test_version_bump_multifile.sh` (NEW) — 14 assertions covering
  `_parse_version_files_list` semantics, the Cargo+package.json synced
  bump, desync → commit-gate trip, single-file backward compat, and the
  missing-file non-blocking branch of verify. 237 lines.
- `tests/test_version_bump_json.sh` (NEW) — 13 assertions covering
  format-preservation under `_bump_json_version`, the package.json
  routing through `_bump_single_file`, and the `_discover_package_json_files`
  non-root scan including node_modules exclusion + version-less skip
  + no-duplicate guarantee. 221 lines.
- `docs/reference/configuration.md` — new "Project Versioning" section
  with VERSION_FILES syntax, JSON / TOML selector vocabulary, the Cargo
  + non-root JSON example, post-bump self-check semantics, and the
  PROJECT_VERSION_* config-key table.
- `CLAUDE.md` — added the two new `lib/` files to the repository
  layout tree.

## Architecture Change Proposals

None. The new `lib/project_version_bump_helpers.sh` follows the
established pattern (`common.sh` → `common_box.sh` / `common_timing.sh`,
`state.sh` → `state_helpers.sh`, `tui.sh` → `tui_helpers.sh`) of a
library self-sourcing its helpers when the parent is sourced. The new
`lib/project_version_verify.sh` is a sibling module deliberately *not*
self-sourced by the bump library — it's an optional concern (the
post-bump check) called via `command -v` so the bump library remains
usable in test contexts that don't want the gate-tripping side effect.

`trip_commit_gate` and `drift human-action append` are the existing
post-pipeline drift integration seams (used by `stages/coder_buildfix.sh`
and `stages/architect.sh` already); no new contract.

## Observed Issues (out of scope)

- `lib/finalize_commit.sh` and `stages/coder.sh` size ceilings — both
  carried over from m42's summary. Untouched by m43.
- `lib/init_config_sections.sh` duplicate `TEST_CMD="true"` fallback —
  carried over from m42. Untouched by m43.

## Human Notes Status

No Human Notes block was injected for this run.

## Docs Updated

- `docs/reference/configuration.md` — new "Project Versioning" section
  documenting the VERSION_FILES multi-file / JSON / pointer syntax with
  the Cargo + non-root JSON example, plus the post-bump self-check
  semantics and the PROJECT_VERSION_* config-key table. This is the
  public-surface change the milestone asks for under Goal 3.
- `CLAUDE.md` — added the two new lib files
  (`project_version_bump_helpers.sh`, `project_version_verify.sh`) to
  the repository layout tree so the architecture map stays in sync.
