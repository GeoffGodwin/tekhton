# Coder Summary

## Status: COMPLETE

## What Was Implemented

m28.3 — Stale-Config Migration + Tests. Final subtask of the m28 arc.
m28.1 made fresh configs correct; m28.2 made startup truth-telling;
m28.3 makes existing broken configs self-heal on next run and ships
the regression coverage for the whole arc.

### Goal 1 — `_is_stale_serena_config`

Added to `lib/mcp_resolve.sh` (see "File-ceiling extraction" below) between
`_probe_serena_startup` and `_resolve_mcp_config`. Body matches the
milestone spec — `python3` heredoc, narrow match on
`args[0]=="-m" && args[1]=="serena"`. Returns 0 for stale shape, 1 for
anything else (correct, malformed, missing, foreign server keyed as
"serena" with a different layout). `python3` chosen over `jq` because
`jq` is not guaranteed on the CI matrix; the project already shells to
`python3` from `lib/test_audit_helpers.sh` and elsewhere.

The detection regex is intentionally narrow: a user with a custom MCP
config that names a server "serena" but uses a different command/args
layout is not affected (e.g. `{"command":"/usr/local/bin/my-wrapper.sh"}`
with arbitrary args is preserved).

### Goal 2 — `_resolve_mcp_config` rewire

The `default_config` branch now calls `_is_stale_serena_config`:
- stale → `cp` to `<config>.bak.$(date +%Y%m%d%H%M%S)`, `log_verbose`,
  `rm`, fall through to the existing template-substitution block
- not-stale → set `_MCP_CONFIG_PATH` and return 0 (unchanged path)

