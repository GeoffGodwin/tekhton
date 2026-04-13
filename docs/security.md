# Security

> This page used to live in the main README. It was split out in
> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md)
> to keep the README focused on the happy path.

Tekhton includes defense-in-depth hardening:

- **Safe config parsing** — `pipeline.conf` values containing `$(`, backticks, `;`, `|`, `&` are rejected (no shell injection via config)
- **Per-session temp files** — all temp files use `mktemp -d` in a session directory, not predictable paths
- **Pipeline locking** — only one instance runs per project (PID-validated lock file)
- **Anti-prompt-injection** — file content in agent prompts is wrapped in explicit delimiters; all agent system prompts include anti-injection directives
- **Git safety** — warns if `.gitignore` is missing `.env` or key patterns before `git add`
- **Sensitive data redaction** — API keys, auth tokens, and credentials are stripped from error reports, log summaries, and state files
- **Agent permissions** — each agent gets only the tools it needs; destructive operations (`git push`, `rm -rf`, `curl`, `wget`) are always blocked
- **Config bounds** — numeric config values are clamped to hard upper limits to prevent resource exhaustion
