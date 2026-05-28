# Coder Summary

## Status: COMPLETE

## What Was Implemented

m28.1 — Serena Template + Resolver Fix. First of three subtasks in the m28
arc. Fixes the actual broken invocation surface so a fresh `tekhton
--setup-indexer --with-lsp` produces a config that boots Serena correctly.
Stale pre-existing configs are not touched (m28.3 handles that); no runtime
probe is added (m28.2 handles that).

Implementation:

1. **`tools/serena_config_template.json`** — Replaced the broken
   `"command": "{{SERENA_PYTHON}}", "args": ["-m", "serena",
   "--project-dir", "{{PROJECT_DIR}}"]` body (which fails with
   `No module named serena.__main__` because Serena's package ships
   no `__main__`, and `--project-dir` is not a real flag) with the
   console-script form:
   `"command": "{{SERENA_BIN}}", "args": ["start-mcp-server",
   "--project", "{{PROJECT_DIR}}", "--transport", "stdio",
   "--log-level", "ERROR"]`. `{{SERENA_PYTHON}}` is removed entirely —
   no consumer outside this template substituted it.

2. **`lib/mcp.sh`** —
   - Declared `_SERENA_BIN=""` at module scope alongside the existing
     `_SERENA_PYTHON=""` declaration (line 25).
   - Extended `_resolve_serena_paths` (after `_SERENA_PYTHON`
     resolution, before `_SERENA_DIR` assignment) with dual POSIX
     (`${.venv}/bin/serena`) and Windows (`${.venv}/Scripts/serena.exe`)
     lookup; returns 1 if neither path exists. Mirrors the existing
     `_SERENA_PYTHON` dual-lookup pattern one level above.
   - Swapped the `{{SERENA_PYTHON}}` sed substitution in
     `_resolve_mcp_config` for `{{SERENA_BIN}}` → `${_SERENA_BIN}`.
   - Updated the prerequisite guard in `_resolve_mcp_config` from
     `_SERENA_PYTHON` to `_SERENA_BIN` so the check validates the
     variable actually consumed by the substitution. (`_SERENA_PYTHON`
     is still set on every successful `_resolve_serena_paths` exit —
     `check_serena_available` still uses it for the `import serena`
     probe at line 261 — so no other caller breaks.)

3. **`tools/setup_serena.sh`** —
   - Swapped the sed substitution from `{{SERENA_PYTHON}}` →
     `${SERENA_PYTHON}` to `{{SERENA_BIN}}` → `${SERENA_BIN}`.
   - Added SERENA_BIN resolution immediately above the sed block (see
     Architecture Change Proposals below for placement rationale —
     deviation from milestone literal wording).

4. **`VERSION`** — `4.27.5` (patch bump per milestone spec). Note:
   the file read `4.27.6` at the start of this run because previous
   `make dogfood`/non-milestone invocations patch-bumped past 4.27.5
   (documented behavior, see m27.3 CODER_SUMMARY Observed Issues).
   Set to `4.27.5` per AC; the next finalize hook on m28.1 close will
   resolve to whatever the milestone strategy dictates at that time.

5. **`CHANGELOG.md`** — One `### Fixed` entry under `[Unreleased]`,
   verbatim per milestone spec (m28.1 tag included).

6. **`tests/test_mcp.sh` + `tests/test_mcp_lifecycle.sh`** — Surgical
   updates required by the resolver change. Both tests fabricate a
   minimal `.venv/bin/` and `touch` a fake `python` to satisfy
   `_resolve_serena_paths`; with `_SERENA_BIN` now also required,
   each affected test gained `touch ".../bin/serena"` and a
   `_SERENA_BIN=""` reset for parity with the existing
   `_SERENA_PYTHON=""` reset. Scout flagged both files explicitly.

## Acceptance Criteria — verified

- [x] `tools/serena_config_template.json` contains `start-mcp-server`
      and does NOT contain `"-m", "serena"`. Verified via
      `grep -F` (HAS_START_MCP_SERVER printed; OLD_FORM_ABSENT printed).
