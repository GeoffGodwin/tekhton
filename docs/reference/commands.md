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
| `--init --full` | Brownfield one-shot: chains `--init` and `--plan-from-index` so a single command produces a fully scaffolded `DESIGN.md` and `CLAUDE.md` from the project crawl. |
| `--reinit` | Re-initialize, preserving existing configuration values while adding new defaults. |
| `--plan` | Start the interactive planning phase. Produces `DESIGN.md` and `CLAUDE.md` with a milestone plan. |
| `--plan --answers <file>` | Import pre-filled YAML answers (skip interview). |
| `--plan-browser` | Open the browser-based planning interview form. |
| `--export-questions` | Export planning questions as a YAML template to stdout. |
| `--plan-from-index` | Synthesize docs from an existing `PROJECT_INDEX.md` (skips interview). |
| `--version`, `-v` | Print the Tekhton version and exit. |
| `--help`, `-h` | Show usage summary and exit. |
| `--help --all` | Show the full flag list with all options. |
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
| `--dry-run` | Preview mode: run scout + intake only, show what the pipeline would do without executing. |
| `--continue-preview` | Resume from a previous `--dry-run` (uses cached scout/intake results). |
| `--no-commit` | Skip the auto-commit prompt at the end of the pipeline. |
| `--skip-audit` | Skip the architect audit stage (even if drift thresholds are exceeded). |
| `--skip-security` | Bypass the security review stage entirely. |
| `--force-audit` | Force the architect audit to run (even if thresholds aren't met). |
| `--notes-filter TAG` | Filter human notes by tag: `BUG`, `FEAT`, or `POLISH`. |
| `--usage-threshold N` | Pause the pipeline if session API usage exceeds N%. |

## Safety

| Flag | Description |
|------|-------------|
| `--rollback` | Revert the last pipeline run (clean git operations). |
| `--rollback --check` | Preview what rollback would do without acting. |

## Inspection & Diagnostics

| Flag | Description |
|------|-------------|
| `--status` | Print the saved pipeline state (stage, task, resume point, rollback availability). |
| `--report`, `report` | Print a one-screen summary of the last pipeline run. |
| `--metrics` | Print the run metrics dashboard (timing, turns, success rates). |
| `--health` | Run a standalone project health assessment and print the report. |
| `--diagnose` | Analyze the last pipeline failure and suggest recovery steps. |
| `--audit-tests` | Audit all test files for integrity issues. |

## Notes

| Command | Description |
|---------|-------------|
| `note "text"` | Add a note to `HUMAN_NOTES.md` (default tag: FEAT). |
| `note "text" --tag TAG` | Add a note with a specific tag (BUG, FEAT, POLISH). |
| `note --list [--tag TAG]` | List unchecked notes, optionally filtered by tag. |
| `note --done <N\|text>` | Mark a note as completed by number or text match. |
| `note --clear` | Remove all completed notes. |
| `--triage [TAG]` | Triage all unchecked notes (size estimate) without running the pipeline. |
| `--add-milestone "desc"` | Create a new scoped milestone via the intake agent (no pipeline run). |

## Maintenance

| Flag | Description |
|------|-------------|
| `--fix-nonblockers`, `--fix-nb` | Address all non-blocking notes accumulated in `NON_BLOCKING_LOG.md`. |
| `--fix-drift` | Force an architect audit to resolve drift observations. |
| `--replan` | Delta-based update to `DESIGN.md` and `CLAUDE.md` based on current codebase state. |
| `--rescan` | Update `PROJECT_INDEX.md` incrementally (only changed files). |
| `--rescan --full` | Full re-crawl of the project for `PROJECT_INDEX.md`. |
| `--migrate` | Upgrade project config to current Tekhton version. |
| `--migrate --check` | Show what migrations would run without applying. |
| `--migrate --status` | Show config version vs running Tekhton version. |
| `--migrate --rollback` | Restore from pre-migration backup. |
| `--migrate-dag` | Convert inline milestones in `CLAUDE.md` to DAG format (individual files + `MANIFEST.cfg`). |
| `--update [--check]` | Check for and install Tekhton updates (`--check`: report only). |
| `--init-notes` | Create a blank `HUMAN_NOTES.md` template. |
| `--seed-contracts` | Seed inline system contracts into library files. |

## Indexer & LSP

| Flag | Description |
|------|-------------|
| `--setup-indexer` | Install Python virtualenv for the tree-sitter repo map indexer. |
| `--with-lsp` | Also install the Serena LSP server (use with `--setup-indexer`). |
| `--setup-completion` | Install shell completions for your shell. |
| `--uninstall` | Remove Tekhton installation. |

## Examples

```bash
# Simple task
tekhton "Fix the login page redirect bug"

# Milestone mode with auto-advance
tekhton --milestone --auto-advance

# Preview what a task would do
tekhton --dry-run "Refactor the auth module"

# Resume from the review stage
tekhton --start-at review "Add user profile page"

# Work on the next bug from human notes
tekhton --human BUG

# Run in complete mode (loop until done)
tekhton --complete "Implement the REST API"

# Add a note for the next run
tekhton note "Login page needs error handling" --tag BUG

# Check what happened in the last run
tekhton --report

# Diagnose a failure
tekhton --diagnose

# Revert the last run
tekhton --rollback

# Run health assessment
tekhton --health
```
