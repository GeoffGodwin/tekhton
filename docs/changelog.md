# Changelog

## 3.18.0

- Documentation site with MkDocs Material theme
- Getting Started guide (installation, first project, first milestone)
- Complete configuration reference
- Command reference for all CLI flags
- Concept explainers (pipeline flow, milestone DAG, health scoring, context budget)
- Troubleshooting guide with --diagnose walkthrough
- GitHub Actions deployment to GitHub Pages
- `--docs` flag to open documentation in browser

## 3.17.0

- Pipeline diagnostics and recovery guidance (`--diagnose`)
- Failure classification with structured recovery suggestions
- Diagnostic rules for common failure modes

## 3.16.0

- Quota management and usage-aware pacing
- Proactive pause before hitting API rate limits
- Configurable usage thresholds and retry intervals

## 3.15.0

- Project health scoring (`--health`)
- Five-category assessment: tests, quality, dependencies, documentation, hygiene
- Belt rating system for quick visual feedback
- Health baseline tracking and trend comparison

## 3.14.0

- Watchtower dashboard enhancements
- Security summary view
- Milestone map visualization

## 3.13.0

- Watchtower dashboard (browser-based pipeline monitoring)
- Causal event log for run history tracking
- Real-time pipeline progress display

## 3.12.0

- Brownfield deep analysis during `--init`
- Workspace, service, CI/CD, and infrastructure detection
- Test framework detection
- Documentation quality assessment

## 3.11.0

- AI artifact detection during `--init`
- Archive, tidy, and ignore handling modes
- Artifact merge agent for combining AI configs

## 3.10.0

- Intake agent (PM pre-stage gate)
- Task clarity scoring and scope assessment
- Automatic task tweaking and splitting

## 3.9.0

- Security agent stage
- Vulnerability scanning with severity ratings
- Automatic remediation and unfixable issue escalation
- Security waivers

## 3.8.0

- Health scoring foundations

## 3.7.0

- Indexer task-file history tracking

## 3.6.0

- Serena LSP integration via MCP

## 3.5.0

- Repo map indexer with tree-sitter (Python)
- PageRank-based file relevance scoring
- Token-budgeted output

## 3.4.0

- Repo map orchestration from shell

## 3.3.0

- Indexer Python tooling foundations

## 3.2.0

- Milestone sliding window with character budget

## 3.1.0

- Milestone DAG infrastructure
- File-based milestones with MANIFEST.cfg
- Dependency tracking and frontier detection

## 2.x

- Context budget system
- Task-scoped context assembly
- Milestone state machine and auto-advance
- Clarification protocol
- Autonomous debt sweep stage
- Specialist reviewers
- Run metrics and adaptive calibration
- Error taxonomy and classification
- Milestone archival
- Milestone splitting
- Outer orchestration loop (`--complete`)
- Transient error retry with exponential backoff
- Turn exhaustion continuation
- Quota-aware pacing

## 1.x

- Core pipeline: scout, coder, reviewer, tester
- Build gate and completion gate
- Review-rework loop
- Human notes system
- Drift detection and architect audit
- Planning phase (`--plan`)
- Pipeline state persistence and resume
