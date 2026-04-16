# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
