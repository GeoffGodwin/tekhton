#!/usr/bin/env python3
"""
tekhton-conductor — Autonomous milestone progression daemon.

Drives Tekhton milestone progression overnight via a state machine,
manages git branching/merging, tracks API token usage, and exposes
an HTTP control plane for external monitoring and commands.
"""

import configparser
import enum
import json
import logging
import os
import re
import signal
import subprocess
import sys
import threading
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

@dataclass
class ConductorConfig:
    tekhton_path: str = "/tekhton"
    manifest_path: str = ""
    repo_url: str = ""
    repo_path: str = "/repo"
    integration_branch: str = "feature/Version3"
    api_port: int = 7411
    api_token: str = ""
    usage_window_hours: float = 5.0
    usage_safety_threshold: float = 0.25
    max_milestone_retries: int = 3
    log_path: str = "/data/logs/conductor.log"
    state_path: str = "/data/state/conductor.state.json"

    @classmethod
    def from_file(cls, path: str) -> "ConductorConfig":
        cfg = cls()
        cp = configparser.ConfigParser()
        # Manifest-style key=value without sections — add a dummy section
        with open(path, "r") as f:
            content = "[conductor]\n" + f.read()
        cp.read_string(content)
        section = cp["conductor"]
        for key in (
            "tekhton_path", "manifest_path", "repo_url", "repo_path",
            "integration_branch", "api_token",
            "log_path", "state_path",
        ):
            if key in section:
                setattr(cfg, key, section[key])
        for key in ("api_port", "max_milestone_retries"):
            if key in section:
                setattr(cfg, key, int(section[key]))
        for key in ("usage_window_hours", "usage_safety_threshold"):
            if key in section:
                setattr(cfg, key, float(section[key]))
        return cfg


# ---------------------------------------------------------------------------
# Manifest parser
# ---------------------------------------------------------------------------

@dataclass
class Milestone:
    id: str
    title: str
    status: str
    depends_on: list
    file: str
    parallel_group: str

    @property
    def slug(self) -> str:
        return self.file.replace(".md", "").lstrip(self.id + "-") if self.file else self.id


def parse_manifest(path: str) -> list:
    """Parse MANIFEST.cfg into a list of Milestone objects."""
    milestones = []
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("|")
            if len(parts) < 5:
                continue
            deps = [d.strip() for d in parts[3].split(",") if d.strip()] if parts[3].strip() else []
            milestones.append(Milestone(
                id=parts[0].strip(),
                title=parts[1].strip(),
                status=parts[2].strip(),
                depends_on=deps,
                file=parts[4].strip(),
                parallel_group=parts[5].strip() if len(parts) > 5 else "",
            ))
    return milestones


def find_next_milestone(milestones: list) -> Optional[Milestone]:
    """Return the first incomplete milestone whose dependencies are all done."""
    done_ids = {m.id for m in milestones if m.status == "done"}
    for m in milestones:
        if m.status != "done":
            if all(dep in done_ids for dep in m.depends_on):
                return m
    return None


# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------

class State(str, enum.Enum):
    IDLE = "IDLE"
    ARMED = "ARMED"
    RUNNING_MILESTONE = "RUNNING_MILESTONE"
    RUNNING_FIXES = "RUNNING_FIXES"
    COMMITTING = "COMMITTING"
    WAITING_FOR_USAGE = "WAITING_FOR_USAGE"
    ANALYZING_ERROR = "ANALYZING_ERROR"
    STOPPED_SUCCESS = "STOPPED_SUCCESS"
    STOPPED_ERROR = "STOPPED_ERROR"