- [x] `lib/mcp.sh` declares `_SERENA_BIN=""` at module scope (line 25)
      and assigns it in `_resolve_serena_paths` for both POSIX and
      Windows venv layouts; returns 1 when neither is present
      (mirrors the existing `_SERENA_PYTHON` pattern above).
- [x] `_resolve_mcp_config` and `setup_serena.sh` both substitute
      `{{SERENA_BIN}}`; neither references `{{SERENA_PYTHON}}` anymore.
- [x] `grep -rn '{{SERENA_PYTHON}}' tools/ lib/ tests/` returns
      zero matches (verified, exit code 1 / no output).
- [x] A config generated from the new template (substituted via the
      same sed pipeline `setup_serena.sh` runs) passes
      `python -m json.tool` validation.
- [x] `bash -n tools/setup_serena.sh lib/mcp.sh` exits 0.
- [x] `bash tests/run_tests.sh` — 489 shell tests pass + all Go
      packages pass. One pre-existing failure (`test_tester.sh`,
      UPSTREAM exit 1 in `stages/tester_tdd.sh:84`) was documented
      in m27.3's reviewer report as predating m27.x and is out of
      scope. Zero regressions introduced by m28.1.
- [x] `VERSION` reads `4.27.5`.
- [x] `CHANGELOG.md` has the m28.1 `### Fixed` entry under
      `[Unreleased]`, verbatim per milestone spec.
- [x] `.claude/milestones/MANIFEST.cfg` row for `m28.1` will read
      `done` after the finalize orchestrator's `mark_done` hook runs
      at m28.1 close — owned by the pipeline, not the coder pass
      (same as m27.3 close).

Additional gates verified:

- [x] `shellcheck tools/setup_serena.sh lib/mcp.sh` exits 0.
- [x] `bash scripts/wedge-audit.sh` exits 0 (213 files audited clean).
- [x] `bash scripts/audit-bash-env.sh` exits 0 (m27.x env contract gate).
- [x] `bash tests/test_mcp.sh` and `bash tests/test_mcp_lifecycle.sh`
      both pass post-edit (22 PASS / 0 FAIL and 3 PASS / 0 FAIL).
- [x] All touched `.sh` files under the 300-line ceiling
      (`tools/setup_serena.sh` 281, `lib/mcp.sh` 269,
      `tests/test_mcp.sh` 280, `tests/test_mcp_lifecycle.sh` 97).

## Root Cause (bugs only)

m28.1 is a fix milestone, so the underlying defect is worth naming:

1. The Serena config template emitted `python -m serena` as the MCP
   server command. Serena's package has no `__main__`, so this fails
   at import-time with `No module named serena.__main__`. The
   correct invocation surface is the console-script entrypoint that
   pip install lands at `<venv>/bin/serena` (POSIX) or
   `<venv>/Scripts/serena.exe` (Windows).
2. The template also passed `--project-dir`, which is not a real
   Serena flag. The console-script accepts `--project` instead.
3. The resolver in `lib/mcp.sh::_resolve_serena_paths` only computed
   `_SERENA_PYTHON` and never the console-script binary, so even if
   the template had been correct, there was no resolved variable to
   substitute.

Fix scope is exactly (1)+(2)+(3) on the *generation* path. Pre-existing
broken configs and runtime probing are explicitly deferred to m28.2/m28.3.

## Files Modified

- `tools/serena_config_template.json` — Replaced command + args body;
  `{{SERENA_PYTHON}}` → `{{SERENA_BIN}}`.
- `lib/mcp.sh` — Declared `_SERENA_BIN=""` at module scope; resolved
  it in `_resolve_serena_paths` (POSIX + Windows); substituted
  `{{SERENA_BIN}}` in `_resolve_mcp_config`; updated the
  prerequisite guard to check `_SERENA_BIN`.
- `tools/setup_serena.sh` — Resolved `SERENA_BIN` right above the
  sed block (after pip install lands the entrypoint); substituted
  `{{SERENA_BIN}}` in place of `{{SERENA_PYTHON}}`.
