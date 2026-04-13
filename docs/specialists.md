# Specialist Reviews

> This page used to live in the main README. It was split out in
> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md)
> to keep the README focused on the happy path.

After the main reviewer approves, focused specialist agents can run additional review passes.

**Built-in / auto-enabled:**

- **Security** — runs as a dedicated pipeline stage (not just a specialist). OWASP-aware vulnerability scanning with severity scoring and auto-remediation. Toggle with `SECURITY_AGENT_ENABLED`.
- **UI/UX** — auto-enabled when `UI_PROJECT_DETECTED=true`. 8-category checklist covering component structure, design system consistency, WCAG 2.1 AA accessibility, responsive behavior, state presentation, interaction patterns, loading/empty/error states, and keyboard/focus management. Pulls platform-specific patterns from the active platform adapter (web / Flutter / iOS / Android / game engines). Override with `SPECIALIST_UI_ENABLED` and `UI_PLATFORM`.

**Opt-in:**

- **Docs agent** — dedicated post-coder stage that reads the diff and updates README/docs/ using a Haiku-tier model. Runs between build gate and security. Enable with `DOCS_AGENT_ENABLED=true`.
- **Performance** — N+1 queries, unbounded loops, memory leaks, expensive operations
- **API contracts** — schema consistency, error format compliance, backward compatibility

`[BLOCKER]` findings re-enter the rework loop. `[NOTE]` findings go to `NON_BLOCKING_LOG.md`.

Enable per specialist in `pipeline.conf`:
```bash
SPECIALIST_PERFORMANCE_ENABLED=true
SPECIALIST_API_ENABLED=true
# UI specialist is auto-on for UI projects; force off with:
# SPECIALIST_UI_ENABLED=false
```

Custom specialists are supported via `SPECIALIST_CUSTOM_*` config keys with your own prompt templates. User platform adapters can be dropped into `.claude/platforms/<name>/` to extend or override the built-in UI knowledge.
