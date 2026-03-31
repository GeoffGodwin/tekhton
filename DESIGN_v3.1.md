# Tekhton 3.1 — Pipeline Acceleration & Transparency

## Problem Statement

Tekhton produces high-quality code but its execution is opaque and often slower
than necessary. Users cannot tell why a run takes 10 minutes vs. 45 minutes. The
pipeline's multi-agent architecture compounds latency through redundant I/O,
repeated context assembly, unnecessary agent invocations, and lack of visibility
into where time is spent.

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
| Specialist reviews (security/perf/API) | +1-3 | When enabled |
| Architect audit | +1 | Drift-triggered |
| Clarification → re-run | +1 | Occasional |

In `--complete` mode, the outer loop can retry the entire pipeline up to
`MAX_PIPELINE_ATTEMPTS=5` times, with a hard cap at `MAX_AUTONOMOUS_AGENT_CALLS=200`.

**Worst-case theoretical maximum:** 200 agent invocations (safety valve).
**Typical worst case:** 15-25 invocations for a difficult milestone.

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

---

## Design Philosophy

1. **Measure before optimizing.** Milestone 1 adds instrumentation. No
   behavioral changes until we have baseline data.
2. **Reduce agent calls > reduce per-call cost.** Eliminating one agent
   invocation saves more than optimizing ten file reads.
3. **Cache within a run, not across runs.** Intra-run caching (read once, use
   many times) is safe and deterministic. Cross-run caching introduces staleness
   risks.
4. **Transparency is a feature.** Users should see a timing breakdown after
   every run. This also serves as a regression detector.
5. **No new dependencies.** All optimizations use bash 4+ and existing tools.
   Vector databases (Qdrant, ChromaDB) are deferred to v4.0.

---

## Milestone Plan

### Milestone 1: Instrumentation & Timing Report

**Scope:** Add wall-clock timing to every pipeline phase and emit a
human-readable timing report at run end.

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

### Milestone 2: Intra-Run Context Cache

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

### Milestone 3: Detection Caching

**Scope:** Cache tech stack detection results and skip re-detection when project
files haven't changed.

**Changes:**

- After detection, write results to `.claude/detect_cache.json` with mtimes of
  the config files that were scanned (package.json, Cargo.toml, etc.)
- On subsequent runs, compare mtimes. If unchanged, load from cache.
- Add `--force-detect` flag to bypass cache.
- Cache includes: detected languages, frameworks, build/test/lint commands,
  UI framework, UI test command.

**Acceptance criteria:**
- Second consecutive run with no file changes skips all detection I/O
- Cache invalidates when any detected config file's mtime changes
- `--force-detect` bypasses cache
- Detection results are identical cached vs. fresh
- All existing tests pass

**Files touched:**
- `lib/detect.sh` — cache read/write
- `lib/detect_commands.sh` — cache integration
- `tekhton.sh` — `--force-detect` flag

---

### Milestone 4: Reduce Agent Invocations

**Scope:** Eliminate unnecessary agent calls through smarter routing decisions.

**Changes:**

1. **Merge Scout into Coder when repo map is available:**
   - When `REPO_MAP_ENABLED=true`, the repo map already provides what Scout
     discovers. Inject the repo map directly into the Coder prompt and skip the
     separate Scout invocation.
   - Add `SCOUT_SKIP_WITH_REPO_MAP` config (default: true).
   - Fallback: if repo map generation fails, run Scout as before.

2. **Diff-size review threshold:**
   - After Coder completes, measure diff size (`git diff --stat`).
   - If diff is below `REVIEW_SKIP_THRESHOLD` (default: 0, meaning always review),
     skip the full Reviewer agent and auto-pass review.
   - Add `REVIEW_SKIP_THRESHOLD` config (lines changed).

3. **Conditional specialist invocation:**
   - Before spawning a specialist (security, perf, API), check if the diff
     touches files relevant to that specialist.
   - Security: skip if no auth/crypto/input-handling files changed.
   - Performance: skip if no hot-path/query/loop files changed.
   - API: skip if no route/endpoint/schema files changed.
   - Detection is keyword-based on diff file paths (fast, no agent needed).

4. **Smarter turn budget from metrics history:**
   - When `METRICS_ADAPTIVE_TURNS=true` and sufficient history exists, use
     historical median turns for the task type rather than the configured max.
   - Reduce over-provisioned turn budgets that cause unnecessary continuation
     attempts.

**Acceptance criteria:**
- With `REPO_MAP_ENABLED=true`, Scout is skipped (1 fewer agent call)
- Specialist agents only run when diff touches relevant files
- Metrics-calibrated turn budgets reduce continuation frequency
- All optimizations are configurable and default to conservative settings
- All existing tests pass
- Timing report shows reduced agent count

**Files touched:**
- `stages/coder.sh` — scout-skip logic
- `lib/agent_helpers.sh` — diff-size measurement
- `lib/specialists.sh` — conditional invocation
- `lib/metrics_calibration.sh` — adaptive turn budgets
- `lib/config_defaults.sh` — new config keys

---

### Milestone 5: Structured Run Memory

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
  insufficient, Milestone 6 (future) adds optional vector augmentation.

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

### Milestone 6: Progress Transparency

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
   - When the pipeline makes a routing decision (skip scout, skip specialist,
     trigger continuation, etc.), log the reason:
     ```
     [tekhton] Skipping Scout — repo map available (SCOUT_SKIP_WITH_REPO_MAP=true)
     [tekhton] Skipping security specialist — diff doesn't touch auth files
     [tekhton] Continuing coder — turn limit hit, progress detected (attempt 2/3)
     ```

3. **Live dashboard enhancement:**
   - Add current phase, elapsed time, and estimated remaining time to the
     dashboard state emitted via `emit_dashboard_run_state()`.

4. **Run-end summary enhancement:**
   - Add a "Pipeline Decisions" section to `RUN_SUMMARY.json` listing every
     routing decision made and why.
   - Add "Time Breakdown" section with per-phase timings from Milestone 1.

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

If Milestone 5's structured memory proves insufficient for cross-run context
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
5. The real win is fewer, better-targeted agent calls (Milestone 4)

---

## Implementation Order & Dependencies

```
M1: Instrumentation ──────────────────────────────┐
                                                   │
M2: Intra-Run Cache ──┐                           │
                      ├──▶ M4: Reduce Agents ─────┤
M3: Detection Cache ──┘                           │
                                                   ▼
                                          M5: Run Memory
                                                   │
                                                   ▼
                                          M6: Transparency
```

M1 should be first (measure before optimizing). M2 and M3 are independent and
can be done in parallel. M4 depends on M2/M3 for cache infrastructure. M5 and
M6 can proceed independently but benefit from M1's timing data.

---

## Estimated Impact

| Milestone | Agent Calls Saved | Wall Time Saved | Effort |
|-----------|-------------------|-----------------|--------|
| M1: Instrumentation | 0 | 0 (diagnostic) | Small |
| M2: Intra-Run Cache | 0 | 1-5s per run | Small |
| M3: Detection Cache | 0 | 0.5-2s per run | Small |
| M4: Reduce Agents | 1-3 per run | 2-10 min per run | Medium |
| M5: Run Memory | 0-1 (better context) | Indirect (fewer reworks) | Medium |
| M6: Transparency | 0 | 0 (diagnostic) | Small |

**M4 is the high-impact milestone.** Eliminating even one agent call per run
saves more time than all other optimizations combined.
