<div align="center">
  <img src="assets/tekhton-logo.svg" alt="Tekhton" width="120" />

  <h1>Tekhton</h1>

  <p><strong>One intent. Many hands.</strong></p>

  <p><em>v3.119.0 — Context-Aware Pipeline</em></p>
</div>

## What is Tekhton?

Tekhton is a standalone, project-agnostic multi-agent development pipeline built
on the [Claude CLI](https://docs.anthropic.com/en/docs/build-with-claude/claude-code/cli-usage).
Give it a task description and it orchestrates an **Intake -> Scout -> Coder ->
Security -> Reviewer -> Tester** cycle with automatic rework routing, build gates,
architecture drift prevention, and resume support.

It works on any project — web apps, CLI tools, APIs, mobile, games. You describe
what you want built; Tekhton coordinates the agents, manages context, and iterates
until the work passes review and tests.

Hand it `--complete` and walk away. It retries transient errors, continues on turn
exhaustion, splits oversized milestones, and loops until acceptance criteria pass.

## Install

### One-liner (Linux, macOS, WSL)

```bash
curl -sSL https://raw.githubusercontent.com/geoffgodwin/tekhton/main/install.sh | bash
```

This installs Tekhton to `~/.tekhton` and adds `tekhton` to your PATH.

### macOS (Homebrew)

```bash
brew install geoffgodwin/tekhton/tekhton
```

### From source

```bash
git clone https://github.com/geoffgodwin/tekhton.git
cd tekhton && ./install.sh
```

### Platform notes

- **macOS:** `brew install geoffgodwin/tekhton/tekhton` (preferred) or the curl one-liner. macOS ships with bash 3.2 — both methods install bash 4.3+ automatically. See [Installation -> macOS](docs/getting-started/installation.md#macos) for details.
- **Linux / WSL:** The curl one-liner is the recommended path.
- **From source:** `git clone` + `./install.sh` for contributors or custom installs.

## 5-Minute Quickstart

### Greenfield (new project)

```bash
tekhton --plan                # Interview -> DESIGN.md + CLAUDE.md with milestones
tekhton --init                # Generate pipeline config + agent roles
tekhton "Implement Milestone 1: Project scaffold"
```

### Brownfield (existing project)

```bash
cd /path/to/existing/project
tekhton --init                # Detects stack, crawls codebase, generates config
tekhton "Fix the login timeout bug"
```

### Day-to-day

```bash
tekhton "Implement user authentication"        # Single task
tekhton --milestone "Implement Milestone 3"    # Full milestone with acceptance
tekhton --human --complete                     # Process all human notes
tekhton --replan                               # Update docs after drift
```

After `--init`, your project will contain:

```
your-project/
+-- .claude/
|   +-- pipeline.conf          # Pipeline configuration
|   +-- agents/                # Agent role definitions (coder, reviewer, tester, etc.)
|   +-- milestones/            # Milestone DAG: per-milestone files + MANIFEST.cfg
|   +-- dashboard/             # Watchtower browser dashboard (open index.html)
|   +-- logs/                  # Run logs, metrics, event logs (gitignored)
+-- CLAUDE.md                  # Project rules (read by all agents)
+-- DESIGN.md                  # Design doc (from --plan)
+-- HUMAN_NOTES.md             # Bug/feat/polish queue
```

## How to Use Tekhton Effectively

**1. Start with a plan.** `tekhton --plan` runs an interview that
produces a `CLAUDE.md` plan and a set of milestone files. Edit them
if you want — Tekhton will work from your edits.

**2. Run a milestone.** `tekhton` (no args) picks the first pending
milestone and runs the full pipeline: scout -> coder -> security ->
review -> test. Most runs finish in a single invocation. If a rework
cycle needs human input, Tekhton pauses with a clear prompt.

**3. Check the notes.** `HUMAN_NOTES.md` is where the pipeline
collects things it thinks need your eyes. Tick items off when done;
the next run will pick up the unchecked ones.

**4. Watch it drift.** Over many runs, architecture drifts.
`DRIFT_LOG.md` and `ARCHITECTURE_LOG.md` record what changed and why.
Run `tekhton --replan` when the plan stops matching reality.

**5. Ship.** `CHANGELOG.md` and project version files auto-update. For Tekhton
self-hosting, `VERSION` is the CLI source of truth.
Tag when ready.

## What's in `docs/`

Detailed reference material lives in `docs/`. The README covers the happy
path; these pages cover everything else.

<a id="how-the-pipeline-works"></a>
<a id="autonomous-modes"></a>
<a id="human-notes"></a>

| Topic | Page |
|-------|------|
| Pipeline flow, autonomous modes, human notes | [docs/USAGE.md](./docs/USAGE.md) |
| Milestones | [docs/MILESTONES.md](./docs/MILESTONES.md) |
| CLI flags and commands | [docs/cli-reference.md](./docs/cli-reference.md) |
| `pipeline.conf` reference | [docs/configuration.md](./docs/configuration.md) |
| Specialist reviews (security, UI/UX, perf, API) | [docs/specialists.md](./docs/specialists.md) |
| Watchtower browser dashboard | [docs/watchtower.md](./docs/watchtower.md) |
| Run metrics and adaptive calibration | [docs/metrics.md](./docs/metrics.md) |
| Context budgeting and clarification protocol | [docs/context.md](./docs/context.md) |
| Project crawling and tech stack detection | [docs/crawling.md](./docs/crawling.md) |
| Architecture drift prevention | [docs/drift.md](./docs/drift.md) |
| Agent resilience and fault tolerance | [docs/resilience.md](./docs/resilience.md) |
| Autonomous debt sweeps | [docs/debt-sweeps.md](./docs/debt-sweeps.md) |
| Planning phase (`--plan`, `--replan`) | [docs/planning.md](./docs/planning.md) |
| Security hardening | [docs/security.md](./docs/security.md) |

<a id="watchtower-dashboard"></a>
<a id="specialist-reviews"></a>
<a id="architecture-drift-prevention"></a>
<a id="agent-resilience"></a>
<a id="context-management"></a>
<a id="clarification-protocol"></a>
<a id="project-crawling--tech-stack-detection"></a>
<a id="cli-reference"></a>
<a id="configuration"></a>
<a id="metrics-dashboard"></a>
<a id="autonomous-debt-sweeps-opt-in"></a>
<a id="planning-phase---plan"></a>
<a id="security"></a>

Also see the full [documentation site](docs/index.md) for getting-started guides,
concept deep-dives, and troubleshooting.

## Requirements

- **Bash 4.3+** — Linux and WSL2 ship with a compatible version. **macOS requires setup** — macOS ships with bash 3.2 which will not work. Run `brew install bash` and add the Homebrew bash to your PATH *before* running Tekhton. See [installation notes](docs/getting-started/installation.md#macos).
- **Claude CLI** — authenticated and on `PATH` (`claude --version` should work)
- **Git** — used for commit integration
- **Python 3** — used for JSON parsing of agent output

### Optional Dependencies

- **Python 3.8+** with **tree-sitter** — for intelligent repo map indexing (`--setup-indexer` installs automatically)
- **Serena LSP** — for live symbol lookup via MCP (`--setup-indexer --with-lsp`)
- **shellcheck** — for development on Tekhton itself

## Contributing

Bug reports and pull requests welcome. All `.sh` files must pass `shellcheck` with
zero warnings. Run self-tests with `bash tests/run_tests.sh`.

If you're working on Tekhton itself, you'll need **shellcheck** installed:

```bash
# Debian/Ubuntu/WSL2
sudo apt-get install -y shellcheck

# macOS
brew install shellcheck
```

## Changelog

See [CHANGELOG.md](./CHANGELOG.md).

## License

MIT
