# Coder Summary

## Status: COMPLETE

## What Was Implemented

m28.1 — Serena Template + Resolver Fix. First of three subtasks in the m28 arc.
Fixes the broken Serena MCP invocation surface so a fresh `tekhton
--setup-indexer --with-lsp` produces a config that boots Serena correctly.
Stale pre-existing configs are not touched (m28.3 handles that); no runtime
probe is added (m28.2 handles that).

### Re-run delta (this cycle)

The previous coder pass already landed the full m28.1 surface (template,
resolver, sed substitution, VERSION, CHANGELOG, test updates) in commit
`e3cc604`. This cycle re-verified the prior work and addressed two
follow-up issues flagged by the prior-cycle reviewer/tester reports:

1. **SC1091 blocker on `scripts/wedge-audit.sh`.** Reviewer report flagged
   that `shellcheck tests/test_stage_env_setu.sh scripts/wedge-audit.sh`
   exited 1 because the source-directive comment did not suppress SC1091.
   Verified the fix (`# shellcheck disable=SC1091` immediately above the
   `source` line) was already committed at HEAD by the prior coder pass.
   Re-ran the exact shellcheck invocation from the reviewer's repro to
   confirm exit 0 — blocker is closed. (My in-tree Edits to this file
   transitively produced identical content to HEAD; `git diff` is empty
   for this path, so there is no net change from this coder pass.)

2. **`VERSION` drift.** The acceptance criterion says `VERSION` reads
   `4.27.5`. Intermediate non-milestone pipeline runs between coder
   passes patch-bumped the file (observed at `4.27.15` on read; this is
   the same documented behavior the previous CODER_SUMMARY flagged for
   `4.27.14`). Reset to `4.27.5` per AC; the finalize hook on m28.1
   close will resolve the final number per the milestone strategy.

### Original m28.1 implementation (unchanged, verified in place this cycle)

1. **`tools/serena_config_template.json`** — Replaced the broken
   `"command": "{{SERENA_PYTHON}}", "args": ["-m", "serena",
   "--project-dir", "{{PROJECT_DIR}}"]` body with the console-script
   form: `"command": "{{SERENA_BIN}}", "args": ["start-mcp-server",
   "--project", "{{PROJECT_DIR}}", "--transport", "stdio",
   "--log-level", "ERROR"]`. `{{SERENA_PYTHON}}` removed entirely.

2. **`lib/mcp.sh`** — Declared `_SERENA_BIN=""` at module scope (line 25);
   extended `_resolve_serena_paths` with dual POSIX
   (`${.venv}/bin/serena`) and Windows (`${.venv}/Scripts/serena.exe`)
   lookup; substituted `{{SERENA_BIN}}` in `_resolve_mcp_config`;
   updated the prerequisite guard to check `_SERENA_BIN`.

3. **`tools/setup_serena.sh`** — Resolved `SERENA_BIN` immediately above
   the sed block (after pip install lands the entrypoint, per the
   Architecture Change Proposal in the previous CODER_SUMMARY);
   substituted `{{SERENA_BIN}}` in place of `{{SERENA_PYTHON}}`.

4. **`CHANGELOG.md`** — `### Fixed` entry under `[Unreleased]` (m28.1 tag).

5. **`tests/test_mcp.sh` + `tests/test_mcp_lifecycle.sh`** — Surgical
   `touch .../bin/serena` + `_SERENA_BIN=""` reset in tests that
   exercise the resolver.

## Acceptance Criteria — verified this cycle

- [x] `tools/serena_config_template.json` contains `start-mcp-server`
      and does NOT contain `"-m", "serena"`.
- [x] `lib/mcp.sh` declares `_SERENA_BIN=""` at module scope and
      assigns it in `_resolve_serena_paths` for both POSIX and Windows
      venv layouts; returns 1 when neither is present.
- [x] `_resolve_mcp_config` and `setup_serena.sh` both substitute
      `{{SERENA_BIN}}`; neither references `{{SERENA_PYTHON}}`.
- [x] `grep -rn '{{SERENA_PYTHON}}' tools/ lib/ tests/` returns zero
      matches.
- [x] `python -m json.tool` validates the generated config produced by
      the sed pipeline (template syntax is well-formed JSON).
- [x] `bash -n tools/setup_serena.sh lib/mcp.sh scripts/wedge-audit.sh`
      exits 0.
- [x] `bash tests/run_tests.sh` — 490 shell tests pass, all Go packages
      pass. One pre-existing failure (`test_tester.sh` Test 2,
      `stages/tester_tdd.sh:84` UPSTREAM `return` vs `exit 1`) is
      documented as predating m27.x in the prior reviewer report and
      is out of scope for m28.1.
