# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [4.40.0] - 2026-06-05

### Added
- **m40 — resume parity fixes (m40.1 + m40.2).** Closes the auto-advance and
  milestone-mode resume gap exposed by the m34.1 dogfood. Before this arc, a
  halted milestone-mode run resumed via `tekhton --resume` rebuilt the
  `RunRequest` with `AutoAdvance=false` AND `Milestone=""`, leaving
  `MILESTONE_MODE=false` through the finalize chain. `_hook_mark_done` then
  skipped silently and the manifest never advanced — the operator could run
  the same milestone successfully several times in a row without it flipping
  to `done`.
- **m40.1 — snapshot proto auto-advance fields.** `StateSnapshotV1` now carries
  `auto_advance` (bool) and `auto_advance_limit` (int) as first-class fields
  with `omitempty` JSON tags. The runner's `requestFromSnapshot` copies both
  onto the rebuilt `RunRequestV1`, so `tekhton --resume` no longer drops the
  auto-advance arc the operator originally started with
  `--auto-advance --auto-advance-limit N`. The bash writer
  (`lib/state_helpers.sh::write_pipeline_state`) emits both fields keyed off
  `AUTO_ADVANCE` / `AUTO_ADVANCE_LIMIT` env vars (already populated by the
  m26 env builder for milestone-mode runs). Backward-compat preserved: state
  files written without the keys load cleanly with zero-value fields.
- **m40.2 — state writer milestone_id field.** `lib/state_helpers.sh`
  `_state_write_snapshot` now sources `milestone_id` from a three-tier
  precedence chain: explicit 6th positional argument, then `MILESTONE_ID`
  (the m26 env-contract carrier), then `_CURRENT_MILESTONE` (the legacy
  bash-orchestrator global). All-empty means a non-milestone task run and
  the field is omitted through omitempty parity. Previously, only callers
  that explicitly passed the 6th positional emitted milestone_id; stage-
  level `write_pipeline_state` sites in `stages/coder.sh`,
  `stages/review.sh`, `stages/tester.sh`, etc. did not, so a halted
  milestone-mode run lost the milestone identity on resume.
- `cmd/tekhton/state.go::applyField` and `lookupField` extended to handle
  `reflect.Bool` so the `tekhton state update --field auto_advance=true`
  hop the bash writer uses round-trips correctly.
- `tests/test_state_writer_resume_fields.sh` — extended shim-boundary
  integration test. m40.1 scenarios cover `AUTO_ADVANCE=true
  AUTO_ADVANCE_LIMIT=4` round-trip through both writer paths. m40.2 adds
  six scenarios across bash-fallback and Go-path writers: MILESTONE_ID env
  set, _CURRENT_MILESTONE legacy fallback, and both-unset task-mode.
- `internal/runner/resume_test.go` — three new Go tests:
  `TestRequestFromSnapshotMilestoneIDFixture` loads a hand-authored
  `milestone_id:"m34.2"` fixture and asserts the rebuilt request routes to
  milestone mode; `TestRequestFromSnapshotMilestoneIDAbsentFallsThrough`
  anchors the backward-compat path (no key → task mode); m40.1 added
  `TestRequestFromSnapshotAutoAdvanceFields`,
  `TestRequestFromSnapshotAutoAdvanceBackwardCompat`, and
  `TestStateSnapshotAutoAdvanceJSONRoundTrip` covering the auto-advance
  round-trip.

## [4.35.0] - 2026-06-03

### Changed
- **Security stage ported to Go (m35).** `stages/security.sh` (167 LOC) and
  `lib/security_helpers.sh` (240 LOC across the m35.1 shim arc) deleted —
  407 LOC of bash retired. The security stage now dispatches through
  `internal/stages/security/RunStage` via the M34 stage-port pattern.
  Severity classification, finding parsing, and `HUMAN_ACTION_REQUIRED.md`
  escalation are Go-native (`internal/security/`). Routing through
  `internal/drift.HumanAction.Append` centralizes the escalation surface
  across stages.

