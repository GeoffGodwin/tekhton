# Tekhton 3.1 — Pipeline Acceleration & Transparency

## Problem Statement

Tekhton produces high-quality code but its execution is opaque and often slower
than necessary. Users cannot tell why a run takes 10 minutes vs. 45 minutes. The
pipeline's multi-agent architecture compounds latency through redundant I/O,
full pipeline reruns for trivial test failures, underutilized tooling, and lack
of visibility into where time is spent.

**Goal:** Make Tekhton measurably faster at what it already does well, and make
its execution transparent enough that users can diagnose slowness themselves.

## Analysis Summary

### Where Wall-Clock Time Goes

Based on analysis of the codebase, here is the cost breakdown for a typical
single-milestone run:

| Phase | Estimated % of Wall Time | Notes |
|-------|--------------------------|-------|
| Agent execution (Claude API) | 85-92% | Dominant cost by far |
| Build gate (external tools) | 3-8% | Analyze + compile + UI test |
| Startup + detection + sourcing | 1-3% | 208 source statements, tech detection |
| Context assembly + prompting | 0.5-1% | Template rendering, budget checking |
| State persistence + I/O | 0.5-1% | State writes, causal log, metrics |
| Monitor + process management | <0.5% | FIFO-based, efficient |

**Key insight:** The only way to meaningfully reduce wall time is to reduce the
number and cost of agent invocations. All other optimizations save seconds, not
minutes.

### Agent Invocation Audit

A "clean pass" pipeline run invokes a minimum of 4 agents:

```
Scout → Coder → Reviewer → Tester
```

Real-world runs frequently hit 6-12 invocations:

| Trigger | Extra Agent Calls | Frequency |
|---------|-------------------|-----------|
| Build failure → fix agent | +1-2 | Common |
| Review rework → Coder again | +1-2 per cycle | Common |
| Turn exhaustion → continuation | +1-3 per stage | Occasional |
| Self-test failure → full pipeline retry | +4-8 | **Very common** |
| Specialist reviews (security/perf/API) | +1-3 | When enabled |
| Architect audit | +1 | Drift-triggered |
| Clarification → re-run | +1 | Occasional |

In `--complete` mode, the outer loop can retry the entire pipeline up to
`MAX_PIPELINE_ATTEMPTS=5` times, with a hard cap at `MAX_AUTONOMOUS_AGENT_CALLS=200`.

**Worst-case theoretical maximum:** 200 agent invocations (safety valve).
**Typical worst case:** 15-25 invocations for a difficult milestone.

### The Self-Test Rerun Problem (Highest-Impact Issue)

The most common cause of excessive wall time is the **pre-finalization test gate**
in `orchestrate.sh:251-287`. When 1-2 self-tests fail at run end — often due to
trivial issues like a shellcheck warning or a test assertion needing an update —
the orchestration loop triggers a **full pipeline retry** from the coder stage:

```
Tests fail at run end
  → orchestrate.sh:251-287 (pre-finalization gate)
  → Writes PREFLIGHT_ERRORS.md
  → Sets START_AT="coder"
  → continue → FULL PIPELINE RETRY (Coder → Reviewer → Tester)
```

This is wildly disproportionate for what are usually minor fixups. The lightweight
fix agent in `hooks.sh:309-351` (`FINAL_FIX_ENABLED`) does exist and runs with
only ~26 turns, but it fires **only at finalization time**, after the orchestration
loop is exhausted. So the expensive retry happens first; the cheap fix only runs
if the retry also fails.

A targeted Jr Coder fix attempt should be tried **before** falling back to a full
pipeline retry.

### Agent Model Economics

The pipeline uses a tiered model strategy (from `pipeline.conf`):

| Agent | Model | Cost Tier | Default Turns |
|-------|-------|-----------|---------------|
| Scout | `claude-haiku-4-5` | Cheapest | 20 |
| Coder | `claude-opus-4-6` | Most expensive | 35 (70 milestone) |
| Jr Coder | `claude-haiku-4-5` | Cheapest | 15 (30 milestone) |
| Reviewer | `claude-sonnet-4-6` | Mid | 10 (15 milestone) |
| Tester | `claude-haiku-4-5` | Cheapest | 30 (60 milestone) |
| Architect | `claude-sonnet-4-6` | Mid | 25 |

