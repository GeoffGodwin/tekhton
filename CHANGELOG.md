# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
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