### Added
- `scripts/wedge-audit-companions.sh` m35.3 ban block — forbids
  re-introduction of `stages/security.sh`, `lib/security_helpers.sh`, and
  the nine deleted helper function names (`_parse_security_findings`,
  `_severity_meets_threshold`, `_build_fixable_block`,
  `_build_unfixable_block`, `_build_notes_block`,
  `_handle_unfixable_findings`, `_write_security_notes`,
  `_security_is_docs_only`, `_has_blocking_findings`). Files needing
  the names in comments may opt out with `# --m35-allowlist`.
- `tests/test_wedge_audit_m35.sh` regression test (6 scenarios) for the
  m35.3 ban block — plants file/function/allowlist variants and asserts
  the audit's pass/fail behavior.
- `tests/test_security_parity.sh` end-to-end parity gate driving
  `tekhton run-stage security` through three scenarios
  (`pass-no-findings`, `fixable-cycle-1-resolved`, `unfixable-escalate`)
  via the `testdata/fake_security_agent.sh` fixture. Baselines under
  `tests/baselines/m35-security/`. Wired into `make dogfood`.
- `testdata/fake_security_agent.sh` — purpose-built fake supervisor binary
  for the parity gate. Emits two turn events and conditionally writes
  pre-canned `SECURITY_REPORT.md` content per scenario + cycle.

### Operator notes
- `tekhton security parse-findings --report PATH [--format tsv|json]` is
  available as an inspection tool for `SECURITY_REPORT.md` files.
- `tekhton security meets-threshold --severity SEV --threshold THR`
  exposes the classification predicate for debugging.
- `SECURITY_AGENT_ENABLED=false` continues to skip the stage entirely;
  no behavior change.
- The prompt templates (`prompts/security_scan.prompt.md`,
  `prompts/security_rework.prompt.md`,
  `prompts/specialist_security.prompt.md`) are unchanged — only the
  rendering caller moved.

## [4.30.0] - 2026-05-30

### Added
- `internal/crawler/rescan.go` — `Rescan(ctx, opts)` ports the eight-
  branch decision tree from `rescan.sh::rescan_project`. Falls back to
  full crawl on every legacy branch (missing index, no meta.json, not a
  git repo, no scan commit, rebased-away commit, major change set);
  drives selective regen on the incremental path. (m30.2)
- `internal/crawler/significance.go` — `ClassifyChanges` returns
  Trivial / Moderate / Major using the load-bearing thresholds from
  `_detect_significant_changes` (2+ manifests OR 5+ new dirs OR 10+
  deletions → Major). (m30.2)
- `internal/crawler/changes.go` — `DetectChangedFiles` runs git diff +
  git status porcelain, deduplicates by path (working-tree wins),
  preserves bash's R-status rename pair handling. (m30.2)
- `internal/crawler/metadata.go` — `ExtractScanMetadata`,
  `IsManifestFile`, `IsConfigFile`, `ExtractSampledFiles`. Structured
  meta.json read with legacy HTML-comment header fallback for pre-M68
  projects. (m30.2)
- `tekhton crawler rescan` Cobra subcommand replaces the m30.1
  placeholder. `--full` forces a full crawl regardless of change
  detection; `--json` emits a summary envelope with mode, significance,
  change count, and regenerated section list. (m30.2)
- `tests/test_rescan_parity.sh` — four-scenario parity gate
  (no_changes, trivial, moderate_manifest, major_manifest) drives
  `--json` against fixtures under
  `internal/crawler/testdata/rescan_scenarios/` and asserts the exact
  (mode, significance, regenerated_sections) verdict per scenario. (m30.2)

### Changed
- `tekhton-legacy.sh` `--rescan` block exec's `tekhton crawler rescan`
  directly; the bash `rescan_project` function no longer exists. View
  generation (`generate_project_index_view`) still runs in bash until
  m31+ ports the index-view subsystem. (m30.2)
- `scripts/wedge-audit.sh` PATTERNS extended: now blocks
  `source lib/rescan*.sh`, `rescan_project()`, `_update_index_sections()`,
  `_get_changed_files_since_scan()`, `_detect_significant_changes()`,
  `_is_manifest_file()`, `_is_config_file()`, `_extract_sampled_files()`,
  `_record_scan_metadata()` from being reintroduced anywhere in
  `lib/` or `stages/`. (m30.2)

