# FAQ

## General

### How much does it cost to run?

Tekhton uses the Claude API through the Claude CLI. Costs depend on:

- **Model choice** — Opus is more expensive than Sonnet
- **Turn limits** — Higher limits = more tokens = higher cost
- **Task complexity** — A simple bug fix uses fewer tokens than a milestone

A typical single-task run (50 coder turns, 15 reviewer turns, 30 tester turns)
with Sonnet uses roughly 100k-300k tokens. A milestone run with higher limits
can use 500k-1M+ tokens.

Check your usage with `claude usage` (if supported by your CLI version) or in
your Anthropic dashboard.

### Can I use it with GPT, Gemini, or other AI models?

No. Tekhton is built specifically on the Claude CLI and uses Claude-specific
features (structured output parsing, tool use patterns). It is not compatible
with other AI providers.

### Can multiple people use it on the same repo?

Not simultaneously. Tekhton writes state files and reports to the project
directory. Two concurrent runs would conflict. Sequential use by different
team members works fine — each run reads the current state and produces clean
output.

Multi-user support is planned for a future version.

### How do I undo what Tekhton did?

Tekhton creates git commits for its changes. To undo:

```bash
# Undo the last commit (keeps changes in working directory)
git reset HEAD~1

# Or fully revert
git revert HEAD
```

If you used `--no-commit`, changes are uncommitted and can be discarded with
`git checkout .` (after reviewing what would be lost).

### Is it safe to run on production code?

Yes, with caveats:

- Tekhton writes code through the Claude CLI, which operates in a sandboxed
  environment
- Changes are committed to git, so they're fully reversible
- The security agent catches common vulnerabilities before they're committed
- The build gate ensures code compiles and passes linting

That said, always review the diff before pushing to production. Tekhton is a
tool, not a replacement for human judgment on critical systems.

## Configuration

### What's the minimum configuration needed?

A `pipeline.conf` with just `PROJECT_NAME`:

```bash
PROJECT_NAME="my-project"
```

Everything else has sensible defaults. `TEST_CMD` defaults to `true` (no-op),
and all optional features are off by default.

### How do I make the pipeline faster?

- Use Sonnet instead of Opus for agents where speed matters more than reasoning
- Lower turn limits if tasks are consistently simple
- Disable optional stages you don't need:
  ```bash
  SECURITY_AGENT_ENABLED=false    # Skip security review
  INTAKE_AGENT_ENABLED=false      # Skip PM evaluation
  ```

### How do I make the pipeline produce better code?

- Use Opus for the coder: `CLAUDE_CODER_MODEL=opus`
- Write detailed agent role definitions in `.claude/agents/`
- Provide a thorough `CLAUDE.md` with architecture guidelines
- Use `--plan` to create a design doc before coding
- Enable the repo map indexer for better code awareness:
  ```bash
  tekhton --setup-indexer
  REPO_MAP_ENABLED=true
  ```

## Troubleshooting

### The pipeline keeps running out of turns

Increase turn limits:

```bash
CODER_MAX_TURNS=80
TESTER_MAX_TURNS=50
```

Or use milestone mode (`--milestone`) which automatically doubles turn limits.

### The reviewer keeps rejecting code

Your reviewer role might be too strict. Check `.claude/agents/reviewer.md` and
adjust the criteria. Alternatively, increase `MAX_REVIEW_CYCLES` to give more
rework attempts.

### How do I skip a stage?

- Skip security: `--skip-security`
- Skip architect audit: `--skip-audit`
- Start from a specific stage: `--start-at review "task"`

### The dashboard doesn't load

- Try a different browser (Chrome/Firefox recommended)
- Safari may block JavaScript on `file://` URLs
- Start a local server: `python3 -m http.server 8080 -d .claude/dashboard`
- Check that `.claude/dashboard/data/` contains `.js` files

## What's Next?

- [Using --diagnose](diagnose.md) — Automated failure analysis
- [Common Errors](common-errors.md) — Error message reference
- [Configuration Reference](../reference/configuration.md) — All config options
