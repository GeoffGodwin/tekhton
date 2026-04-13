# Planning Phase

> This page used to live in the main README. It was split out in
> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md)
> to keep the README focused on the happy path.

Don't have a CLAUDE.md or DESIGN.md yet? The planning phase takes you from "I want
to build X" to production-ready documents that the execution pipeline can consume.

```bash
tekhton --plan

# 1. Pick a project type (web-app, cli-tool, api-service, web-game, mobile-app, library, custom)
# 2. Three-phase interview fills in DESIGN.md section by section
# 3. Completeness check flags shallow sections for follow-up
# 4. Claude generates CLAUDE.md with milestones, rules, and architecture
# 5. Review the milestone plan, then approve to write files

# Then initialize and build
tekhton --init
tekhton --milestone "Implement Milestone 1: Project scaffold"
```

**Interview phases:**
1. **Concept Capture** — high-level overview, tech stack, developer philosophy
2. **System Deep-Dive** — each feature/system section, with Phase 1 context visible
3. **Architecture & Constraints** — config architecture, naming conventions, open questions

If interrupted, re-running `tekhton --plan` offers to resume where you left off.

**DESIGN.md** — Professional-grade design document (500-1600+ lines):
developer philosophy, deep system sections with sub-sections and tables,
config architecture, open design questions.

**CLAUDE.md** — Authoritative development rulebook with 12 sections (500-1500 lines):
project identity, architecture philosophy, repository layout, key design decisions,
non-negotiable rules, implementation milestones (each with scope, file paths,
tests, watch-fors, and seeds-forward), code conventions, and more.

Each milestone is a standalone task: `tekhton --milestone "Implement Milestone 1: Project scaffold"`

## Brownfield Replanning (`--replan`)

Already have a codebase? `--replan` updates DESIGN.md and CLAUDE.md based on
accumulated drift, completed milestones, and codebase evolution. It's delta-based —
human edits are preserved, and you review all changes before they're applied.

```bash
tekhton --replan
```