### Removed
- `lib/rescan.sh` (50-line m30.1 shim) and `lib/rescan_helpers.sh`
  (deleted earlier) — the entire rescan bash surface retires with
  m30.2. (m30.2)
- `tests/test_rescan.sh` — m30.1 skip stub superseded by
  `tests/test_rescan_parity.sh`. (m30.2)
- `internal/crawler/rescan_stub.go` — m30.1 placeholder sentinel; real
  rescan landed. (m30.2)

### Notes
- Closes the m30 Crawler Port arc — 8 bash files retired across m30.1
  (six `crawler*.sh`) and m30.2 (two `rescan*.sh`), ~1.7k LOC ported
  to Go. `VERSION` bumps to 4.30.0 marking arc close (matches m27.3
  pattern: minor bump at the closing child, not at the opening one).

## [4.28.0] - 2026-05-29

### Added
- `_is_stale_serena_config` detects and replaces pre-m28.1 Serena MCP
  configs that invoke `python -m serena`, preserving a timestamped
  backup at `<config>.bak.<ts>`. Stale projects pick up the fix on
  next pipeline run with no manual intervention. (m28.3)
- `tests/test_serena_template_substitution.sh` plus three new
  `_probe_serena_startup` scenarios in `tests/test_mcp.sh` cover the
  m28 arc end-to-end. New fixtures under `tests/fixtures/serena_configs/`
  pin the stale vs. correct shape diff. (m28.3)

### Changed
- `start_mcp_server` now smoke-tests the resolved Serena binary with a
  2-second `serena start-mcp-server --help` probe before declaring
  success. On probe failure: warns and continues without LSP-backed
  tools, instead of silently logging `Serena MCP integration enabled`
  for a dead server. The pipeline-level `[✓] Indexer + Serena MCP
  ready` checkpoint now reflects actual probe state. (m28.2)

### Fixed
- Serena MCP config template emits `serena start-mcp-server` (the
  console script) instead of `python -m serena` (which fails with
  `No module named serena.__main__`). Affects fresh configs generated
  by `tekhton --setup-indexer --with-lsp` or any project missing
  `.claude/serena_mcp_config.json`. Stale broken configs from earlier
  versions are migrated in m28.3. (m28.1)

## [4.22.0] - 2026-05-18

### Added
- skip-guard 2 pre-existing failing tests before m22 dogfood (M22)
## [4.20.5] - 2026-05-09

### Added
- Address all 10 open non-blocking notes in .tekhton/NON_BLOCKING_LOG.md.

## [4.20.4] - 2026-05-09

### Added
- [POLISH] **m01/m02 milestone-doc cleanup pass.** Four small doc nits sur
## [4.20.3] - 2026-05-09

### Added
- [BUG] At the end of a `--fix-nonblockers` run, the action-items summary

## [4.20.2] - 2026-05-09

### Added
- emit post-loop action-items refresh in _run_fix_nonblockers_loop
## [4.20.1] - 2026-05-09

