# Changelog

## v3.66 — Context-Aware Pipeline (April 2026)

66 milestones delivered across the V3 initiative. Changes grouped by theme:

### Milestone DAG & Intelligent Indexing (M1–M8)

- File-based milestones with `MANIFEST.cfg` dependency tracking and parallel groups
- Sliding context window — only active + frontier milestones injected into prompts
- Automatic migration from inline CLAUDE.md milestones (`--migrate-dag`)
- Tree-sitter repo maps with PageRank ranking and token-budgeted output
- Task-relevant context slicing per pipeline stage
- Cross-run file association tracking for personalized ranking
- Serena LSP integration via MCP for live symbol lookup
- Indexer setup command (`--setup-indexer`) and Python virtualenv management

### Quality & Safety (M9–M10, M20, M28–M30, M33, M39, M43–M44)

- Dedicated security agent stage with OWASP-aware scanning, severity scoring, and auto-remediation
- Task intake / PM agent with clarity scoring, scope assessment, and task decomposition
- Test integrity audit for verifying test file quality
- UI test awareness and E2E prompt integration
- UI validation gate with headless smoke testing
- Build gate hardening: hang prevention, timeout enforcement, process tree cleanup
- Human mode completion loop and state fidelity improvements
- Notes injection hygiene and action items UX with severity colors
- Test-aware coding — coder receives test context for targeted implementations
- Jr coder test-fix gate for automatic test repair

### Watchtower Dashboard (M13–M14, M34–M38, M66)

- Browser-based pipeline monitoring with Live Run, Milestone Map, Reports, and Trends tabs
- Causal event log (JSONL) for structured debugging and cross-run learning
- Data fidelity fixes and smart refresh with context-aware layout
- Interactive controls and parallel teams readiness (V4-ready data model)
- Live Run and Milestone Map UX polish
- Security summary view and health score display
- Full-stage metrics with hierarchical breakdown — every timed step (security, audit,
  cleanup, specialists, rework cycles) now appears in the Per-Stage Breakdown with
  collapsed-by-default drill-down

### Brownfield Intelligence (M11–M12, M15, M22)

- AI artifact detection with archive, tidy, and ignore handling modes
- Deep analysis: workspace, service, CI/CD, infrastructure, test framework detection
- Documentation quality assessment
- Project health scoring with five-category assessment and belt ratings
- Init UX overhaul with improved detection and onboarding flow

### Developer Experience (M17–M19, M21, M23–M27, M31–M32, M52)

- Pipeline diagnostics and recovery guidance (`--diagnose`)
- Documentation site with MkDocs Material theme and GitHub Pages deployment
- Distribution and install experience improvements
- Version migration framework (`--migrate`, `--migrate --check`, `--migrate --rollback`)
- Dry-run preview mode (`--dry-run`) — scout + intake only
- Run safety net with `--rollback` for reverting pipeline runs
- Human notes UX enhancement with `note` subcommand
- Express mode — zero-config execution when no `pipeline.conf` exists
- TDD support with `PIPELINE_ORDER=test_first`
- Planning answer layer with file-based answer import
- Browser-based planning interview (`--plan-browser`)
- Context-aware onboarding flow (M52) — `--init` and `--plan` next-steps messages
  detect what artifacts already exist, ending the previous circular prompts; new
  `--init --full` chains init and synthesis in one invocation for brownfield projects

### Acceleration (M40–M50)

- Human notes core rewrite with cleaner state management
- Note triage and sizing gate (`--triage`)
- Tag-specialized execution paths for BUG, FEAT, POLISH
- Scout leverages repo map and Serena for better file discovery
- Instrumentation and timing report with stage-level duration tracking
- Intra-run context cache to avoid redundant file reads
- Reduced unnecessary agent invocations via smarter skip logic
- Structured run memory (JSONL) for cross-run learning with keyword filtering
- Progress transparency with timing estimates from run history

### Resilience & Auto-Remediation (M53–M56)

- **Error pattern registry (M53)** — A declarative bash registry classifies build/test
  output into six categories (`env_setup`, `service_dep`, `toolchain`, `resource`,
  `test_infra`, `code_error`). Only true code errors reach the build-fix agent.
- **Auto-remediation engine (M54)** — When the registry identifies a `safe`-rated
  fix (e.g., `npx playwright install`, `npm install`, port cleanup), the build gate
  runs it automatically and re-tries the failed phase. `prompt`-rated remediations
  are written to `HUMAN_ACTION_REQUIRED.md`; `manual`-rated issues get clear
  diagnosis but no automated action. Capped at 2 attempts per gate, all logged to
  the causal event log.
