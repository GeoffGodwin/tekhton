# Command Reference

Complete reference for all Tekhton CLI flags and options.

## Basic Usage

```bash
tekhton "Your task description"
```

## Getting Started

| Flag | Description |
|------|-------------|
| `--init` | Initialize Tekhton in the current project directory. Detects tech stack, creates `pipeline.conf`, agent roles, and dashboard. |
| `--reinit` | Re-initialize, preserving existing configuration values while adding new defaults. |
| `--plan` | Start the interactive planning phase. Produces `DESIGN.md` and `CLAUDE.md` with a milestone plan. |
| `--plan-from-index` | Synthesize docs from an existing `PROJECT_INDEX.md` (skips interview). |
| `--version`, `-v` | Print the Tekhton version and exit. |
| `--help`, `-h` | Show usage summary and exit. |
| `--docs` | Open the documentation site in your default browser. |

## Running the Pipeline

| Flag | Description |
|------|-------------|
| `--milestone` | Run in milestone mode: higher turn limits, more review cycles, upgraded tester model. Picks the next pending milestone automatically. |
| `--auto-advance` | After completing a milestone, automatically advance to the next one. Use with `--milestone`. |
| `--complete` | Loop mode: keep running the pipeline until the task is done or limits are reached. |
| `--start-at STAGE` | Resume from a specific stage. Valid stages: `intake`, `coder`, `security`, `review`, `tester`, `test`. |
| `--human [TAG]` | Pick the next unchecked note from `HUMAN_NOTES.md`. Optional tag filter: `BUG`, `FEAT`, `POLISH`. |
| `--with-notes` | Force human notes injection into the coder prompt (even if threshold isn't met). |
| `--no-commit` | Skip the auto-commit prompt at the end of the pipeline. |
| `--skip-audit` | Skip the architect audit stage (even if drift thresholds are exceeded). |
| `--skip-security` | Bypass the security review stage entirely. |
| `--force-audit` | Force the architect audit to run (even if thresholds aren't met). |
| `--notes-filter TAG` | Filter human notes by tag: `BUG`, `FEAT`, or `POLISH`. |
| `--usage-threshold N` | Pause the pipeline if session API usage exceeds N%. |

## Inspection & Diagnostics

| Flag | Description |
|------|-------------|
| `--status` | Print the saved pipeline state (stage, task, resume point). |
| `--report`, `report` | Print a one-screen summary of the last pipeline run. |
| `--metrics` | Print the run metrics dashboard (timing, turns, success rates). |
| `--health` | Run a standalone project health assessment and print the report. |
| `--diagnose` | Analyze the last pipeline failure and suggest recovery steps. |

## Maintenance

| Flag | Description |
|------|-------------|
| `--fix-nonblockers`, `--fix-nb` | Address all non-blocking notes accumulated in `NON_BLOCKING_LOG.md`. |
| `--fix-drift` | Force an architect audit to resolve drift observations. |
| `--replan` | Delta-based update to `DESIGN.md` and `CLAUDE.md` based on current codebase state. |
| `--rescan` | Update `PROJECT_INDEX.md` incrementally (only changed files). |
| `--rescan --full` | Full re-crawl of the project for `PROJECT_INDEX.md`. |
| `--migrate-dag` | Convert inline milestones in `CLAUDE.md` to DAG format (individual files + `MANIFEST.cfg`). |
| `--add-milestone "desc"` | Create a new scoped milestone via the intake agent. |
| `--init-notes` | Create a blank `HUMAN_NOTES.md` template. |
| `--seed-contracts` | Seed inline system contracts into library files. |

## Indexer & LSP

| Flag | Description |
|------|-------------|
| `--setup-indexer` | Install Python virtualenv for the tree-sitter repo map indexer. |
| `--with-lsp` | Also install the Serena LSP server (use with `--setup-indexer`). |

## Examples

```bash
# Simple task
tekhton "Fix the login page redirect bug"

# Milestone mode with auto-advance
tekhton --milestone --auto-advance

# Resume from the review stage
tekhton --start-at review "Add user profile page"

# Work on the next bug from human notes
tekhton --human BUG

# Run in complete mode (loop until done)
tekhton --complete "Implement the REST API"

# Check what happened in the last run
tekhton --report

# Diagnose a failure
tekhton --diagnose
```