Scout runs on Haiku (~60x cheaper per token than Opus). Its job — file discovery
and complexity estimation — is correctly scoped for a cheap model. **Merging Scout
into Coder would be counterproductive** because it would force Opus to spend
expensive turns on file discovery work that Haiku handles well.

However, Scout currently underutilizes the tooling available to it.

### Scout Underutilizes Tree-Sitter and Serena

The Tekhton self-build has tree-sitter, Serena LSP, and the context compiler all
enabled (`pipeline.conf:97-106`):

```
REPO_MAP_ENABLED=true
SERENA_ENABLED=true
CONTEXT_COMPILER_ENABLED=true
```

Scout's prompt (`scout.prompt.md`) receives both the repo map and Serena LSP
tools. However, the core directive on line 9-10 contradicts this:

> Find the files relevant to the task below. Do not fix anything.
> Use `find`, `grep`, and `ls` to locate files by name and keyword.

This hardcodes a filesystem-crawling strategy even when the repo map already
provides ranked, task-relevant file signatures and Serena provides precise symbol
cross-references. The prompt says "use INSTEAD of blind find/grep" for the repo
map (line 30), but the core directive says "Use find, grep, and ls."

**Result:** Scout wastes Haiku turns re-discovering files that tree-sitter already
indexed and ranked. When repo map and Serena are available, Scout's job should
shift from "explore the filesystem" to "verify and annotate the repo map's
recommendations using LSP cross-references, then estimate complexity."

### Redundant Work Across Stages

Every agent invocation independently:
1. Re-reads architecture content from disk
2. Re-reads drift log from disk
3. Re-reads human notes and filters them
4. Re-reads clarifications file
5. Re-computes milestone window (re-parses DAG, re-reads milestone files)
6. Re-computes context budget (same arithmetic, same result)
7. Re-runs keyword extraction on the same task string

For a 6-agent run, architecture content alone is read 6 times. The milestone
window (DAG parse + file reads + budget arithmetic) is computed 6 times with
identical results.

### Tech Stack Detection

`detect_ui_framework()` and `detect_ui_test_cmd()` run on **every** pipeline
invocation. Results are never cached. For projects with many config files to
scan, this adds measurable startup latency.

### Context Assembly Inefficiencies

The context compiler (`lib/context_compiler.sh`) performs keyword extraction and
section filtering per-block per-agent. Key issues:

- `_estimate_block_tokens()` is called multiple times during budget enforcement
  without caching intermediate results
- Over-budget compression makes 3-5 full passes over all blocks in the worst case
- `extract_relevant_sections()` runs awk with regex matching per block (~100-200ms
  per 10KB) — called 5-9 times per agent for the same content

### What's Already Efficient

- **Agent monitoring:** FIFO-based with blocking reads — no polling overhead
- **State persistence:** Atomic tmpfile+mv pattern — safe and fast
- **Repo map caching:** mtime-based tag cache avoids re-parsing unchanged files
- **Causal log:** Append-only JSONL — fast writes, no lock contention
- **Milestone DAG:** In-memory arrays loaded once from manifest
- **Model tiering:** Scout/Tester/Jr Coder on Haiku, Coder on Opus — correct
  economic split for the work each agent does

---

## Design Philosophy

1. **Fix the biggest pain point first.** Self-test failures triggering full
   pipeline reruns is the most common cause of excessive run time. Fix that
   before measuring anything else.
2. **Use the tools you already have.** Tree-sitter and Serena are enabled but
   underutilized. Make existing agents leverage them properly before adding new
   infrastructure.
3. **Reduce agent calls > reduce per-call cost.** Eliminating one agent
   invocation saves more than optimizing ten file reads.
4. **Cheap models for cheap work.** Scout, Tester, and Jr Coder already run on
   Haiku — this is correct. Don't merge agents across model tiers.
5. **Cache within a run, not across runs.** Intra-run caching (read once, use
   many times) is safe and deterministic. Cross-run caching introduces staleness
   risks.
6. **Transparency is a feature.** Users should see a timing breakdown after
   every run. This also serves as a regression detector.