### Added
- Bounded the unbounded retry loop reported in HUMAN_NOTES (`stages/intake.sh: line 73`

## [4.20.0] - 2026-05-09

### Added
- Fixed the bug described in the task — Go `BashAdapter.Run` was sourcing only
## [4.19.0] - 2026-05-08

### Added
- [MILESTONE 18 ✓] feat: M18 (M19)

## [4.18.0] - 2026-05-08

### Added
- New milestones for continuation of the Go conversion (M18)
## [4.17.1] - 2026-05-07

### Added
- All 8 open non-blocking notes addressed:

## [4.17.0] - 2026-05-07

### Added
- Milestone 17 — Error Taxonomy Wedge. The bash error classification engine (M17)
## [4.16.0] - 2026-05-07

### Added
- Milestone 16 — Config Loader Wedge. Pipeline configuration loading, (M16)

## [4.15.0] - 2026-05-07

### Added
- Phase 4 wedge — port the prompt template engine from `lib/prompts.sh` into a (M15)
## [4.14.1] - 2026-05-07

### Added
- Addressed all 17 open non-blocking notes in `.tekhton/NON_BLOCKING_LOG.md`. The

## [4.14.0] - 2026-05-06

### Added
- Ported the milestone-DAG state machine from four bash files (~600 LOC) into a (M14)
## [4.13.0] - 2026-05-06

### Added
- Ported MANIFEST.cfg parsing and writing from bash (`lib/milestone_dag_io.sh`, (M13)

## [4.12.0] - 2026-05-06

### Added
- Setup phase 4 of v4 milestones (M12)
## [4.11.0] - 2026-05-06

### Added
- m11 is a decision milestone — produces no runtime code change. Deliverables: (M11)

## [4.10.0] - 2026-05-06

### Added
- [MILESTONE 9 ✓] feat: Implement Milestone 9: Windows/WSL Reaper + fsnotify Change Detection (M10)
## [4.9.0] - 2026-05-06

### Added
- [MILESTONE 8 ✓] feat: Implement Milestone 8: Quota Pause/Resume + Retry-After Parsing (M9)

## [4.8.0] - 2026-05-05

### Added
- [MILESTONE 07 ✓] feat: M07 (M8)
## [4.07.0] - 2026-05-05

### Added
- wire Go into the test gate + fix two latent bugs the gate exposed (M07)

## [4.5.2] - 2026-05-05

### Added
- Closed all 5 open items in `.tekhton/NON_BLOCKING_LOG.md`. Two items had already
## [4.5.1] - 2026-05-05

### Added
- Addressed all 14 open non-blocking notes in `.tekhton/NON_BLOCKING_LOG.md`. Items

## [4.5.0] - 2026-05-05

### Added
- m05 opens Phase 2 of the V4 Go migration with the agent supervisor scaffold: (M5)
## [4.4.0] - 2026-05-05

### Added
- m04 closes Phase 1 of the V4 Go migration with gates and docs (no behavior (M4)

## [4.3.0] - 2026-05-04

### Added
- m03 — Pipeline State Wedge. The pre-m03 178-line `lib/state.sh` heredoc (M3)
## [4.01.0] - 2026-05-04

### Added
- m02 — Causal Log Wedge. The causal event log writer moves from bash (M2)

## [3.01.0] - 2026-05-04

### Added
- m01 — Go Module Foundation. Bootstraps the Go module in-repo, stands up a (M01)
## [3.138.4] - 2026-04-30

### Added
- Addressed all 30 open non-blocking notes in `.tekhton/NON_BLOCKING_LOG.md`. Real

## [3.138.3] - 2026-04-30

### Added
- Defensive observability fix for the TUI sidecar's silent-death failure mode in
## [3.138.2] - 2026-04-30

### Added
- The polish note requested adding the immediate working-directory name to the

## [3.138.1] - 2026-04-30

### Added
- Fixed the BUG where `tekhton --report` printed literal `\033[...]` strings on
## [3.138.0] - 2026-04-28

### Added
- Milestone 138 — Resilience Arc: Runtime CI Environment Auto-Detection. When (M138)

## [3.137.0] - 2026-04-27

### Added
- M137 — Resilience Arc V3.2 Migration Script. Created the V3.1 → V3.2 (M137)
## [3.136.0] - 2026-04-27

### Added
- M136 — Resilience Arc Config Defaults & Validation Hardening. Config-layer (M136)

## [3.135.0] - 2026-04-27

### Added
- M135 — Resilience Arc Artifact Lifecycle Management. Four hygiene fixes (M135)
## [3.134.0] - 2026-04-27

### Added
- M134 — Resilience Arc Integration Test Suite & Cross-Cutting Regression Harness. (M134)

## [3.133.0] - 2026-04-27

### Added
- All eight goals from the milestone spec, plus the mandatory doc surface and (M133)
## [3.132.0] - 2026-04-27

### Added
- All ten goals from the milestone spec, plus the mandatory doc surface and (M132)

## [3.131.0] - 2026-04-27

### Added
- All seven milestone goals plus mandatory extras: (M131)
## [3.130.0] - 2026-04-27

### Added
- All six milestone goals plus mandatory extras: (M130)

## [3.129.0] - 2026-04-26

### Added
- Milestone 129 — Failure Context Schema Hardening & Primary/Secondary Cause (M129)
## [3.128.0] - 2026-04-26

### Added
- Milestone 128 — Build-Fix Continuation Loop & Adaptive Turn Budgeting. (M128)

## [3.127.0] - 2026-04-26

### Added
- Milestone 127 — Mixed-Log Classification Hardening & Confidence-Based Routing. (M127)
## [3.126.0] - 2026-04-26

### Added
- M126 — Deterministic UI Gate Execution & Non-Interactive Reporter Control. (M126)

## [3.125.4] - 2026-04-25

### Fixed
- TUI sidecar orphan after build-gate-failure exit. When the build gate failed and the parent shell exited via `error "…"; exit 1` (e.g. `stages/coder.sh:1167` and sibling sites), `tools/tui.py` could remain alive indefinitely with a stale `.claude/tui_sidecar.pid` left on disk. Three coupled fixes:
  - `lib/tui.sh::tui_stop` — dropped the `_TUI_ACTIVE` early-return guard and added a pidfile fallback so the EXIT trap reaps the sidecar even when `_TUI_ACTIVE` was flipped false earlier in the run. Pidfile is now removed on every code path (alive process, dead PID, or no PID at all). `tui_complete` keeps its happy-path guard — the asymmetry is intentional.
  - `tools/tui.py` — added a double-timeout watchdog escape hatch that fires on `2 × watchdog_secs` of status-file staleness regardless of `current_agent_status` / `agent_turns_used`, closing the gap where the original watchdog preconditions were unreachable in the orphan scenario.
  - Regression coverage: `tests/test_tui_stop_orphan_recovery.sh`, `tests/test_tui_orphan_lifecycle_integration.sh`, and watchdog tests in `tools/tests/test_tui.py`.

### Changed
- Stage Timings panel — long-label truncation. Substage breadcrumbs like `wrap-up » running final static analyzer` were pushing the right-aligned time/turns columns off-screen. `_truncate(s, limit)` was promoted from `tools/tui_render.py` into a new `tools/tui_render_common.py` module (avoids a circular import) and applied with a 32-char cap (`_LABEL_MAX_CHARS`) to both completed-stage labels and the live-row breadcrumb in `tools/tui_render_timings.py`. The column's existing `overflow="fold"` remains as a backstop on narrow terminals.

### Docs
- 300-line file ceiling — data-only exemption. Added an explicit carve-out in `CLAUDE.md` (Non-Negotiable Rule #8) for files containing only `:=` defaults, constant declarations, and shared clamp/validation helper calls — no function bodies, no conditional logic. Documents `lib/config_defaults.sh` as the canonical example.

## [3.125.3] - 2026-04-24

### Fixed
- `gh release create` failure due to unsupported `--latest` flag; removed flag, GitHub handles latest promotion automatically.
- Jekyll GitHub Pages build failure caused by unguarded `{%s}` printf format string in `DESIGN_v4.md` being parsed as an unterminated Liquid tag; wrapped block in `{% raw %}...{% endraw %}`.
- Missing `{% endraw %}` closing tag that would have caused the raw block to consume the rest of the document.

## [3.125.2] - 2026-04-24

### Added
- Resolved the single open non-blocking note in `.tekhton/NON_BLOCKING_LOG.md`
## [3.125.1] - 2026-04-24

### Added
- Fixed NON_BLOCKING_LOG and put the log back.

## [3.125.0] - 2026-04-23

### Added
- M125 — Quota Pause Refresh Accuracy & Probe Budget. Three correctness fixes (M125)
## [3.124.0] - 2026-04-23

### Added
- M124 — TUI Quota-Pause Awareness & Spinner Coordination. Issue #180: (M124)

## [3.123.0] - 2026-04-23

### Added
- M123 — Indexer Grammar Coverage Audit & Silent-Failure Prevention. Defence- (M123)
## [3.122.3] - 2026-04-23

### Added
- Fixed the GitHub Actions checkout failure caused by an untracked-but-committed

## [3.122.2] - 2026-04-23

### Added
- Added `tui_reset_for_next_milestone()` in `lib/tui_ops.sh` and wired it into
## [3.122.1] - 2026-04-23

### Added
- Moved acceptance-criteria quality lint from end-of-run acceptance checking

## [3.122.0] - 2026-04-23

### Added
- M122 — Indexer Multi-Grammar Package Support + Diagnostic Plumbing (M122)
## [3.121.0] - 2026-04-22

### Added
- M121 — Planning Path Write-Failure Hardening + Empty-Slate Test Coverage. (M121)

## [3.120.0] - 2026-04-22

### Added
- M120 — Planning Mode DESIGN_FILE Default Restoration. Four goals: (M120)
## [0.1.60] - 2026-04-22

### Added
- M119 is a quality gate, not a feature. Two deliverables: (M119)

## [0.1.59] - 2026-04-22

### Added
- **Goal.** Eliminate the "stage said success before its pill turned green" (M118)
## [0.1.58] - 2026-04-22

### Added
- **Goal.** Recent Events log entries in the TUI now carry a `source` field that (M117)

## [0.1.57] - 2026-04-22

### Added
- Addressed all 12 open non-blocking notes in `.tekhton/NON_BLOCKING_LOG.md`. Several
## [0.1.56] - 2026-04-22

### Added
- M116 — Migrating rework + architect-remediation onto the M113 substage API, (M116)

## [0.1.55] - 2026-04-22

### Added
- Milestone 115 — `run_op` migration onto the M113 substage API and full (M115)
## [0.1.54] - 2026-04-22

### Added
- M114 — TUI Renderer + Scout Substage Migration. Three coordinated changes: (M114)

## [0.1.53] - 2026-04-21

### Added
- M113 — TUI Hierarchical Substage API. (M113)
## [0.1.52] - 2026-04-21

### Added
- M110 — TUI Stage Lifecycle Semantics and Timings Coherence. (M110)

## [0.1.51] - 2026-04-21

### Added
- M112 — Pre-Run Dedup Coverage Hardening. (M112)
## [0.1.50] - 2026-04-21

### Added
- M111 — Fix Milestone Splitting for DAG Mode. Three compounding bugs that prevented (M111)

## [0.1.49] - 2026-04-21

### Added
- TUI sidecar lifecycle is now scoped to the outer `tekhton.sh` invocation rather
## [0.1.48] - 2026-04-21

### Added
- Address all 12 open non-blocking notes in .tekhton/NON_BLOCKING_LOG.md.

## [0.1.47] - 2026-04-21

### Added
- [MILESTONE 110 ✓] feat: M110 - TUI Stage Lifecycle Semantics and Timings Coherence
## [0.1.46] - 2026-04-20

### Added
- docs(m110): tighten TUI lifecycle milestone design (M110)

## [0.1.45] - 2026-04-20

### Added
- Addressed all 6 open non-blocking notes from `.tekhton/NON_BLOCKING_LOG.md`.
## [0.1.44] - 2026-04-20

### Added
- M109 — Init Feature Wizard. Adds a guided feature wizard step to `tekhton --init` (M109)

## [0.1.43] - 2026-04-20

### Added
- Implemented the M108 design: the bottom of the TUI now splits into a (M108)
## [0.1.42] - 2026-04-20

### Added
- M107 wires every pipeline stage into the M106 TUI protocol API (M107)

## [0.1.41] - 2026-04-20

### Added
- Address all 11 open non-blocking notes in .tekhton/NON_BLOCKING_LOG.md. (M106)
## [0.1.40] - 2026-04-20

### Added
- Addressed all 11 open non-blocking notes in `.tekhton/NON_BLOCKING_LOG.md`:

## [0.1.39] - 2026-04-19

### Added
- M105 — Test Run Deduplication. Skips redundant `TEST_CMD` executions by hashing (M105)
## [0.1.38] - 2026-04-19

### Added
- Milestone 104 — TUI Operation Liveness. A `run_op LABEL CMD...` wrapper that (M104)

## [0.1.37] - 2026-04-19

### Added
- Milestone 103: Output Bus Tests + Integration Validation — automated test (M103)
## [0.1.36] - 2026-04-19

### Added
- M102 — TUI-Aware Finalize + Completion Flow. The core implementation was (M102)

## [0.1.35] - 2026-04-19

### Added
- M101 — Eliminate Direct ANSI Output. All 91 direct `echo -e "...${BOLD|RED|GREEN|YELLOW|CYAN|NC}..."` calls across the 10 target library files have been migrated to the new structured formatters in `lib/output_format.sh` or to the existing `log`/`warn`/`error`/`success` wrappers that route through `_out_emit`. (M101)
## [0.1.34] - 2026-04-19

### Added
- M100 — Dynamic Stage Order + TUI Sync. The TUI stage-pill row is now built (M100)

## [0.1.33] - 2026-04-19

### Added
- Updated the milestone plan with 99-103 (M99)
## [0.1.32] - 2026-04-18

### Added
- Addressed all 3 open non-blocking notes in `.tekhton/NON_BLOCKING_LOG.md` and moved them to the Resolved section.

## [0.1.31] - 2026-04-18

### Added
- M98 TUI Redesign — Layout, Run Context, Logo Animation & Completion Hold. (M98)
## [0.1.30] - 2026-04-18

### Added
- Addressed the single open non-blocking note — a stale acceptance criterion in

## [0.1.29] - 2026-04-18

### Added
- Address all 7 open non-blocking notes in .tekhton/NON_BLOCKING_LOG.md. F
## [0.1.28] - 2026-04-18

### Added
- Bug 1 — "TestTimeout" text flickering at the TUI border (agent.sh:170) The spinner subshell in run_agent() was unconditionally writing printf '\r...' > /dev/tty, which conflicts with rich's alternate screen buffer. Now guarded by [[ "${_TUI_ACTIVE:-false}" != "true" ]] — the spinner still ticks tui_update_agent (so the TUI gets turn updates) but no longer writes text to the terminal itself.

## [0.1.27] - 2026-04-17

### Added
- Dual output TUI fix
## [0.1.26] - 2026-04-17

### Added
- Milestone 97 — TUI Mode (rich.live sidecar). Opt-in full-screen status display (M97)

## [0.1.25] - 2026-04-17

### Added
- [MILESTONE 94 ✓] feat: M94 (M96)
## [0.1.24] - 2026-04-17

### Added
- Milestone 94 — Failure Recovery CLI Guidance & `--diagnose` Overhaul. (M94)

## [0.1.23] - 2026-04-17

### Added
- Milestone 93 — Rejection Artifact Preservation & Smart Resume Routing. (M93)
## [0.1.22] - 2026-04-17

### Fixed
- Addressed the 5 open non-blocking notes in `.tekhton/NON_BLOCKING_LOG.md`:

## [0.1.21] - 2026-04-17

### Added
- M95 — split `lib/test_audit.sh` (574 → 269 lines) into three companion modules. (M95)
## [0.1.20] - 2026-04-16

### Added
- M92 — Pristine Test State Enforcement. The pipeline now treats `pre_existing` (M92)

## [0.1.19] - 2026-04-16

### Added
- Milestone 91: Adaptive Rework Turn Escalation. When the orchestrator hits (M91)
## [0.1.18] - 2026-04-16

### Added
- Milestone 90 — Auto-Advance Fix. Two independent bugs in `--auto-advance` are fixed: (M90)

## [0.1.17] - 2026-04-16

### Added
- Refactored `run_test()` to invoke each test exactly once and reuse the
## [0.1.16] - 2026-04-16

### Added
- Address all 10 open non-blocking notes in .tekhton/NON_BLOCKING_LOG.md. (M89)

## [0.1.15] - 2026-04-15

### Added
- Addressed all 10 open non-blocking notes in NON_BLOCKING_LOG.md:
## [0.1.14] - 2026-04-15

### Added
- Verified all 16 M88 acceptance criteria are satisfied

## [0.1.13] - 2026-04-15

### Fixed
- Fixed 5 remaining failing shell tests with stale file path expectations after the b3b6aff CLI flag refactor moved pipeline artifacts from project root into `.tekhton/` subdirectory.
## [0.1.12] - 2026-04-14

### Added
- [MILESTONE 86 ✓] feat: M86 (M87)

## [0.1.11] - 2026-04-14

### Added
- Added "Negative Space" to the required sections list in `draft_milestones_validate_output()` so the validation function enforces M86's new section requirement (M86)
## [0.1.10] - 2026-04-14

### Added
- Created `lib/milestone_acceptance_lint.sh` with three lint checks: behavioral criterion detection, refactor completeness grep, config self-referential check (M85)

## [0.1.9] - 2026-04-14

### Added
- Added 83-87 to the DAG and properly marked 83 as done. (M84)
## [0.1.8] - 2026-04-13

### Added
- [MILESTONE 82 ✓] feat: M82 (M83)

## [0.1.7] - 2026-04-13

### Added
- Milestone 82: Milestone Progress CLI & Run-Boundary Guidance (M82)
## [0.1.6] - 2026-04-13

### Added
- Merge pull request #175 from GeoffGodwin/milestones/80 (M81)

## [0.1.5] - 2026-04-13

### Added
- **`lib/draft_milestones.sh`** (NEW) — Interactive milestone authoring flow entry point. Contains `run_draft_milestones()`, `draft_milestones_next_id()`, and `draft_milestones_build_exemplars()`. Sources `draft_milestones_write.sh`. 223 lines. (M80)
## [0.1.4] - 2026-04-13

### Added
- Slimmed README.md from 845 lines to 196 lines (well under the 300-line cap) (M79)

## [0.1.3] - 2026-04-13

### Added
- Addressed all 10 open non-blocking notes in NON_BLOCKING_LOG.md:

## [0.1.2] - 2026-04-13

### Added
- Rewrote README.md Install section: curl|bash one-liner is now the headline install method, followed by Homebrew tap, then from-source as a secondary option (M78)

## Historical (pre-M77)

These entries were previously in the README. They were moved here in
[M79](/.claude/milestones/m79-readme-restructure-docs-split.md).
See [docs/changelog.md](docs/changelog.md) for the detailed version history.

### v3.79.0 — README Restructure + docs/ Split (April 2026)

- Slimmed README from 845 lines to ≤300 lines focused on the happy path
- Moved reference material into `docs/` (13 new topic files)
- Moved historical changelog entries from README to CHANGELOG.md

### v3.78.0 — Install UX (April 2026)

- curl|bash one-liner promotion, Homebrew tap, install.sh

### v3.71.0 — Structured Project Index & Code Quality (April 2026)

5 milestones (M67–M71): structured data layer for project crawling, consumer
migration to bounded reader API, view generator and rescan rewrite, coder
pre-completion self-check, shell hygiene rules.

### v3.66 — Context-Aware Pipeline (April 2026)

66 milestones delivered across the V3 initiative. Key themes:
- Milestone DAG with dependency tracking and sliding context window
- Tree-sitter repo maps with PageRank ranking
- Security agent, intake agent, UI/UX specialist
- Watchtower browser dashboard with live run monitoring
- Brownfield intelligence (tech stack detection, health scoring)
- Notes pipeline rewrite with tag-specialized execution
- Express mode, TDD support, browser planning, dry-run preview
- Error pattern registry, auto-remediation engine, pre-flight validation
- UI platform adapters (web, mobile, game engines)
- Repo map cross-stage cache, tester surgical fix mode
- Structured run memory, progress transparency, causal event log

### v2.21.0 — Adaptive Pipeline (March 2026)

21 milestones: autonomous operation (`--complete`, `--auto-advance`, `--human`),
transient error retry, turn-exhaustion continuation, milestone auto-split, context
budgeting, specialist reviews, autonomous debt sweeps, error taxonomy, metrics
dashboard, brownfield init/replan, clarification protocol, security hardening.

### v1.0 — Foundation (March 2026)

Core pipeline (Scout → Coder → Reviewer → Tester), dynamic turn limits, architecture
drift detection, build gates, `--plan` interactive planning, human notes, pipeline
state persistence, FIFO-isolated agent invocation, `--milestone` mode.