The fall-through reuses the existing generation block — no duplication.
Backup filename uses second-resolution timestamp per the milestone's
Watch For note ("two pipeline runs within the same second is acceptable
collision risk for a one-shot migration; don't add nanosecond precision").

### Goal 3 — `tests/test_serena_template_substitution.sh` (NEW)

End-to-end black-box coverage of `_resolve_mcp_config` across three
scenarios:
1. **Fresh-generation** — no pre-existing config → asserts the file
   parses as JSON, `command == _SERENA_BIN`, `args[0] == "start-mcp-server"`,
   `args` contains `--project` pointing at `PROJECT_DIR`.
2. **No-overwrite-when-correct** — pre-place `fixtures/correct.json` →
   asserts md5 unchanged and zero `.bak.*` files created.
3. **Regenerate-when-stale** — pre-place `fixtures/stale.json` → asserts
   md5 differs, exactly one `.bak.*` exists, backup contains the original
   stale bytes.

Shape matches `tests/test_mcp.sh`: `assert_exit_code` helper, top-level
`PASS`/`FAIL` counters, trap-based cleanup. 10 / 10 PASS in isolation.

### Goal 4 — `tests/test_mcp.sh` extension

Appended the three `_probe_serena_startup` scenarios (empty bin,
`/usr/bin/false`, `command -v echo`) using a compact `_probe_case`
helper that wraps each invocation. Three new test cases, all PASS.
File at 298 lines after compaction (was 282 pre-edit).

### Goal 5 — Fixtures

`tests/fixtures/serena_configs/{stale,correct}.json` — hand-written
to the exact pre-/post-m28.1 shapes per the milestone Watch For
("don't programmatically derive correct.json from setup_serena.sh —
divergence is exactly what this test exists to catch"). Both validate
under `python3 -m json.tool`.

### Goal 6 — VERSION + manifest + CHANGELOG

- `VERSION`: `4.27.7` → `4.28.0` (pipeline subsequently patch-bumped to
  `4.28.1` mid-run; both tests are tolerant of any `4.>=28.x`).
- `CHANGELOG.md`: promoted the m28.1 `### Fixed` and m28.2 `### Changed`
  entries from `[Unreleased]` into a new dated `## [4.28.0] - 2026-05-29`
  block, and added the m28.3 `### Added` entries inside the same block,
  per the milestone consolidation convention.
- `MANIFEST.cfg`: m28 (parent), m28.1, m28.2, m28.3 all flipped to
  `done`. Parent's `split` status replaced with `done` per AC.

### File-ceiling extraction — `lib/mcp_resolve.sh` (NEW)

Adding `_is_stale_serena_config` (~16 lines) to `lib/mcp.sh` pushed the
file to 327 lines, over the CLAUDE.md Rule 8 300-line bash ceiling.
Extracted the five internal resolver/probe helpers
(`_resolve_serena_paths`, `_probe_serena_startup`,
`_is_stale_serena_config`, `_resolve_mcp_config`, `_cli_supports_mcp_config`)
into a sibling file `lib/mcp_resolve.sh` sourced by `lib/mcp.sh`.

The split is conceptually clean: `mcp_resolve.sh` owns "find/probe/
regenerate config", `mcp.sh` owns "server lifecycle (start/stop/health)".
All callers (5 sourcing sites — `tekhton-legacy.sh` plus 4 tests) get
the helpers transitively via the source line in `mcp.sh`. Final counts:
`lib/mcp.sh` 186, `lib/mcp_resolve.sh` 164 — both well under 300.

Architecture map (`ARCHITECTURE.md`) updated to reflect the new file
under the Layer 3 listing.

### Test maintenance (broken by promoting [Unreleased] → [4.28.0])

`tests/test_mcp_probe.sh` and `tests/test_mcp_serena_bin.sh` were
written against the in-flight m28.2/m28.1 floor states — AC8 asserted
`VERSION == 4.27.x` and AC9 asserted entries under `[Unreleased]`.
m28.3's milestone-spec'd consolidation breaks both assertions.

Both updated to accept either the in-flight `4.27.x` floor OR the
post-promotion `4.>=28.x` shape, and to scan both `[Unreleased]` and
the most recent `[4.NN.N]` block. Pre-existing AC structure preserved —
this is the minimal fix the m28-arc-close requires.

`tests/test_mcp_serena_bin.sh` was at 308 lines pre-edit (already over
the 300 ceiling at m28.1 close — pre-existing violation noted but not
introduced by me). My AC8/AC9 expansion plus consolidating three
repetitive `_resolve_serena_paths` setup blocks into a parameterized
`_resolve_case` helper brought it to 263 lines — pulling it back under
the ceiling. Same 22-test count, same coverage, smaller surface.

## Acceptance Criteria — verified

- [x] `_is_stale_serena_config` returns 0 on stale shape, 1 on correct/
      malformed/missing/foreign-args layouts. Confirmed by the three
      fixture-driven cases in `test_serena_template_substitution.sh`
      plus the milestone's narrow-match property.
- [x] `_resolve_mcp_config` against a stale config: creates exactly one
      `<config>.bak.<timestamp>` with original contents, deletes the
      original, falls through to template generation, returns 0 with
      `_MCP_CONFIG_PATH` set. Verified by
      `test_serena_template_substitution.sh` "Regenerate-when-stale".
- [x] `_resolve_mcp_config` against a correct config: returns 0
      unchanged, no backup created, file byte-identical. Verified by
      `test_serena_template_substitution.sh` "No-overwrite-when-correct"
      (md5 match before/after).
- [x] `tests/test_serena_template_substitution.sh` exits 0; covers
      fresh-generation, no-overwrite-correct, regenerate-when-stale.
      10 / 10 PASS.
- [x] `tests/test_mcp.sh` adds and passes the three
      `_probe_serena_startup` scenarios. 25 / 25 PASS.
- [x] Fixtures `tests/fixtures/serena_configs/{stale,correct}.json`
      parse with `python -m json.tool`.
- [x] `bash tests/run_tests.sh` shows zero regressions — 494 shell PASS
      / 0 FAIL (up from 492 at m28.2 close — the two new test cases).
      All Go packages pass.
- [x] `.claude/milestones/MANIFEST.cfg`: m28 parent + m28.1 + m28.2 +
      m28.3 all `done`. Parent's `split` field replaced with `done`.
- [x] `VERSION` reads `4.28.0` (pipeline subsequently patch-bumped to
      `4.28.1`; both are 4.>=28.x and satisfy the floor).
- [x] `CHANGELOG.md` `[Unreleased]` is empty; entries promoted to
      `[4.28.0] - 2026-05-29` block per project convention.

Additional gates verified:

- [x] `shellcheck tekhton.sh lib/*.sh stages/*.sh` exits 0 (full tree).
- [x] `shellcheck` on the four modified test files: only pre-existing
      SC1091 (info) and SC2034 (warning on pipeline-consumed vars) —
      same shape as the m28.2-close baseline.
- [x] File ceilings: every modified `.sh` file under 300 lines —
      `lib/mcp.sh` 186, `lib/mcp_resolve.sh` 164, `tests/test_mcp.sh`
      298, `tests/test_mcp_probe.sh` 170, `tests/test_mcp_serena_bin.sh`
      263, `tests/test_serena_template_substitution.sh` 189.

## Root Cause (bugs only)

N/A — m28.3 is a migration feature. The bug class it addresses (silent
acceptance of pre-m28.1 broken configs by `_resolve_mcp_config`'s
unconditional file-exists short-circuit) was fixed structurally by
adding the stale-detect branch. No prior runtime regression to root-cause.

## Files Modified

- `lib/mcp.sh` — Sliced down to 186 lines: kept public API
  (`get_mcp_config_path`, `check_mcp_health`, `is_mcp_running`,
  `start_mcp_server`, `stop_mcp_server`, `check_serena_available`) plus
  module-state vars; added `source lib/mcp_resolve.sh` line.
- `lib/mcp_resolve.sh` (NEW) — 164 lines. Owns
  `_resolve_serena_paths`, `_probe_serena_startup`,
  `_is_stale_serena_config` (new in m28.3), `_resolve_mcp_config`
  (with new stale-detect branch in m28.3), `_cli_supports_mcp_config`.
- `tests/test_mcp.sh` — Appended three `_probe_serena_startup`
  scenarios via a `_probe_case` helper. 298 lines.
- `tests/test_mcp_probe.sh` — Updated AC8 (VERSION floor) and AC9
  (CHANGELOG block) to accept both in-flight and promoted shapes.
  170 lines.
- `tests/test_mcp_serena_bin.sh` — Same AC8/AC9 update; consolidated
  three repetitive AC2 `_resolve_serena_paths` blocks into a single
  `_resolve_case` helper. Down from 308 to 263 lines.
- `tests/test_serena_template_substitution.sh` (NEW) — 189 lines.
  End-to-end coverage of `_resolve_mcp_config` template substitution +
  stale-config migration.
- `tests/fixtures/serena_configs/stale.json` (NEW) — Pre-m28.1
  broken-shape fixture.
- `tests/fixtures/serena_configs/correct.json` (NEW) — Post-m28.1
  correct-shape fixture.
- `VERSION` — `4.27.7` → `4.28.0` (pipeline finalize hook may bump
  further to `4.28.1` between stages; both pass the AC8 floor).
- `CHANGELOG.md` — `[Unreleased]` cleared; entries promoted to
  `[4.28.0] - 2026-05-29` block; added m28.3 `### Added` entries for
  `_is_stale_serena_config` and the new tests/fixtures.
- `.claude/milestones/MANIFEST.cfg` — Flipped m28 (parent),
  m28.1, m28.2, m28.3 all to `done`.
- `ARCHITECTURE.md` — Added `lib/mcp_resolve.sh` entry under Layer 3.

## Human Notes Status

No HUMAN_NOTES.md items present in this task. The Clarifications block
contained Q&A pairs from prior runs (Watchtower dashboard,
NON_BLOCKING_LOG, --init/--plan flow, notes inconsistency) — all in
different subsystems, none relevant to m28.3.

## Docs Updated

- `ARCHITECTURE.md` — Added an entry for the new `lib/mcp_resolve.sh`
  file under Layer 3, mirroring the existing `mcp.sh` entry's style.
  No CHANGELOG bullet for the architecture-map update (internal
  navigation aid, not a user-visible change).

`_is_stale_serena_config` is underscore-prefixed (internal API) and
the auto-repair-on-next-run behavior is documented in the CHANGELOG
`[4.28.0]` block. The milestone Watch For explicitly forbids a
`tekhton --repair-mcp-config` CLI subcommand, so no docs/completion
surface to add.

## Observed Issues (out of scope)

- **`lib/mcp.sh` and `lib/mcp_resolve.sh` both carry
  `set -euo pipefail` despite being sourced libs.** Pre-existing
  pattern in this file (m28.1 review noted it as out of scope for
  m28.1); inherited into `mcp_resolve.sh` to match the convention
  used by the rest of `lib/*_helpers.sh`. Cleanup belongs to a future
  shell-hygiene milestone that sweeps all sourced libs.
- **`tests/test_mcp.sh` and `tests/test_mcp_lifecycle.sh` carry
  pre-existing SC1091/SC2034 warnings.** Same observation as the m28.2
  reviewer. Not introduced by me; not in scope.
- **`scripts/wedge-audit.sh` at 307 lines** — still 7 over the 300-line
  ceiling, carrying from prior milestones. No changes from m28.3.

## Architecture Change Proposals

None. The extraction of `lib/mcp_resolve.sh` from `lib/mcp.sh` is a
file-ceiling compliance split, not an architectural change. Same
public interface, same dependency direction (sourced by `mcp.sh` so
all callers of `mcp.sh` pick up the helpers transitively without
edits), same `lib/*.sh` layer. Documented in `ARCHITECTURE.md` per
the standard layer-3 entry pattern, matching `agent_helpers.sh` /
`indexer_helpers.sh` precedent.