7. **No new dependencies.** All optimizations use bash 4+ and existing tools.
   Vector databases (Qdrant, ChromaDB) are deferred to v4.0.

---

## Milestone Plan

### Milestone 1: Jr Coder Test-Fix Gate

**Scope:** When self-tests fail at run end, try a cheap Jr Coder fix before
triggering a full pipeline retry. This is the single highest-impact change —
it prevents full Coder→Reviewer→Tester reruns for trivial test breakages.

**Changes:**

- In `orchestrate.sh:251-287` (pre-finalization test gate), when new test
  failures are detected, **insert a Jr Coder fix loop** before the full retry:
  1. Spawn Jr Coder (Haiku, `JR_CODER_MAX_TURNS`) with test output + error
  2. Re-run `TEST_CMD` independently (shell runs tests, not the agent — this
     prevents the Jr Coder from cheating by modifying tests to pass)
  3. If tests pass → proceed to finalization (skip full retry)
  4. If tests fail → toss back to Jr Coder with updated output (up to
     `PREFLIGHT_FIX_MAX_ATTEMPTS`, default: 2)
  5. If Jr Coder exhausts attempts → fall through to existing full retry logic

- Add config keys:
  - `PREFLIGHT_FIX_ENABLED` (default: true)
  - `PREFLIGHT_FIX_MAX_ATTEMPTS` (default: 2)
  - `PREFLIGHT_FIX_MODEL` (default: `CLAUDE_JR_CODER_MODEL`)
  - `PREFLIGHT_FIX_MAX_TURNS` (default: `JR_CODER_MAX_TURNS`)

- Add a prompt template `prompts/preflight_fix.prompt.md`:
  - Receives: test output, file list from CODER_SUMMARY.md, error details
  - Constrained to: fix the failing tests, do not refactor
  - Tools: same as build_fix (Edit, Read, Bash for running targeted commands)

**Key design: shell-verified testing.** The Jr Coder fixes code and the shell
independently runs `TEST_CMD`. The Jr Coder never sees test output it generated
itself — only the shell's independent verification. This prevents the agent from
"fixing" tests by weakening assertions.

**Acceptance criteria:**
- When 1-2 tests fail at run end, Jr Coder fix is attempted before full retry
- Tests are run by the shell, not by the fix agent
- If Jr Coder fixes the issue, no full pipeline retry occurs
- If Jr Coder fails after max attempts, existing retry logic fires unchanged
- `PREFLIGHT_FIX_ENABLED=false` disables the feature (existing behavior)
- All existing tests pass
- New test covering the fix-before-retry flow

**Files touched:**
- `lib/orchestrate.sh` — insert fix loop in pre-finalization gate
- `prompts/preflight_fix.prompt.md` — new prompt template
- `lib/config_defaults.sh` — new config keys
- `lib/orchestrate_helpers.sh` — Jr Coder fix helper function

---

### Milestone 2: Scout Prompt — Leverage Repo Map & Serena

**Scope:** When tree-sitter repo maps and/or Serena LSP are available, Scout
should use them as primary discovery tools instead of blind `find`/`grep`.

**Changes:**

- Rewrite `prompts/scout.prompt.md` with conditional directives:
  - When `REPO_MAP_CONTENT` is available: Scout's job shifts from "explore the
    filesystem" to "verify and refine the repo map's ranked candidates." Use
    LSP tools (`find_symbol`, `find_referencing_symbols`) for cross-reference
    verification. Read candidate files only to confirm relevance — do not use
    `find`/`grep` for file discovery.
  - When `SERENA_ACTIVE` but no repo map: use LSP tools for symbol-based
    discovery, supplemented by targeted grep for non-symbol patterns.
  - When neither is available: existing behavior (find/grep/ls exploration).

- Reduce Scout's filesystem tool allowlist when repo map is available:
  - Keep: Read, Glob, Grep, Write (for SCOUT_REPORT.md)
  - Remove: `Bash(find:*)`, `Bash(cat:*)`, `Bash(ls:*)` — these are redundant
    when the repo map and LSP provide the same data more efficiently.
  - Conditional in `stages/coder.sh` where `AGENT_TOOLS_SCOUT` is set.

