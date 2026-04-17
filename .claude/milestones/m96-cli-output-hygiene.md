# Milestone 96: CLI Output Hygiene
<!-- milestone-meta
id: "96"
status: "done"
-->

## Overview

Tekhton's terminal output has grown organically across 95 milestones and now
conflates two audiences: a human watching in real time and a log reader doing
post-mortem analysis. Internal diagnostics, per-stage cache hits, and context
breakdowns scroll by alongside the status information a user actually needs.

This milestone performs a focused hygiene pass: fix three output bugs, reduce
noise by moving internal diagnostics to log-only, collapse redundant multi-line
blocks into single summary lines, and improve the prominence of the two most
actionable outputs (version bump, what's-next guidance).

No architectural changes. No new dependencies. All output changes apply to
non-TTY paths transparently. The cleaned-up output is also a prerequisite for
the V4 TUI milestone, which will build a live display layer around this
normalized event stream.

## Bugs to Fix

### Bug 1 — Event ID leakage to stdout

`emit_event` ends with `printf '%s' "$event_id"` (no trailing newline). Call
sites that do not capture the return value (`eid=$(emit_event ...)`) print the
event ID directly onto stdout, where it runs into the very next `log` call on
the same line. Symptoms in current output:

```
pipeline.001[tekhton] Milestone 95 metadata updated in m95-...
tester.002[✓] Test audit passed — all tests meet integrity standards.
pipeline.003[tekhton] Cleared 1 resolved item(s) from ...
pipeline.004[tekhton] Archived milestone 95 to ...
```

**Fix:** Audit all `emit_event` call sites in `lib/` and `stages/` and
`tekhton.sh`. For every call that does not assign the result to a variable,
redirect stdout to `/dev/null`:

```bash
emit_event "pipeline_end" "pipeline" "exit_code=${exit_code}" \
    "$_LAST_STAGE_EVT" "" "" > /dev/null
```

Affected files include at minimum: `lib/finalize.sh`, `lib/test_audit.sh`,
`lib/milestone_ops.sh`, `lib/milestone_acceptance.sh`, `lib/test_baseline.sh`,
`lib/quota.sh`, `lib/preflight.sh`, `lib/milestone_split.sh`,
`lib/orchestrate_recovery.sh`, `stages/tester_fix.sh`.

### Bug 2 — Duplicate Run Summary after Reviewer

`stages/review_helpers.sh` calls `print_run_summary` at both its approval path
(~line 37) and its rework path (~line 70), so on a first-cycle approval the
summary prints twice with only one log line between them.

**Fix:** Consolidate so `print_run_summary` is called exactly once per
reviewer cycle in each exit path.

### Bug 3 — Stage pre-announcement duplicates the stage banner

Every stage emits a plain log line immediately before the visual header:

```
[tekhton] Stage 2/4: Security — no estimate
                                                ← gap
══════════════════════════════════════
  Stage 2 / 4 — Security
══════════════════════════════════════
```

The log line carries no information the banner does not already carry.

**Fix:** Remove the standalone `log "Stage N/M: <name> — ..."` calls that
precede each stage's `header` call. The header is sufficient on its own.
Estimate information (currently "no estimate" or a time) can be incorporated
into the header line itself when available:
```
  Stage 2 / 4 — Security                (est. 2m)
```

## Noise Reduction

### NR1 — MCP / Indexer startup block (8 lines → 1)

Current:
```
[tekhton] [indexer] Serena LSP: installed
[tekhton] Indexer: available (repo map enabled)
[tekhton] [mcp] Starting Serena MCP server...
[tekhton] [mcp] MCP config: /home/.../serena_mcp_config.json
[tekhton] [mcp] Serena MCP integration enabled.
[tekhton] [mcp] Serena path: /home/.../serena
[tekhton] [mcp] Language servers: pylsp, bash-language-server
[tekhton] Serena: MCP integration active
```

Target:
```
[✓] Indexer + Serena MCP ready  (pylsp, bash-language-server)
```

On failure/degraded mode: `[!] Serena MCP unavailable — falling back to v2 context`

The path / config file details are written to the log file as before; they are
suppressed from stdout.

### NR2 — Report archival block (N lines → 1)

Current: one `[tekhton] Archived previous ...` per file.

Target: `[tekhton] Archived 5 previous reports`

When no files needed archiving, suppress the message entirely.

### NR3 — Per-stage context breakdown (8-line table → single summary line)

The full context breakdown table currently prints once per stage (~4× per run).
The total summary line at the bottom already contains everything the user needs.

**Fix:** Suppress the per-row breakdown from stdout (write to log only). Fold
the total into the agent progress line instead:

```
[tekhton] [Coder] Turns: 60/70 | Time: 26m41s | Context: ~12.7k tokens (6%)
```

This requires passing the context total into the agent monitor's completion
line in `lib/agent_monitor.sh` / `lib/agent.sh`. The per-stage breakdown
continues to appear in the log file.

### NR4 — Internal diagnostics moved to log-only

The following line types provide no user-facing value on stdout. They belong in
the log file and nowhere else. Each should be emitted only via a `log_verbose`
wrapper (new function in `lib/common.sh`) that writes to the log but not to the
terminal.

Lines to suppress from stdout:
- `[context-compiler] Extracted keywords: ...`
- `[indexer] Repo map loaded from run cache (hit #N)`
- `[indexer] Run cache saved: ...`
- `[indexer] Test symbol map written to ...`
- `[dry-run] Dry-run cache: no cache found.`
- `[context-cache] Preloaded context cache (arch=N, drift=N, ...)`
- `[context-cache] Drift log cache invalidated`
- `[context-cache] Milestone window cache invalidated`
- `Run summary written to ...`
- `Run memory appended to ...`
- `Timing report written to ...`
- `[tester-diag] Prompt: N chars (~N tokens)` (all tester-diag lines except the
  Stage Complete summary)
- `[milestone_window] Included N milestone(s), N budget, N remaining`

A `VERBOSE_OUTPUT` config key (default: `false`) enables stdout for any
`log_verbose` call, for users who want the full firehose back.

### NR5 — Remove "Agent calls" counter from Orchestration Loop header

The counter `Agent calls: 0 / 200` in the orchestration loop box never carries
actionable information. The ceiling is a circuit-breaker, not meaningful
progress. Remove the line entirely from `lib/orchestrate_helpers.sh`.

### NR6 — Role template warnings moved after startup banner

Currently these warnings appear before the startup banner, orphaned above it:
```
[tekhton] Using built-in role template for security...
[tekhton] Using built-in role template for intake...

══════════════════════════════════════
  Tekhton — ProjectName — Starting at: coder
══════════════════════════════════════
```

**Fix:** Defer role template warnings until after the header call (they are
informational, not fatal). Alternatively, integrate them as footnotes inside
the startup block.

## Information Architecture

### IA1 — Reduce print_run_summary frequency

`print_run_summary` currently fires after: Scout, Coder, Security, Reviewer,
sub-agent completions, and several paths in final checks. The growing cumulative
table is genuinely useful as a progress tracker but is only meaningful at
natural phase transitions.

**Policy:**
- **Keep** after Coder, after Reviewer (on pass or rework), at the final
  Pipeline Complete banner (already showing it).
- **Remove** after Scout (its one-liner status is sufficient), after Security
  (its status line is sufficient), after Test Audit (same), and from
  intermediate final-check paths that are immediately followed by another print.

### IA2 — Version bump into Pipeline Complete banner

Currently a quiet log line emitted in the finalization noise:
```
[tekhton] Bumped project version: 0.1.20 → 0.1.21 (patch)
```

**Fix:** Expose the version bump in the Pipeline Complete banner:
```
══════════════════════════════════════
  Tekhton — Pipeline Complete
══════════════════════════════════════

  Task:      M96
  Verdict:   APPROVED_WITH_NOTES
  Milestone: 96 — COMPLETE
  Version:   0.1.20 → 0.1.21 (patch)
  Time breakdown (top 3):
  ...
```

The version bump variables are available at finalize time; this is purely a
display change in `lib/finalize_display.sh` and `lib/finalize_summary.sh`.

### IA3 — "What's next" promoted to final line

The `What's next:` guidance from `lib/milestone_progress.sh` currently appears
mid-flow, sandwiched between the Pipeline Complete banner and the commit message
wall. It is the most actionable output of the entire run.

**Fix:** Move it to the absolute last printed line — after the final
`print_run_summary` call and after the commit confirmation:
```
[✓] Committed. Open a PR and squash-merge to main when ready.

What's next: tekhton --milestone "M93: Rejection Artifact Preservation..."
```

### IA4 — Normalize prefix semantics

Current state: `[!]` is used for informational mode flags, operational warnings,
quality lint warnings, and agent errors simultaneously.

**Proposed mapping:**

| Prefix | Meaning | Example |
|--------|---------|---------|
| `[✓]` | Success / gate passed | `[✓] Build gate PASSED` |
| `[!]` | Warning requiring attention | `[!] Uncommitted changes detected` |
| `[✗]` | Failure / blocking error | `[✗] Build gate FAILED` |
| `[~]` | Mode / config info (non-actionable) | `[~] MILESTONE MODE — Review cycles: 4` |

Mode announcements such as `MILESTONE MODE`, `HUMAN MODE`, and `DRY RUN` are
currently `[!]`. Change them to `[~]` (or remove the prefix character and use
bold styling only).

### IA5 — Truncate commit diff table

The git diff file list in the suggested commit message is a wall of ~20+ entries.
Show only the top 5 most significant entries (sorted by total lines changed) plus
the summary line:

```
  lib/test_audit.sh                 | 323 ++----...
  .tekhton/MILESTONE_ARCHIVE.md     | 139 ++++...
  .tekhton/CODER_SUMMARY.md         | 131 ++++...
  tekhton.sh                        |   6 +
  ARCHITECTURE.md                   |   4 +
  ... 19 more files
  24 files changed, 296 insertions(+), 577 deletions(-)
```

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Shell files modified | ~12 | `lib/common.sh`, `lib/agent.sh`, `lib/agent_monitor.sh`, `lib/agent_helpers.sh`, `lib/finalize.sh`, `lib/finalize_display.sh`, `lib/causality.sh` (or call sites), `lib/orchestrate_helpers.sh`, `lib/mcp.sh`, `lib/indexer.sh`, `stages/review_helpers.sh`, `tekhton.sh` |
| New config keys | 2 | `VERBOSE_OUTPUT` (default: false), noted in `lib/config_defaults.sh` and CLAUDE.md |
| Shell tests added | 1 | `tests/test_cli_output_hygiene.sh` — verifies no event ID leakage (runs pipeline stub and checks no `pipeline.NNN` or `tester.NNN` in stdout) |

## Acceptance Criteria

- [ ] No `pipeline.NNN` or `tester.NNN` string appears in pipeline stdout
      during a normal run (captured and asserted in test)
- [ ] `print_run_summary` fires at most once per pipeline stage on a clean run
      with no rework cycles
- [ ] MCP/Indexer startup emits at most 2 lines to stdout
- [ ] Report archival emits exactly 1 line to stdout (or 0 if nothing to archive)
- [ ] Context breakdown table does not appear on stdout; total is present on the
      agent completion line
- [ ] "Agent calls: N / 200" does not appear in any Orchestration Loop block
- [ ] Role template warnings appear after the startup banner, not before it
- [ ] `What's next:` line is printed after the final `print_run_summary`, not
      before it
- [ ] Version bump (when applicable) is present inside the Pipeline Complete
      banner
- [ ] `VERBOSE_OUTPUT=true` restores all suppressed diagnostic lines to stdout
