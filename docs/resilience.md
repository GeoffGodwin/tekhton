# Agent Resilience

> This page used to live in the main README. It was split out in
> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md)
> to keep the README focused on the happy path.

Tekhton uses FIFO-isolated agent invocation with multiple layers of fault tolerance:

- **Interrupt handling** — Ctrl+C works immediately, even if the agent is hung. Claude runs in a background subshell writing to a named pipe; the foreground read loop exits on signal.
- **Activity timeout** — If an agent produces no output or file changes for 10 minutes (`AGENT_ACTIVITY_TIMEOUT`), it's killed automatically. Catches hung API connections and stuck retry loops. File-change detection prevents false kills when agents work silently.
- **Total timeout** — Hard wall-clock limit of 2 hours (`AGENT_TIMEOUT`) as a backstop.
- **Transient error retry** — API errors (500, 429, 529), OOM kills, and network failures trigger automatic retry with exponential backoff (30s -> 60s -> 120s, up to 3 attempts). Rate-limit responses respect `retry-after` headers.
- **Turn-exhaustion continuation** — When a coder or tester hits its turn limit but made substantive progress (`Status: IN PROGRESS` + file changes), the pipeline automatically re-invokes with full prior-progress context and a fresh turn budget. Up to 3 continuations before escalating to milestone split or exit.
- **Null-run detection** — Agents that die during discovery (<=2 turns, non-zero exit) are flagged. Combined with file-change detection to distinguish real null runs from silent completions. API failures are never misclassified as null runs.
- **Error taxonomy** — Structured error classification (UPSTREAM, ENVIRONMENT, AGENT_SCOPE, PIPELINE) with transience detection, recovery suggestions, and sensitive data redaction. Errors are displayed in formatted boxes with actionable next steps.
- **Windows compatibility** — Detects Windows-native `claude.exe` running via WSL interop or Git Bash and uses `taskkill.exe` for cleanup (Windows processes ignore POSIX signals).