- **Pre-flight environment validation (M55)** — A new pipeline stage runs after
  config loading but BEFORE any agent invocation, catching missing toolchains,
  stale `node_modules`, or missing Playwright browsers before the coder spends
  20+ turns. Auto-remediates safe issues via the M54 engine; halts the run with
  actionable diagnosis on blocking issues. Toggle with `PREFLIGHT_ENABLED`.
- **Service readiness probing (M56)** — Pre-flight cross-references Docker Compose,
  test framework configs, and code imports to infer required services (PostgreSQL,
  Redis, MySQL, MongoDB, RabbitMQ, Kafka, etc.), then probes them with a 1-second
  TCP connect. Down services produce actionable startup instructions instead of
  cryptic `ECONNREFUSED` errors deep in test output.

### UI Platform Adapters (M57–M60)

- **Adapter framework (M57)** — A new `platforms/` directory holds per-platform
  detection, coder guidance, specialist checklists, and tester patterns. Replaces
  the previous web-centric hardcoded `{{IF:UI_PROJECT_DETECTED}}` blocks. Set
  `UI_PLATFORM=auto` (default) to auto-detect or pin via `UI_PLATFORM=web|
  mobile_flutter|mobile_native_ios|mobile_native_android|game_web`.
- **Web adapter (M58)** — Detects Tailwind, Bootstrap, Bulma, UnoCSS, MUI, Chakra,
  shadcn/ui, daisyUI, and more. Provides web-specific coder guidance for design
  tokens, accessibility, responsive layouts, and tester patterns for headless
  browser testing.
- **UI/UX specialist reviewer (M59)** — A new specialist alongside security,
  performance, and API. Reviews accessibility, visual hierarchy, design system
  consistency, responsive behavior, and interaction patterns. Auto-enables when
  a UI platform is detected. Toggle with `SPECIALIST_UI_ENABLED`.
- **Mobile & game adapters (M60)** — Adapters for Flutter (`platforms/mobile_flutter/`),
  iOS SwiftUI/UIKit (`platforms/mobile_native_ios/`), Android Jetpack Compose/XML
  (`platforms/mobile_native_android/`), and browser game engines like Phaser,
  PixiJS, Three.js, Babylon.js (`platforms/game_web/`).

### Efficiency & Tester Hardening (M61–M65)

- **Repo map cross-stage cache (M61)** — The tree-sitter repo map is now generated
  once per run and sliced per stage instead of regenerated for every stage. The
  full map writes to `.claude/logs/${TIMESTAMP}/REPO_MAP_CACHE.md`; subsequent
  stages load from cache without re-invoking the Python tool. Saves ~5–15 seconds
  per stage on large projects.
- **Tester timing instrumentation (M62)** — The tester agent self-reports
  TEST_CMD timing in a structured TESTER_REPORT.md section, parsed by the pipeline.
  Build gate phase data (analyze, compile, constraints) is now surfaced in
  TIMING_REPORT.md so optimization is no longer guesswork.
- **Test baseline hygiene (M63)** — Fresh baseline captured per run (no more
  cross-run baseline pollution); the completion gate now actually runs `TEST_CMD`
  instead of trusting the coder's "COMPLETE" claim; the tester receives baseline
  context so it can distinguish pre-existing failures from new regressions; the
  `TEST_BASELINE_PASS_ON_STUCK` escape hatch is now disabled by default. Toggle
  test enforcement at completion with `COMPLETION_GATE_TEST_ENABLED`.
- **Tester fix — surgical mode (M64)** — When `TESTER_FIX_ENABLED=true` and the
  tester finds failures, instead of spawning a full recursive pipeline run
  (coder → reviewer → tester, 40+ minutes), an inline fix agent operates within
  the tester stage itself. Mirrors the coder's build-fix retry pattern.
- **Prompt tool awareness (M65)** — Audited 42 prompts and added Serena MCP +
  repo map guidance to the ones that do code discovery (tester, coder_rework,
  build_fix, all specialists). Stops agents from falling back to manual grep/find
  when LSP tools are available.

### Autonomous Runtime (M16)

- Quota management and usage-aware pacing
- Proactive pause before hitting API rate limits

## v2.0 — Adaptive Pipeline (March 2026)

22 milestones: autonomous operation (`--complete`, `--auto-advance`, `--human`),
transient error retry, turn-exhaustion continuation, milestone auto-split, context
budgeting, specialist reviews, autonomous debt sweeps, error taxonomy, metrics
dashboard, brownfield init/replan, clarification protocol, security hardening.

## v1.0 — Foundation (March 2026)

Core pipeline (Scout → Coder → Reviewer → Tester), dynamic turn limits, architecture
drift detection, build gates, `--plan` interactive planning, human notes, pipeline
state persistence, FIFO-isolated agent invocation, `--milestone` mode.
