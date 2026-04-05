# Tekhton Conductor

Autonomous milestone progression daemon for Tekhton. Runs as a Docker container, driving milestone completion overnight while you sleep.

## What It Does

- Reads the milestone manifest and walks the DAG in dependency order
- For each milestone: creates a git branch, runs `--milestone <id>`, runs `--fix-nonblockers` and `--fix-driftlog`, commits, creates a PR, and enables auto-merge
- Tracks API token usage to avoid hitting the 5-hour rolling window ceiling
- On failure, calls the Anthropic API (`claude-opus-4-6`) to analyze the error and decide: retry, fix, diagnose, or stop
- Stops after 3 consecutive failures of the same milestone
- Exposes an HTTP control plane (FastAPI on port 7411) for monitoring and commands

## Architecture

The conductor is fully self-contained:

- **Tekhton source** is baked into the Docker image at build time
- **Target project repo** is cloned from `repo_url` on startup into a tmpfs (ephemeral, fast, disposable after push)
- **Auth** uses `ANTHROPIC_API_KEY` env var for both the Claude CLI and the conductor's own API calls (no OAuth expiry issues)
- **SSH keys** and **gh CLI auth** are mounted read-only from the host for git push and PR creation
- **State** persists to a named Docker volume so the conductor survives restarts

Nothing lives on the host except SSH keys, gh auth, and the config file.

## Quick Start

### 1. Create config

```bash
cp conductor/conductor.cfg.example conductor.cfg
```

Edit `conductor.cfg`:
- Set `repo_url` to your target project's SSH clone URL
- Set `integration_branch` to your integration branch name
- Set `api_token` to a random secret

### 2. Set environment variables

Create a `.env` file or export:

```bash
ANTHROPIC_API_KEY=sk-ant-...    # required
CONDUCTOR_PORT=7411             # optional, defaults to 7411
PUID=1000                       # optional, match your host UID
PGID=1000                       # optional, match your host GID
TZ=UTC                          # optional
```

### 3. Build and run

From the tekhton repo root:

```bash
docker compose -f conductor/tekhton-conductor.yml build
docker compose -f conductor/tekhton-conductor.yml up -d
```

### 4. Verify

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" http://localhost:7411/status
```

## Host Prerequisites

The container bind-mounts these from the host (read-only):

- **`~/.ssh/`** -- SSH keys for `git push` (must have access to the target repo)
- **`~/.config/gh/`** -- GitHub CLI auth (`gh auth login` must have been run)

The `ANTHROPIC_API_KEY` environment variable handles all Claude authentication. No OAuth login or `~/.claude` mount needed.

## Integrating with an Existing Compose Stack

If you run Docker Compose with an include-based layout, copy the service definition from `tekhton-conductor.yml` into your stack. Key things to adjust:

- `build.context` must point to the tekhton repo root (so the full source gets baked in)
- `build.dockerfile` must point to `conductor/Dockerfile` relative to that context
- Volume source for `conductor.cfg` should match your appdata layout

## Arming a Night Run

```bash
# Start from next incomplete milestone
curl -X POST http://localhost:7411/start-night-run \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'

# Start from a specific milestone
curl -X POST http://localhost:7411/start-night-run \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"starting_milestone": "m57"}'
```

## Monitoring

```bash
# Full state as JSON
curl -s -H "Authorization: Bearer YOUR_TOKEN" http://localhost:7411/status | python3 -m json.tool

# Last 100 log lines
curl -s -H "Authorization: Bearer YOUR_TOKEN" "http://localhost:7411/log?lines=100"

# Docker container logs
docker logs tekhton-conductor --tail 50
```

## Morning Report

Check `/status` when you wake up. Key fields:

- `state`: `STOPPED_SUCCESS` = all milestones done. `STOPPED_ERROR` = needs attention.
- `completed_milestones`: list of milestone IDs finished during the run
- `error_history`: timestamped list of any failures
- `accumulated_tokens`: total tokens consumed
- `last_error_output`: output from the last failed operation

## Stopping

```bash
curl -X POST http://localhost:7411/stop -H "Authorization: Bearer YOUR_TOKEN"
```

## State Machine

```
IDLE -> ARMED -> RUNNING_MILESTONE -> RUNNING_FIXES -> COMMITTING -> IDLE (loop)
                       |                                               ^
                ANALYZING_ERROR --> RETRY / FIX / DIAGNOSE ------------+
                       |
                STOPPED_ERROR
                                          WAITING_FOR_USAGE (retry every 10min)
                                          STOPPED_SUCCESS (all done)
```

## Config Reference

| Key | Description | Default |
|-----|-------------|---------|
| `tekhton_path` | Tekhton source (baked into image) | `/tekhton` |
| `repo_url` | SSH clone URL for target project | -- |
| `repo_path` | Clone destination (tmpfs in container) | `/repo` |
| `manifest_path` | MANIFEST.cfg path (auto-resolved if blank) | `<repo_path>/.claude/milestones/MANIFEST.cfg` |
| `integration_branch` | PR base branch | `feature/Version3` |
| `api_port` | HTTP API port | `7411` |
| `api_token` | Bearer token for API auth | -- |
| `anthropic_api_key` | Anthropic key (env var preferred) | -- |
| `usage_window_hours` | Rolling usage window | `5` |
| `usage_safety_threshold` | Wait threshold (fraction) | `0.25` |
| `max_milestone_retries` | Max consecutive failures | `3` |
| `log_path` | Log file (persisted volume) | `/data/logs/conductor.log` |
| `state_path` | State file (persisted volume) | `/data/state/conductor.state.json` |

## Alternative: systemd

A `tekhton-conductor.service` unit file is included for running directly on a host without Docker. Install Python deps with `pip install -r requirements.txt` and adjust paths in the service file.

## Files

| File | Purpose |
|------|---------|
| `conductor.py` | Main daemon: state machine, repo clone, subprocess execution, error analysis |
| `api.py` | FastAPI control plane (4 endpoints + bearer auth) |
| `Dockerfile` | Container image: Python 3.12 + bash + git + gh + Claude CLI + tekhton source |
| `tekhton-conductor.yml` | Docker Compose service definition |
| `conductor.cfg.example` | Config template |
| `requirements.txt` | Python dependencies |
| `tekhton-conductor.service` | systemd unit file (alternative to Docker) |