- Expected turn savings: Scout currently uses up to 20 turns on Haiku for file
  discovery. With repo map pre-ranking, Scout should complete in 5-10 turns
  because it's verifying a ranked list rather than searching from scratch.

**Acceptance criteria:**
- When `REPO_MAP_ENABLED=true`, Scout prompt instructs verification-first strategy
- When `SERENA_ACTIVE=true`, Scout prompt instructs LSP-based cross-referencing
- When neither is available, Scout falls back to existing find/grep behavior
- Scout produces identical SCOUT_REPORT.md format regardless of tooling mode
- Scout turn usage drops when repo map is available (measurable in metrics)
- All existing tests pass

**Files touched:**
- `prompts/scout.prompt.md` — conditional rewrite
- `stages/coder.sh` — conditional tool allowlist for Scout
- `lib/config_defaults.sh` — optional `SCOUT_REPO_MAP_TOOLS_ONLY` config

---

### Milestone 3: Instrumentation & Timing Report

**Scope:** Add wall-clock timing to every pipeline phase and emit a
human-readable timing report at run end. This provides the baseline data
needed to measure impact of all subsequent optimizations.

**Changes:**

- Add `_phase_start()` / `_phase_end()` timing helpers to `lib/common.sh`
- Instrument each phase in `tekhton.sh` and stage files:
  - Startup/sourcing
  - Config load + detection
  - Indexer (repo map generation)
  - Per-agent: prompt assembly, agent execution, output parsing
  - Build gate (per-phase: analyze, compile, constraints, UI test)
  - State persistence
  - Finalization
- Emit `TIMING_REPORT.md` alongside `RUN_SUMMARY.json` at run end
- Add timing data to the dashboard heartbeat (`emit_dashboard_run_state()`)
- Display a timing summary in the completion banner

**Acceptance criteria:**
- Every agent invocation records: prompt assembly time, execution time, output
  parse time
- Every build gate phase records wall-clock duration
- `TIMING_REPORT.md` is written at run end with per-phase breakdown
- Completion banner shows top-3 time consumers
- No measurable performance regression from instrumentation itself (<100ms total)
- All existing tests pass
- New test coverage for timing helpers

**Files touched:**
- `lib/common.sh` — timing helpers
- `tekhton.sh` — phase instrumentation
- `lib/agent.sh` — per-agent timing
- `lib/gates.sh` — per-gate-phase timing
- `lib/finalize_summary.sh` — TIMING_REPORT.md emission
- `lib/finalize_display.sh` — banner timing summary

---

### Milestone 4: Intra-Run Context Cache

**Scope:** Read shared context files once at pipeline startup and reuse across
all agent invocations within the same run.

**Changes:**

- At startup (after config load), pre-read and cache in shell variables:
  - `_CACHED_ARCHITECTURE_CONTENT`
  - `_CACHED_DRIFT_LOG_CONTENT`
  - `_CACHED_HUMAN_NOTES_BLOCK` (filtered)
  - `_CACHED_CLARIFICATIONS_CONTENT`
  - `_CACHED_ARCHITECTURE_LOG_CONTENT`
- Modify `render_prompt()` in `lib/prompts.sh` to use cached values instead of
  re-reading files
- Pre-compute milestone window once at startup (and after milestone transitions)
  instead of per-agent
- Cache keyword extraction results from task string (computed once, reused by
  context compiler across agents)
- Cache `_estimate_block_tokens()` results and invalidate only on compression

**Acceptance criteria:**
- Architecture content, drift log, notes, and clarifications are read from disk
  exactly once per pipeline run (verifiable via timing report)
- Milestone window is computed once per milestone, not per agent
- Context budget arithmetic runs once per agent, not 3-5 times
- No behavioral change — identical prompts generated
- All existing tests pass
- Timing report shows reduced context assembly time

**Files touched:**
- `tekhton.sh` — startup caching
- `lib/prompts.sh` — use cached variables
- `lib/context_compiler.sh` — cache keyword extraction
- `lib/context_budget.sh` — cache token estimates
- `lib/milestone_window.sh` — compute-once pattern

---

### Milestone 5: Reduce Unnecessary Agent Invocations

**Scope:** Eliminate unnecessary agent calls through smarter routing decisions.

**Changes:**