- [x] `VERSION` reads `4.27.5`.
- [x] `CHANGELOG.md` has the m28.1 `### Fixed` entry under `[Unreleased]`.
- [x] `.claude/milestones/MANIFEST.cfg` row for `m28.1` is `pending`;
      finalize orchestrator's `mark_done` hook will flip it on close.

Additional gates verified:

- [x] `shellcheck tools/setup_serena.sh lib/mcp.sh scripts/wedge-audit.sh
      scripts/wedge-audit-companions.sh` exits 0.
- [x] `shellcheck tests/test_stage_env_setu.sh scripts/wedge-audit.sh`
      exits 0 (the prior-cycle reviewer's blocker repro).
- [x] `shellcheck tekhton.sh lib/*.sh stages/*.sh` exits 0.
- [x] `bash scripts/wedge-audit.sh` exits 0 (214 files audited clean).
- [x] `bash scripts/audit-bash-env.sh` exits 0 (m27.x env contract gate).
- [x] `bash tests/test_mcp.sh` — 22 PASS / 0 FAIL.
- [x] `bash tests/test_mcp_lifecycle.sh` — 3 PASS / 0 FAIL.

## Root Cause (bugs only)

m28.1 root causes (template + resolver) are documented in the prior
CODER_SUMMARY and unchanged here.

SC1091 blocker root cause: shellcheck without `-x` cannot follow `source`
directives even with `# shellcheck source=...`, because the directive
only tells it where to look, not whether to look. The two valid fixes
are (a) run shellcheck with `-x`, or (b) suppress with
`# shellcheck disable=SC1091`. The repo runs shellcheck without `-x`
in CI, so the disable directive is the correct fix and was already
landed in `e3cc604`.

## Files Modified (this cycle)

- `VERSION` — `4.27.15` → `4.27.5` (AC reset; finalize will rebump).

No other files were net-modified this cycle. The full m28.1 surface
(template, resolver, sed substitution, CHANGELOG, test updates, SC1091
disable directive) is present at HEAD from the previous coder commit
`e3cc604`. Edits attempted on `scripts/wedge-audit.sh` during this run
ended up matching the committed content exactly (`git diff` empty).

## Human Notes Status

No HUMAN_NOTES.md items present in this task. The Clarifications block
in the prompt contained Q&A pairs whose answers were copies of the
question text (noise carried over from prior runs); no signal to integrate.

## Docs Updated

None — no public-surface changes in this task. The user-visible surface
is the Serena MCP integration which was previously broken; the milestone
fixes it but does not add, remove, or rename any CLI flag, config key,
or other user-facing API. Internal helpers (`_SERENA_BIN`) are
underscore-prefixed and not part of the documented surface. CHANGELOG.md
gained the standard `Fixed` entry that documents the behavior change for
downstream consumers (committed in `e3cc604`).

## Observed Issues (out of scope)

- **`scripts/wedge-audit.sh` at 307 lines — over the 300-line bash
  ceiling.** Prior-cycle reviewer drift observation predicted this:
  the file was at 297 lines after m27.3 close, and one additional
  assertion block could push it over. The intervening commits
  (`97f19b4`, `e3cc604`) added a `WEDGE_AUDIT_EXTRA_FILES` env-override
  block (+10 lines) and the `# shellcheck disable=SC1091` line (+1)
  for the SC1091 fix. Net: file is 307 lines at HEAD, 7 over the
  ceiling. Out of scope for m28.1 — the milestone's "Files Modified"
  list does not include `scripts/wedge-audit.sh`, and this coder pass
  made zero net changes to it (`git diff` empty). The extraction
  pattern is already established (`scripts/wedge-audit-companions.sh`
  exists at 53 lines), so a follow-up milestone can lift either the
  `WEDGE_AUDIT_EXTRA_FILES` block or another assertion section into
  the companions file in a one-line move.

- **`test_tester.sh` Test 2 — pre-existing UPSTREAM exit 1 failure.**
  Same root cause flagged in m27.2 / m27.3 / m28.1 prior reviewer
  reports: `stages/tester_tdd.sh:84` uses `return` where the test
  expects `exit 1` on `AGENT_ERROR_CATEGORY=UPSTREAM`. Predates the
  m27.x series and m28. Out of scope for m28.1 (no Serena/MCP/template
  surface).

- **m28.1 leaves stale pre-existing `.claude/serena_mcp_config.json`
  files unfixed by design.** `_resolve_mcp_config` short-circuits on
  the existence of `$default_config`, so generation only happens on
  fresh projects. Deliberate — m28.3 owns stale-config migration.

## Architecture Change Proposals

The prior CODER_SUMMARY included an ACP justifying placing the
`SERENA_BIN` resolution above the sed block in `tools/setup_serena.sh`
(deviation from the milestone's literal wording, which placed it
after venv creation but before pip install completed). That ACP
stands; nothing in this re-run changes its rationale or scope.
