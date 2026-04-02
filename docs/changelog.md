# Changelog

## v3.0 — Context-Aware Pipeline (April 2026)

51 milestones delivered across the V3 initiative. Changes grouped by theme:

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

### Watchtower Dashboard (M13–M14, M34–M38)

- Browser-based pipeline monitoring with Live Run, Milestone Map, Reports, and Trends tabs
- Causal event log (JSONL) for structured debugging and cross-run learning
- Data fidelity fixes and smart refresh with context-aware layout
- Interactive controls and parallel teams readiness (V4-ready data model)
- Live Run and Milestone Map UX polish
- Security summary view and health score display

### Brownfield Intelligence (M11–M12, M15, M22)

- AI artifact detection with archive, tidy, and ignore handling modes
- Deep analysis: workspace, service, CI/CD, infrastructure, test framework detection
- Documentation quality assessment
- Project health scoring with five-category assessment and belt ratings
- Init UX overhaul with improved detection and onboarding flow

### Developer Experience (M17–M19, M21, M23–M27, M31–M32)

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
