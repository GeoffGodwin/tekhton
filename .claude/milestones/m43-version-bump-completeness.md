<!-- milestone-meta
id: "43"
status: "todo"
-->

# m43 — Version-bump completeness: sync all version files and validate after bump

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | On a downstream project (sdivi-rust) every milestone that bumped the project version left `bindings/sdivi-wasm/pkg-template/package.json` stale, because the bump only touched the Cargo workspace version. The repo's own version-consistency test (`workspace_version`, which asserts the WASM `package.json` matches the Cargo version) then failed. Worse, the bump runs *after* the tester stage, so the drift it introduces is never re-tested — and (see m42) the no-op `TEST_CMD` wouldn't have caught it anyway. The net effect: a finalize step that bumps the version can leave the repo in a state its own tests reject. |
| **Gap** | `lib/finalize_version.sh::_hook_project_version_bump` calls `detect_project_version_files` then `bump_version_files` (`lib/project_version_bump.sh`). Detection found the primary manifest (`Cargo.toml`) but not the secondary/template JSON version file at a non-root path (`bindings/sdivi-wasm/pkg-template/package.json`). The `VERSION_FILES` config entry (`Cargo.toml:.package.version`) is single-target and TOML-path-shaped, with no documented way to declare a JSON `package.json` `version` field or multiple files. And because `_hook_project_version_bump` runs *before* `_hook_commit` but *after* the tester, no validation re-runs on the post-bump tree. |
| **m43 fills** | (a) Extend version-file detection + bumping to cover JSON `version` fields (`package.json`, including non-root/template paths), and honor a **multi-entry** `VERSION_FILES` (newline/semicolon-separated, each `path:selector` where selector may be a TOML dotted path or a JSON pointer). (b) After bumping, run a fast **version-consistency self-check** (assert every declared version file now matches the bumped version) and trip the existing commit gate with a clear reason if they diverge — so a bump that desyncs files is caught before commit, independent of `TEST_CMD`. (c) Document the `VERSION_FILES` multi-file / JSON syntax. |
| **Depends on** | — |
| **Files changed** | `lib/project_version_bump.sh`, `lib/project_version.sh`, `lib/finalize_version.sh`, `docs/` (VERSION_FILES syntax), `tests/test_version_bump_multifile.sh` (new), `tests/test_version_bump_json.sh` (new). |

---

## Design

### Goal 1 — multi-file + JSON-aware detection and bump

Parse `VERSION_FILES` as a list. Each entry is `path:selector`:
- TOML selector (e.g. `.package.version`, `.workspace.package.version`) → bump via the existing TOML path logic.
- JSON selector (e.g. `#/version` or `.version`) → bump the JSON `version` field with a JSON-safe edit (preserve formatting; do not reserialize the whole file).

`detect_project_version_files` should additionally auto-discover `package.json` files
that declare a `version` (bounded to tracked files, skipping `node_modules`), so
template/binding manifests are caught even when not explicitly listed.

### Goal 2 — post-bump consistency self-check

After `bump_version_files`, read the version back from every declared/detected file and
assert they all equal the target version. On mismatch, `trip_commit_gate
"version_files_desynced_<file>"` and emit a HUMAN_ACTION entry. This makes a desynced
bump fail the commit gate deterministically, independent of `TEST_CMD` (m42) and without
needing the project's full test suite.

### Goal 3 — document the syntax

Document multi-entry `VERSION_FILES` and the JSON selector form, with the
`Cargo.toml:.workspace.package.version` + `bindings/.../package.json:.version` example.

## Files Modified

- `lib/project_version_bump.sh` — list parsing, JSON bump, post-bump self-check.
- `lib/project_version.sh` — JSON read-back for the self-check + auto-discovery.
- `lib/finalize_version.sh` — invoke the self-check; trip the gate on divergence.
- `docs/` — `VERSION_FILES` multi-file / JSON syntax.
- `tests/test_version_bump_multifile.sh`, `tests/test_version_bump_json.sh` (new).

## Acceptance Criteria

- A `VERSION_FILES` with both a `Cargo.toml` TOML selector and a `package.json` JSON selector bumps both to the same version.
- Auto-discovery catches a `package.json` with a `version` at a non-root path even if unlisted.
- After a bump, if any declared/detected version file diverges, the commit gate trips with `version_files_desynced_*` and a HUMAN_ACTION entry.
- JSON bump preserves file formatting (no whole-file reserialization / key reordering).
- Existing single-file `VERSION_FILES` projects keep working unchanged.

## Watch For

- JSON editing must be format-preserving — naive `jq` reserialization reorders keys and rewrites whitespace, producing noisy diffs. Use a targeted version-field replacement.
- The self-check runs on the post-bump tree before commit; it must not itself require the project's full (possibly no-op, see m42) `TEST_CMD`.
- Keep the no-op-bump short-circuit (`PROJECT_VERSION_ENABLED` / no-changes gate) intact.

## Seeds Forward

- Pair with m42: once `TEST_CMD` is real, the post-bump self-check becomes a second, cheaper layer; together they close the "finalize leaves the repo red" gap.