@dataclass
class ConductorState:
    state: str = State.IDLE.value
    active_milestone_id: Optional[str] = None
    active_milestone_title: Optional[str] = None
    starting_milestone: Optional[str] = None
    last_exit_code: Optional[int] = None
    last_run_timestamp: Optional[str] = None
    accumulated_tokens: int = 0
    token_window_start: Optional[str] = None
    error_history: list = field(default_factory=list)
    consecutive_failures: int = 0
    night_run_active: bool = False
    stop_requested: bool = False
    completed_milestones: list = field(default_factory=list)
    last_error_output: Optional[str] = None

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict) -> "ConductorState":
        s = cls()
        for key, val in d.items():
            if hasattr(s, key):
                setattr(s, key, val)
        return s


# ---------------------------------------------------------------------------
# Conductor — the main daemon class
# ---------------------------------------------------------------------------

class Conductor:
    """Explicit state-machine conductor for Tekhton milestone progression."""

    SUBPROCESS_TIMEOUT = 7200  # 2 hours max per subprocess call

    def __init__(self, config: ConductorConfig):
        self.config = config
        self.state = ConductorState()
        self.logger = logging.getLogger("conductor")
        self._shutdown_event = threading.Event()
        self._load_state()

    # -- State persistence ---------------------------------------------------

    def _save_state(self):
        path = Path(self.config.state_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = str(path) + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.state.to_dict(), f, indent=2)
        os.replace(tmp, str(path))

    def _load_state(self):
        path = Path(self.config.state_path)
        if path.exists():
            try:
                with open(path, "r") as f:
                    self.state = ConductorState.from_dict(json.load(f))
                self.logger.info("Loaded persisted state: %s", self.state.state)
            except (json.JSONDecodeError, KeyError) as exc:
                self.logger.warning("Corrupt state file, starting fresh: %s", exc)
                self.state = ConductorState()

    # -- Repo bootstrap -------------------------------------------------------

    def _ensure_repo(self):
        """Clone the target repo if absent, or fetch latest if present."""
        repo = Path(self.config.repo_path)
        git_dir = repo / ".git"

        if git_dir.is_dir():
            # Repo exists — fetch and reset to integration branch
            self.logger.info("Repo exists at %s, refreshing", repo)
            self._run_subprocess(
                ["git", "fetch", "origin"],
                cwd=str(repo), timeout=120,
            )
            self._run_subprocess(
                ["git", "checkout", self.config.integration_branch],
                cwd=str(repo), timeout=30,
            )
            self._run_subprocess(
                ["git", "reset", "--hard", f"origin/{self.config.integration_branch}"],
                cwd=str(repo), timeout=30,
            )
        else:
            # Fresh clone
            if not self.config.repo_url:
                raise RuntimeError("repo_url not set in config and no repo at repo_path")
            self.logger.info("Cloning %s into %s", self.config.repo_url, repo)
            repo.mkdir(parents=True, exist_ok=True)
            self._run_subprocess(
                ["git", "clone", "--branch", self.config.integration_branch,
                 self.config.repo_url, str(repo)],
                cwd="/tmp", timeout=300,
            )

        # Resolve manifest_path relative to repo if not absolute
        if not self.config.manifest_path:
            self.config.manifest_path = str(repo / ".claude" / "milestones" / "MANIFEST.cfg")

        self.logger.info("Repo ready at %s, manifest at %s",
                         repo, self.config.manifest_path)

    # -- State transitions ---------------------------------------------------

    def _transition(self, new_state: State, **extra_fields):
        old = self.state.state
        self.state.state = new_state.value
        for k, v in extra_fields.items():
            if hasattr(self.state, k):
                setattr(self.state, k, v)
        ts = datetime.now(timezone.utc).isoformat()
        self.state.last_run_timestamp = ts
        self._save_state()
        self.logger.info("Transition: %s -> %s %s", old, new_state.value,
                         json.dumps(extra_fields) if extra_fields else "")

    # -- Subprocess execution ------------------------------------------------

    def _run_subprocess(self, args: list, cwd: Optional[str] = None,
                        timeout: Optional[int] = None) -> subprocess.CompletedProcess:
        """Run a subprocess, capture output, extract token counts."""
        timeout = timeout or self.SUBPROCESS_TIMEOUT
        effective_cwd = cwd or self.config.repo_path
        self.logger.info("Running: %s (cwd=%s)", " ".join(args), effective_cwd)

        try:
            result = subprocess.run(
                args,
                cwd=effective_cwd,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            self.logger.error("Subprocess timed out after %ds: %s", timeout, " ".join(args))
            raise

        self.logger.info("Exit code: %d", result.returncode)

        # Extract token usage from stdout/stderr
        self._extract_tokens(result.stdout)
        self._extract_tokens(result.stderr)

        # Detect rate limiting
        combined = (result.stdout or "") + (result.stderr or "")
        if result.returncode != 0 and ("429" in combined or "rate" in combined.lower()):
            self.logger.warning("Rate limit signal detected in subprocess output")

        return result

    def _extract_tokens(self, output: str):
        """Scan output for token usage patterns and accumulate."""
        if not output:
            return
        # Common patterns: "input_tokens": 1234, "output_tokens": 5678
        # Also: "tokens used: 1234"
        for pattern in [
            r'"input_tokens"\s*:\s*(\d+)',
            r'"output_tokens"\s*:\s*(\d+)',
            r'tokens?\s+used\s*:\s*(\d+)',
            r'token_count\s*:\s*(\d+)',
        ]:
            for match in re.finditer(pattern, output, re.IGNORECASE):
                tokens = int(match.group(1))
                self.state.accumulated_tokens += tokens

    def _reset_token_window_if_needed(self):
        """Reset accumulated tokens if the usage window has elapsed."""
        now = datetime.now(timezone.utc)
        if self.state.token_window_start:
            start = datetime.fromisoformat(self.state.token_window_start)
            elapsed_hours = (now - start).total_seconds() / 3600
            if elapsed_hours >= self.config.usage_window_hours:
                self.logger.info("Token window elapsed (%.1fh), resetting accumulator", elapsed_hours)
                self.state.accumulated_tokens = 0
                self.state.token_window_start = now.isoformat()
        else:
            self.state.token_window_start = now.isoformat()

    def _usage_below_threshold(self) -> bool:
        """Check if estimated remaining capacity is below safety threshold.

        Since we can't query Anthropic for session usage, we use a heuristic:
        if accumulated tokens in this window exceed (1 - threshold) of what
        we estimate the window supports, we should wait.

        Without a known ceiling, we treat any 429 as the definitive signal.
        This method is a soft check based on accumulated counts.
        """
        # We rely primarily on 429 detection, but provide a conservative
        # heuristic: if we've accumulated more than 500k tokens in the window,
        # start being cautious. This is a tunable soft limit.
        SOFT_TOKEN_CEILING = 500_000
        if self.state.accumulated_tokens > SOFT_TOKEN_CEILING * (1 - self.config.usage_safety_threshold):
            return True
        return False

    # -- Tekhton commands ----------------------------------------------------

    def _tekhton_cmd(self, *extra_args) -> list:
        return ["bash", os.path.join(self.config.tekhton_path, "tekhton.sh")] + list(extra_args)

    def _run_milestone(self, milestone_id: str) -> subprocess.CompletedProcess:
        return self._run_subprocess(self._tekhton_cmd("--milestone", milestone_id))

    def _run_fix_nonblockers(self) -> subprocess.CompletedProcess:
        return self._run_subprocess(self._tekhton_cmd("--fix-nonblockers"))

    def _run_fix_driftlog(self) -> subprocess.CompletedProcess:
        return self._run_subprocess(self._tekhton_cmd("--fix-driftlog"))

    def _run_diagnose(self) -> subprocess.CompletedProcess:
        return self._run_subprocess(self._tekhton_cmd("--diagnose"))

    # -- Git commands --------------------------------------------------------

    def _git(self, *args, **kwargs) -> subprocess.CompletedProcess:
        return self._run_subprocess(
            ["git"] + list(args),
            cwd=self.config.repo_path,
            timeout=120,
        )

    def _gh(self, *args, **kwargs) -> subprocess.CompletedProcess:
        return self._run_subprocess(
            ["gh"] + list(args),
            cwd=self.config.repo_path,
            timeout=120,
        )

    def _prepare_branch(self, milestone: Milestone):
        """Checkout integration branch, pull, create milestone branch."""
        branch_name = f"milestone/{milestone.id}-{milestone.title.lower().replace(' ', '-')[:50]}"
        self._git("checkout", self.config.integration_branch)
        self._git("pull", "origin", self.config.integration_branch)
        # Create fresh branch — delete if exists from a prior aborted run
        try:
            self._git("branch", "-D", branch_name)
        except Exception:
            pass
        self._git("checkout", "-b", branch_name)
        return branch_name

    def _commit_and_pr(self, milestone: Milestone, branch_name: str):
        """Stage, commit, push, create PR, enable auto-merge."""
        self._git("add", "-A")
        commit_msg = f"milestone {milestone.id}: {milestone.title}"
        self._git("commit", "-m", commit_msg)
        self._git("push", "-u", "origin", branch_name)
        self._gh(
            "pr", "create",
            "--base", self.config.integration_branch,
            "--head", branch_name,
            "--title", commit_msg,
            "--fill",
        )
        self._gh("pr", "merge", "--squash", "--auto")

    # -- Error analysis via Claude CLI ----------------------------------------

    # JSON schema for structured output from claude --print --json-schema
    ERROR_ANALYSIS_SCHEMA = json.dumps({
        "type": "object",
        "properties": {
            "decision": {
                "type": "string",
                "enum": [
                    "RETRY_MILESTONE", "RUN_FIX_NONBLOCKERS",
                    "RUN_FIX_DRIFTLOG", "RUN_DIAGNOSE", "STOP_AND_REPORT",
                ],
            },
            "reason": {"type": "string"},
        },
        "required": ["decision", "reason"],
    })

    def _analyze_error(self, milestone: Milestone, error_output: str) -> dict:
        """Use Claude CLI (--print) to decide next action after a failure.

        Runs under the user's Claude Max subscription — no API key needed.
        """
        self.logger.info("Analyzing error for milestone %s via Claude CLI", milestone.id)

        # Read manifest state
        manifest_lines = ""
        try:
            with open(self.config.manifest_path, "r") as f:
                manifest_lines = f.read()
        except Exception:
            pass

        # Read drift log if present
        drift_log = ""
        drift_path = os.path.join(self.config.repo_path, "DRIFT_LOG.md")
        if os.path.exists(drift_path):
            try:
                with open(drift_path, "r") as f:
                    drift_log = f.read()[-5000:]
            except Exception:
                pass

        # Truncate error output to last 200 lines
        error_lines = error_output.strip().split("\n")
        truncated_error = "\n".join(error_lines[-200:])

        prompt = (
            "You are the Tekhton Conductor's error analysis module. "
            "A milestone run has failed. Analyze the information and decide the next action.\n\n"
            f"## Failing milestone\nID: {milestone.id}\nTitle: {milestone.title}\n\n"
            f"## Last 200 lines of output\n```\n{truncated_error}\n```\n\n"
            f"## Manifest state\n```\n{manifest_lines}\n```\n\n"
            f"## Drift log (last 5000 chars)\n```\n{drift_log}\n```\n\n"
            "Decide: RETRY_MILESTONE if transient/fixable, RUN_FIX_NONBLOCKERS if "
            "non-blocking issues are piling up, RUN_FIX_DRIFTLOG if drift entries "
            "need resolution, RUN_DIAGNOSE if the failure is unclear, or "
            "STOP_AND_REPORT if the failure looks unrecoverable."
        )

        try:
            result = subprocess.run(
                [
                    "claude", "--print",
                    "--model", "sonnet",
                    "--output-format", "json",
                    "--json-schema", self.ERROR_ANALYSIS_SCHEMA,
                    "--max-turns", "1",
                    "--no-input",
                    prompt,
                ],
                capture_output=True, text=True, timeout=120,
            )

            if result.returncode != 0:
                self.logger.error("Claude CLI error analysis failed (exit %d): %s",
                                  result.returncode, (result.stderr or "")[:500])
                return {"decision": "STOP_AND_REPORT",
                        "reason": f"Claude CLI exited {result.returncode}"}

            # Parse structured JSON output
            text = result.stdout.strip()
            # The --output-format json wraps in a result object; extract
            try:
                outer = json.loads(text)
                # output-format json returns {"result": "...", ...}
                if "result" in outer:
                    parsed = json.loads(outer["result"])
                else:
                    parsed = outer
            except (json.JSONDecodeError, TypeError):
                # Try parsing raw text directly
                text = re.sub(r'^```\w*\n?', '', text)
                text = re.sub(r'\n?```$', '', text)
                parsed = json.loads(text)

            decision = parsed.get("decision", "STOP_AND_REPORT")
            valid_decisions = {
                "RETRY_MILESTONE", "RUN_FIX_NONBLOCKERS",
                "RUN_FIX_DRIFTLOG", "RUN_DIAGNOSE", "STOP_AND_REPORT",
            }
            if decision not in valid_decisions:
                self.logger.warning("Invalid decision '%s', defaulting to STOP_AND_REPORT", decision)
                decision = "STOP_AND_REPORT"

            return {"decision": decision, "reason": parsed.get("reason", "")}

        except subprocess.TimeoutExpired:
            self.logger.error("Claude CLI error analysis timed out")
            return {"decision": "STOP_AND_REPORT", "reason": "Analysis timed out"}
        except Exception as exc:
            self.logger.error("Error analysis failed: %s", exc)
            return {"decision": "STOP_AND_REPORT", "reason": f"Analysis failed: {exc}"}

    # -- Main loop -----------------------------------------------------------

    def arm(self, starting_milestone: Optional[str] = None):
        """Arm the conductor for a night run."""
        if self.state.state not in (State.IDLE.value, State.STOPPED_SUCCESS.value, State.STOPPED_ERROR.value):
            raise ValueError(f"Cannot arm from state {self.state.state}")
        self._transition(State.ARMED,
                         starting_milestone=starting_milestone,
                         night_run_active=True,
                         stop_requested=False,
                         consecutive_failures=0,
                         error_history=[])

    def stop(self):
        """Request graceful stop after current operation."""
        self.logger.info("Graceful stop requested")
        self.state.stop_requested = True
        self._save_state()

    def run(self):
        """Main blocking loop — call from the daemon entry point."""
        self.logger.info("Conductor run() starting, state=%s", self.state.state)

        # Bootstrap: clone or refresh the target repo
        try:
            self._ensure_repo()
        except Exception as exc:
            self.logger.error("Failed to bootstrap repo: %s", exc)
            self._transition(State.STOPPED_ERROR, night_run_active=False,
                             last_error_output=f"Repo bootstrap failed: {exc}")
            return

        if self.state.state == State.ARMED.value:
            self._transition(State.IDLE)
            self.state.night_run_active = True
            self._save_state()

        while not self._shutdown_event.is_set():
            if self.state.stop_requested:
                self._transition(State.IDLE, night_run_active=False, stop_requested=False)
                break

            current = self.state.state

            if current == State.IDLE.value and self.state.night_run_active:
                self._step_idle()
            elif current == State.WAITING_FOR_USAGE.value:
                self._step_waiting_for_usage()
            elif current in (State.STOPPED_SUCCESS.value, State.STOPPED_ERROR.value):
                self.logger.info("Terminal state %s reached, exiting loop", current)
                break
            else:
                # Non-night-run IDLE — just sleep and wait for commands
                self._shutdown_event.wait(5)

    def _step_idle(self):
        """From IDLE during a night run: find next milestone and execute."""
        self._reset_token_window_if_needed()

        # Check usage threshold
        if self._usage_below_threshold():
            self._transition(State.WAITING_FOR_USAGE)
            return

        milestones = parse_manifest(self.config.manifest_path)

        # If a starting milestone was specified, skip to it
        target = None
        if self.state.starting_milestone:
            for m in milestones:
                if m.id == self.state.starting_milestone and m.status != "done":
                    target = m
                    break
            self.state.starting_milestone = None  # Only used for the first pick
        else:
            target = find_next_milestone(milestones)

        if target is None:
            # Check if there are any incomplete milestones at all
            incomplete = [m for m in milestones if m.status != "done"]
            if not incomplete:
                self._transition(State.STOPPED_SUCCESS, night_run_active=False)
                return
            else:
                # All remaining milestones have unsatisfied deps — we're stuck
                self.logger.warning("No actionable milestones (deps unsatisfied)")
                self._transition(State.STOPPED_ERROR, night_run_active=False,
                                 last_error_output="No actionable milestones — dependency deadlock")
                return

        self._execute_milestone(target)

    def _execute_milestone(self, milestone: Milestone):
        """Full milestone lifecycle: branch, run, fix, commit, PR."""
        self._transition(State.RUNNING_MILESTONE,
                         active_milestone_id=milestone.id,
                         active_milestone_title=milestone.title)

        # Prepare git branch
        try:
            branch_name = self._prepare_branch(milestone)
        except Exception as exc:
            self.logger.error("Git branch preparation failed: %s", exc)
            self._handle_milestone_failure(milestone, str(exc))
            return

        # Run milestone
        try:
            result = self._run_milestone(milestone.id)
        except subprocess.TimeoutExpired:
            self._handle_milestone_failure(milestone, "Milestone timed out")
            return

        if result.returncode != 0:
            error_output = (result.stdout or "") + "\n" + (result.stderr or "")
            self.state.last_error_output = error_output[-10000:]

            # Check for rate limiting
            if "429" in error_output or "rate" in error_output.lower():
                self._transition(State.WAITING_FOR_USAGE)
                return

            self._handle_milestone_failure(milestone, error_output)
            return

        self.state.last_exit_code = 0

        # Run fixes
        self._transition(State.RUNNING_FIXES)
        try:
            self._run_fix_nonblockers()
        except Exception as exc:
            self.logger.warning("fix-nonblockers failed (non-fatal): %s", exc)

        try:
            self._run_fix_driftlog()
        except Exception as exc:
            self.logger.warning("fix-driftlog failed (non-fatal): %s", exc)

        # Commit and PR
        self._transition(State.COMMITTING)
        try:
            self._commit_and_pr(milestone, branch_name)
        except Exception as exc:
            self.logger.error("Commit/PR failed: %s", exc)
            self._handle_milestone_failure(milestone, f"Git commit/PR failed: {exc}")
            return

        # Success — record and loop back
        self.state.consecutive_failures = 0
        self.state.completed_milestones.append(milestone.id)
        self.logger.info("Milestone %s completed successfully", milestone.id)
        self._transition(State.IDLE, active_milestone_id=None,
                         active_milestone_title=None, night_run_active=True)

    def _handle_milestone_failure(self, milestone: Milestone, error_output: str):
        """Handle a milestone failure: count retries, analyze, decide."""
        self.state.consecutive_failures += 1
        self.state.last_exit_code = 1
        self.state.last_error_output = (error_output or "")[-10000:]
        self.state.error_history.append({
            "milestone_id": milestone.id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "error_snippet": (error_output or "")[-500:],
        })
        self._save_state()

        # Hard stop after N consecutive failures of same milestone
        if self.state.consecutive_failures >= self.config.max_milestone_retries:
            self.logger.error("Milestone %s failed %d consecutive times, stopping",
                              milestone.id, self.state.consecutive_failures)
            self._transition(State.STOPPED_ERROR, night_run_active=False)
            return

        # Analyze error via API
        self._transition(State.ANALYZING_ERROR)
        analysis = self._analyze_error(milestone, error_output)
        decision = analysis["decision"]
        reason = analysis.get("reason", "")
        self.logger.info("Error analysis decision: %s — %s", decision, reason)

        if decision == "RETRY_MILESTONE":
            self._transition(State.IDLE, night_run_active=True)
        elif decision == "RUN_FIX_NONBLOCKERS":
            try:
                self._run_fix_nonblockers()
            except Exception:
                pass
            self._transition(State.IDLE, night_run_active=True)
        elif decision == "RUN_FIX_DRIFTLOG":
            try:
                self._run_fix_driftlog()
            except Exception:
                pass
            self._transition(State.IDLE, night_run_active=True)
        elif decision == "RUN_DIAGNOSE":
            try:
                result = self._run_diagnose()
                self.logger.info("Diagnose output:\n%s", (result.stdout or "")[-2000:])
            except Exception:
                pass
            self._transition(State.IDLE, night_run_active=True)
        elif decision == "STOP_AND_REPORT":
            self._transition(State.STOPPED_ERROR, night_run_active=False)
        else:
            self._transition(State.STOPPED_ERROR, night_run_active=False)

    def _step_waiting_for_usage(self):
        """Wait for usage window to clear, retrying every 10 minutes."""
        self.logger.info("Waiting for usage window to clear (10min intervals)")
        self._reset_token_window_if_needed()

        if not self._usage_below_threshold():
            self.logger.info("Usage window appears clear, resuming")
            self._transition(State.IDLE, night_run_active=True)
            return

        if self.state.stop_requested:
            self._transition(State.IDLE, night_run_active=False, stop_requested=False)
            return

        # Wait 10 minutes (interruptible)
        self._shutdown_event.wait(600)

    # -- Signal handling -----------------------------------------------------

    def handle_sigterm(self, signum, frame):
        self.logger.info("SIGTERM received, shutting down gracefully")
        self._shutdown_event.set()
        self.state.stop_requested = True
        self._save_state()


# ---------------------------------------------------------------------------
# Daemon entry point
# ---------------------------------------------------------------------------

def setup_logging(log_path: str) -> logging.Logger:
    logger = logging.getLogger("conductor")
    logger.setLevel(logging.INFO)
    formatter = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
    )
    # File handler
    fh = logging.FileHandler(log_path)
    fh.setFormatter(formatter)
    logger.addHandler(fh)
    # Also log to stderr for systemd journal capture
    sh = logging.StreamHandler(sys.stderr)
    sh.setFormatter(formatter)
    logger.addHandler(sh)
    return logger


def main():
    config_path = os.environ.get("CONDUCTOR_CONFIG", "/etc/tekhton-conductor/conductor.cfg")
    if len(sys.argv) > 1:
        config_path = sys.argv[1]

    config = ConductorConfig.from_file(config_path)
    setup_logging(config.log_path)

    conductor = Conductor(config)

    # Register signal handlers
    signal.signal(signal.SIGTERM, conductor.handle_sigterm)
    signal.signal(signal.SIGINT, conductor.handle_sigterm)

    # Start the API server in a background thread
    from api import create_app
    import uvicorn

    app = create_app(conductor)
    api_thread = threading.Thread(
        target=uvicorn.run,
        kwargs={
            "app": app,
            "host": "0.0.0.0",
            "port": config.api_port,
            "log_level": "warning",
        },
        daemon=True,
    )
    api_thread.start()

    logging.getLogger("conductor").info(
        "Conductor started, API on port %d", config.api_port
    )

    # Run the main loop
    conductor.run()

    logging.getLogger("conductor").info("Conductor exited, final state: %s", conductor.state.state)


if __name__ == "__main__":
    main()
