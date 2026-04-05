# Tekhton Conductor

Autonomous milestone progression daemon for Tekhton. Runs as a Docker container, driving milestone completion overnight while you sleep.

## What It Does

- Reads the milestone manifest and walks the DAG in dependency order
- For each milestone: creates a git branch, runs `--milestone <id>`, runs `--fix-nonblockers` and `--fix-driftlog`, commits, creates a PR, and enables auto-merge
- Tracks API token usage to avoid hitting the 5-hour rolling window ceiling
- On failure, calls the Anthropic API (`claude-opus-4-6`) to analyze the error and decide: retry, fix, diagnose, or stop
- Stops after 3 consecutive failures of the same milestone
- Exposes an HTTP control plane (FastAPI on port 7411) for monitoring and commands

## Quick Start (Docker)

### 1. Set environment variables

Create a `.env` file (or export these):

```bash
TEKHTON_HOME=/path/to/tekhton          # where tekhton.sh lives
PROJECT_REPO=/path/to/target-project   # the repo tekhton operates on
ANTHROPIC_API_KEY=sk-ant-...           # for error analysis calls
CONDUCTOR_PORT=7411                    # optional, defaults to 7411
PUID=1000                              # optional, match your host UID
PGID=1000                              # optional, match your host GID
TZ=America/New_York                    # optional
```

### 2. Create and edit the config

```bash
cp conductor/conductor.cfg.example conductor.cfg
```

Edit `conductor.cfg` — the paths inside are container-internal and match the compose volume mounts:
- `/tekhton` = Tekhton source (read-only mount)
- `/repo` = target project (read-write mount)
- `/data` = persistent state and logs (named volume)
- `/config` = config file (read-only mount)

Set `api_token` to a random secret and `anthropic_api_key` to your Anthropic key.

### 3. Build and run

```bash
docker compose -f conductor/tekhton-conductor.yml build
docker compose -f conductor/tekhton-conductor.yml up -d
```

### 4. Verify

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" http://localhost:7411/status
```

## Prerequisites on the Host

The container bind-mounts these directories (read-only):

- **`~/.ssh/`** -- SSH keys for `git push`
- **`~/.config/gh/`** -- GitHub CLI auth (`gh auth login` must have been run on the host)
- **`~/.claude/`** -- Claude Code CLI auth (must have been authenticated on the host)

The host user's UID should match `PUID` so file permissions work correctly.

## Integrating with an Existing Compose Stack

If you already run Docker Compose with an include-based layout, copy the service definition from `tekhton-conductor.yml` into your own compose file (or use `include:`). Adjust the `build.context` and volume source paths to match your directory structure.

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
# Graceful stop -- finishes current operation, then halts
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
| `tekhton_path` | Tekhton repo (container path) | `/tekhton` |
| `manifest_path` | MANIFEST.cfg (container path) | `/repo/.claude/milestones/MANIFEST.cfg` |
| `repo_path` | Target project (container path) | `/repo` |
| `integration_branch` | PR base branch | `feature/Version3` |
| `api_port` | HTTP API port | `7411` |
| `api_token` | Bearer token for API auth | -- |
| `anthropic_api_key` | Anthropic key for error analysis | -- |
| `usage_window_hours` | Rolling usage window | `5` |
| `usage_safety_threshold` | Wait threshold (fraction) | `0.25` |
| `max_milestone_retries` | Max consecutive failures before stopping | `3` |
| `log_path` | Log file (container path) | `/data/logs/conductor.log` |
| `state_path` | State file (container path) | `/data/state/conductor.state.json` |

## Alternative: systemd

If you prefer running directly on the host instead of Docker, a `tekhton-conductor.service` unit file is included. Install Python deps with `pip install -r requirements.txt`, edit the paths in the service file, and install to `/etc/systemd/system/`.

## Files

| File | Purpose |
|------|---------|
| `conductor.py` | Main daemon: state machine, subprocess execution, error analysis |
| `api.py` | FastAPI control plane (4 endpoints + bearer auth) |
| `Dockerfile` | Container image: Python 3.12 + bash + git + gh + Claude CLI |
| `tekhton-conductor.yml` | Docker Compose service definition |
| `conductor.cfg.example` | Config template with container-internal paths |
| `requirements.txt` | Python dependencies |
| `tekhton-conductor.service` | systemd unit file (alternative to Docker) |