1. **Conditional specialist invocation:**
   - Before spawning a specialist (security, perf, API), check if the diff
     touches files relevant to that specialist.
   - Security: skip if no auth/crypto/input-handling files changed.
   - Performance: skip if no hot-path/query/loop files changed.
   - API: skip if no route/endpoint/schema files changed.
   - Detection is keyword-based on diff file paths (fast, no agent needed).

2. **Diff-size review threshold:**
   - After Coder completes, measure diff size (`git diff --stat`).
   - If diff is below `REVIEW_SKIP_THRESHOLD` (default: 0, meaning always
     review), skip the full Reviewer agent and auto-pass review.
   - Add `REVIEW_SKIP_THRESHOLD` config (lines changed).

3. **Smarter turn budget from metrics history:**
   - When `METRICS_ADAPTIVE_TURNS=true` and sufficient history exists, use
     historical median turns for the task type rather than the configured max.
   - Reduce over-provisioned turn budgets that cause unnecessary continuation
     attempts.

**Acceptance criteria:**
- Specialist agents only run when diff touches relevant files
- Metrics-calibrated turn budgets reduce continuation frequency
- All optimizations are configurable and default to conservative settings
- All existing tests pass
- Timing report shows reduced agent count

**Files touched:**
- `lib/specialists.sh` — conditional invocation
- `lib/agent_helpers.sh` — diff-size measurement
- `lib/metrics_calibration.sh` — adaptive turn budgets
- `lib/config_defaults.sh` — new config keys

---

### Milestone 6: Structured Run Memory

**Scope:** Replace grep-based causal log scanning with a structured, indexed
run-end summary for faster cross-run context injection.

**Changes:**

- At run end, emit `RUN_MEMORY.jsonl` containing:
  ```json
  {
    "run_id": "run_20250331_...",
    "milestone": "m01",
    "task": "Add user auth",
    "files_touched": ["src/auth.py", "tests/test_auth.py"],
    "decisions": ["Used JWT over session tokens", "Added middleware pattern"],
    "rework_reasons": ["Missing input validation", "Test coverage below 80%"],
    "test_outcomes": {"passed": 12, "failed": 0, "skipped": 1},
    "duration_seconds": 342,
    "agent_calls": 6,
    "verdict": "PASS"
  }
  ```
- On next run, build `INTAKE_HISTORY_BLOCK` by reading the last N entries from
  `RUN_MEMORY.jsonl` filtered by keyword relevance to current task.
- Keyword matching uses simple bash string operations (no vector DB).
- Prune to last `RUN_MEMORY_MAX_ENTRIES` (default: 50) entries.

**Why not vector memory (yet):**
- The bottleneck is agent execution time, not context retrieval speed.
- Keyword-based filtering on 50 structured records is instant in bash.
- A vector DB adds a service dependency, embedding costs, and non-determinism.
- This structured approach provides 80% of the benefit. If it proves
  insufficient, a future milestone adds optional vector augmentation.

**Acceptance criteria:**
- `RUN_MEMORY.jsonl` is emitted at every run end
- Next run's `INTAKE_HISTORY_BLOCK` is built from structured memory, not log scan
- Keyword relevance filtering produces useful context for related tasks
- Memory file stays under 50 entries (auto-pruned)
- All existing tests pass

**Files touched:**
- `lib/finalize_summary.sh` — RUN_MEMORY.jsonl emission
- `lib/causality.sh` — structured memory query
- `lib/prompts.sh` — INTAKE_HISTORY_BLOCK from structured memory
- `lib/config_defaults.sh` — RUN_MEMORY_MAX_ENTRIES

---

### Milestone 7: Progress Transparency

**Scope:** Make pipeline execution visible to users in real-time, showing what
the pipeline is doing and why.

**Changes:**

1. **Stage progress display:**
   - Before each agent invocation, print a clear status line:
     ```
     [tekhton] Stage 2/4: Reviewer (cycle 1/3) — estimated 2-4 min based on history
     ```
   - After each agent, print outcome:
     ```
     [tekhton] Reviewer: REWORK (3 issues) — 2m 14s — rework coder next
     ```

