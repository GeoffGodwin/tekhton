# CLI Reference

> This page used to live in the main README. It was split out in
> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md)
> to keep the README focused on the happy path.

| Flag | Purpose |
|------|---------|
| `--init` | Smart init — detect stack, generate config, agent roles, and dashboard |
| `--init --full` | Run init + synthesis (DESIGN.md + CLAUDE.md) in one command |
| `--reinit` | Re-initialize, preserving existing config while adding new defaults |
| `--plan` | Interactive planning — generates DESIGN.md and CLAUDE.md |
| `--plan --answers <f>` | Import pre-filled YAML answers, skip interview |
| `--plan-browser` | Browser-based planning interview form |
| `--export-questions` | Export planning questions as YAML template to stdout |
| `--plan-from-index` | Synthesize DESIGN.md + CLAUDE.md from PROJECT_INDEX.md |
| `--replan` | Delta-based update of DESIGN.md and CLAUDE.md from current codebase |
| `--complete` | Autonomous loop — retry pipeline until task passes or bounds exhausted |
| `--milestone` | Milestone mode — higher turns, extra review, acceptance checking |
| `--auto-advance [N]` | Chain milestones autonomously (implies `--milestone`); optional `N` overrides `AUTO_ADVANCE_LIMIT` |
| `--add-milestone "desc"` | Create a scoped milestone via the intake agent (no run) |
| `--human [TAG]` | Pick next note from HUMAN_NOTES.md as task (optional: BUG, FEAT, POLISH) |
| `--with-notes` | *(deprecated)* Force human notes injection regardless of task text |
| `--notes-filter TAG` | Inject only notes matching TAG (BUG, FEAT, POLISH) |
| `--triage [TAG]` | Triage all unchecked notes (size estimate) without running |
| `--dry-run` | Preview mode — run scout + intake only, show what would happen |
| `--continue-preview` | Resume from a previous `--dry-run` (uses cached results) |
| `--start-at STAGE` | Resume from: `intake`, `coder`, `security`, `review`, `tester`, `test` |
| `--skip-security` | Bypass security review stage for a single run |
| `--skip-docs` | Bypass docs agent stage for a single run |
| `--skip-audit` | Skip architect audit even if thresholds exceeded |
| `--force-audit` | Run architect audit regardless of thresholds |
| `--no-commit` | Skip auto-commit (prompt instead) |
| `--usage-threshold N` | Pause if session usage exceeds N% |
| `--rollback` | Revert the last pipeline run (clean git operations; `--check` to preview) |
| `--status` | Print saved pipeline state (includes rollback availability) |
| `--progress` | Show milestone progress at a glance (`--all` to include done, `--deps` for dependency edges) |
| `--metrics` | Print run metrics dashboard and exit |
| `--diagnose` | Analyze last failure and suggest recovery steps |
| `--report` | Print summary of the last pipeline run |
| `--health` | Run standalone project health assessment |
| `--audit-tests` | Audit ALL test files for integrity issues |
| `--fix nb` | Address all open non-blocking notes in loop mode |
| `--fix drift` | Force architect audit to resolve drift observations |
| `--rescan` | Update PROJECT_INDEX.md incrementally (add `--full` for full re-crawl) |
| `--migrate` | Upgrade project config to current Tekhton version (`--check`, `--status`, `--rollback`, `--dag`) |
| `--migrate --dag` | Convert inline milestones to DAG file format |
| `--setup-indexer` | Install Python virtualenv for tree-sitter indexer (`--with-lsp` for Serena) |
| `--setup-completion` | Install shell completions for your shell |
| `--update` | Check for and install updates (`--check` to report only) |
| `--uninstall` | Remove Tekhton installation |
| `--docs` | Open documentation site in browser |
| `--version`, `-v` | Print version and exit |
| `--help` | Show usage information (`--help --all` for full flag list) |
| `note "text"` | Add a note to HUMAN_NOTES.md (with `--tag TAG`, `--list`, `--done`, `--clear`) |

Running `tekhton` with no arguments checks for saved pipeline state and offers to resume.