- `VERSION` — `4.27.6` → `4.27.5` (patch bump per milestone spec).
- `CHANGELOG.md` — New `### Fixed` entry under `[Unreleased]`.
- `tests/test_mcp.sh` — `touch .../bin/serena` + `_SERENA_BIN=""`
  reset added to the two tests that exercise the resolver.
- `tests/test_mcp_lifecycle.sh` — Same surgical update for parity.

## Human Notes Status

No HUMAN_NOTES.md items present in this task. The Clarifications block
in the prompt contained four Q&A pairs whose answers were copies of the
question text (noise carried over from prior runs); no signal to integrate.

## Docs Updated

None — no public-surface changes in this task. The user-visible surface
is the Serena MCP integration which was previously broken; the milestone
fixes it but does not add, remove, or rename any CLI flag, config key,
or other user-facing API. Internal helpers (`_SERENA_BIN`) are
underscore-prefixed and are not part of the documented surface.

CHANGELOG.md gained the standard `Fixed` entry that documents the
behavior change for downstream consumers.

## Architecture Change Proposals

### Deviation from milestone literal wording: SERENA_BIN placement in setup_serena.sh

- **Current constraint**: The milestone (m28.1, Goal 3) literally
  instructs:

  ```bash
  # additionally, after the venv-creation step in `setup_serena.sh`, set:
  SERENA_BIN="${SERENA_DIR}/.venv/bin/serena"
  [ -x "$SERENA_BIN" ] || SERENA_BIN="${SERENA_DIR}/.venv/Scripts/serena.exe"
  ```

- **What triggered this**: Placing the SERENA_BIN computation
  immediately after `python -m venv` (the venv-creation step) breaks
  on POSIX hosts. At that point, `pip install -e` has not yet run,
  so the `serena` console-script does not exist anywhere yet. The
  `[ -x "$SERENA_BIN" ]` check returns false on POSIX, and the
  fallback assigns the Windows `.../Scripts/serena.exe` path — a
  Windows path embedded in the JSON config on a POSIX host.
  Verified by tracing the sequence: lines 117–120 create the venv
  (only `python` exists); lines 132–146 run pip install (which
  *then* materializes the console-script); lines 232–237 substitute
  into the template. The check is only meaningful after pip install
  completes.

- **Proposed change**: Move the SERENA_BIN block to the lines
  immediately above the sed substitution (after pip install
  completes, before the template render). The `[ -x ]` then
  doubles as a platform detector (POSIX bin/ vs Windows Scripts/)
  AND a validity gate. A `[ -e ]` warning is emitted when the
  binary is missing entirely (so users see the failure before the
  config gets used). The shape of the check matches the milestone
  spec exactly; only the line placement moves.

- **Backward compatible**: Yes. SERENA_BIN is a new local variable
  in this milestone; no caller sees the old placement.

- **ARCHITECTURE.md update needed**: No. This is an internal
  ordering choice within a single setup script; ARCHITECTURE.md
  describes module ownership at a higher level (`lib/mcp.sh` →
  MCP lifecycle; `tools/setup_serena.sh` → installer entry point).

The deviation is small, defensible, and avoids shipping broken
Windows-path JSON on POSIX hosts. Recording it for the reviewer.

## Observed Issues (out of scope)

- **`test_tester.sh` Test 2 — pre-existing UPSTREAM exit 1 failure.**
  Same root cause flagged in m27.2 and m27.3 CODER_SUMMARYs:
  `stages/tester_tdd.sh:84` uses `return` where the test expects
  `exit 1` on `AGENT_ERROR_CATEGORY=UPSTREAM`. Predates the m27.x
  series and m28. Out of scope for m28.1 (no Serena/MCP/template surface).

- **m28.1 leaves stale pre-existing `.claude/serena_mcp_config.json`
  files unfixed by design.** The `_resolve_mcp_config` early-return
  on `[[ -f "$default_config" ]]` still short-circuits before
  template re-generation. This is deliberate — m28.3 owns the
  stale-config migration. Mentioned only because a passive reader
  of the diff might think this is an oversight.