2. **Decision explanation logging:**
   - When the pipeline makes a routing decision (skip specialist, trigger
     continuation, try Jr Coder fix, etc.), log the reason:
     ```
     [tekhton] Trying Jr Coder fix — 2 test failures detected (PREFLIGHT_FIX_ENABLED=true)
     [tekhton] Skipping security specialist — diff doesn't touch auth files
     [tekhton] Continuing coder — turn limit hit, progress detected (attempt 2/3)
     ```

3. **Live dashboard enhancement:**
   - Add current phase, elapsed time, and estimated remaining time to the
     dashboard state emitted via `emit_dashboard_run_state()`.

4. **Run-end summary enhancement:**
   - Add a "Pipeline Decisions" section to `RUN_SUMMARY.json` listing every
     routing decision made and why.
   - Add "Time Breakdown" section with per-phase timings from Milestone 3.

**Acceptance criteria:**
- Every agent invocation is preceded by a human-readable status line
- Every routing decision is logged with its reason
- Run-end summary includes a decisions log and timing breakdown
- Dashboard shows current phase and elapsed time
- All existing tests pass

**Files touched:**
- `lib/common.sh` — progress display helpers
- `stages/coder.sh` — status lines
- `stages/review.sh` — status lines
- `stages/tester.sh` — status lines
- `lib/specialists.sh` — decision logging
- `lib/finalize_summary.sh` — decisions + timing in summary
- `lib/finalize_display.sh` — enhanced completion banner

---

## Future: Vector-Augmented Memory (v4.0)

If Milestone 6's structured memory proves insufficient for cross-run context
quality, a vector store integration could be added as an optional layer:

- **Embedding source:** Task descriptions, agent outputs, rework reasons,
  architectural decisions
- **Store:** Qdrant or ChromaDB (local, no cloud dependency)
- **Query:** Semantic similarity search for "relevant past context" instead of
  keyword matching
- **Integration point:** Replace keyword filter in `INTAKE_HISTORY_BLOCK`
  assembly with vector query
- **Constraint:** Must be optional (`VECTOR_MEMORY_ENABLED`, default: false).
  Pipeline must remain functional without it.

**Why defer:**
1. The dominant cost is agent API calls, not context retrieval
2. Structured keyword matching on 50 records is effectively instant
3. Vector stores add operational complexity (service lifecycle, embeddings cost)
4. Determinism guarantee is harder with fuzzy similarity search
5. The real win is fewer, better-targeted agent calls — not smarter retrieval

---

## Implementation Order & Dependencies

```
M1: Jr Coder Test-Fix Gate ────────┐
                                    ├──▶ M3: Instrumentation
M2: Scout Prompt Rewrite ──────────┘         │
                                              ▼
                                    M4: Intra-Run Cache
                                              │
                                    M5: Reduce Agents
                                              │
                               ┌──────────────┴──────────────┐
                               ▼                              ▼
                      M6: Run Memory              M7: Transparency
```

M1 and M2 are independent, high-impact, low-risk changes that can be done first
(or in parallel). M3 adds instrumentation to measure impact of M1/M2. M4 and M5
build on instrumentation data. M6 and M7 are independent finishing milestones.

---

## Estimated Impact

| Milestone | Agent Calls Saved | Wall Time Saved | Effort |
|-----------|-------------------|-----------------|--------|
| M1: Jr Coder Test-Fix | 4-8 per failed run | 5-20 min per run | Medium |
| M2: Scout Prompt | 0 (same calls, fewer turns) | 1-3 min (turn savings) | Small |
| M3: Instrumentation | 0 | 0 (diagnostic) | Small |
| M4: Intra-Run Cache | 0 | 1-5s per run | Small |
| M5: Reduce Agents | 1-3 per run | 2-10 min per run | Medium |
| M6: Run Memory | 0-1 (better context) | Indirect (fewer reworks) | Medium |
| M7: Transparency | 0 | 0 (diagnostic) | Small |

**M1 is the highest-impact milestone.** Preventing full pipeline reruns for
trivial test failures saves entire pipeline cycles — often 5-20 minutes per
occurrence on the most common failure mode.

**M2 is the highest-ROI milestone.** A prompt rewrite with no infrastructure
changes makes Scout leverage tooling it already has access to, reducing wasted
turns on a cheap model and improving the quality of Scout's output for downstream
agents.
