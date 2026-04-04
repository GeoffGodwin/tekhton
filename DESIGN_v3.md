# Tekhton 3.0 — Intelligent Indexing, Milestone DAG & Pipeline Quality Design Document

> **Status: Complete** — All 51 milestones delivered. V3 branch merged April 2026.

## Problem Statement

Tekhton 2.0 delivered adaptive pipeline behavior: context accounting, milestone
state machines, auto-advance, clarification protocols, specialist reviewers, and
run metrics. However, two fundamental scaling problems remain.

**Context waste from milestones.** All milestone definitions live inline in
CLAUDE.md. A project with 8 milestones loses ~25k characters (48% of the file) to
milestone definitions that agents don't need — they only need the CURRENT milestone.
Completed milestones are archived, but FUTURE milestones that aren't immediately
relevant still bloat the prompt on every agent invocation. Adding more milestones
(parallelization, security agents, UI) makes this worse linearly.

**Context waste from architecture.** Agents receive the full ARCHITECTURE.md and
a large Repository Layout section regardless of what files they're actually touching.
A coder working on `lib/agent.sh` doesn't need the signatures of `tools/repo_map.py`.
There is no mechanism to rank or filter codebase context by task relevance.

Tekhton 3.0 addresses both: a **Milestone DAG** with a sliding context window for
the first problem, and **intelligent indexing** (tree-sitter repo maps + optional
LSP) for the second.

## Design Philosophy

1. **Files are the unit of work.** Each milestone is a standalone `.md` file. The
   manifest tracks the DAG; the file carries the full specification. This enables
   git-level change tracking per milestone and clean parallel execution in the future.

2. **Character budgets, not fixed counts.** The sliding window fills milestone
   context greedily until a character budget is exhausted, not by including a fixed
   number of milestones. Projects with lean CLAUDE.md files get more milestone
   context; heavy ones get less. This naturally adapts.

3. **Rank, don't truncate.** The repo map uses PageRank to surface the most
   task-relevant files. When the token budget is tight, low-ranked files are
   omitted — not arbitrarily truncated. Quality degrades gracefully.

4. **Shell crawls, agent synthesizes.** Indexing infrastructure (tree-sitter
   parsing, graph building) runs as a Python subprocess. The shell orchestrates
   invocation, budget enforcement, and stage-specific slicing. No Python process
   holds state across stages.

5. **Backward compatible.** All 2.0 workflows work unchanged. DAG features are
   auto-detected (manifest exists → use it; no manifest → inline CLAUDE.md
   parsing). Indexer features are opt-in via `REPO_MAP_ENABLED`.

6. **Parallel-ready data model.** DAG edges, parallel groups, and dependency
   tracking exist from day one. The data structures support future parallel
   execution without modification, even though we don't build the execution
   engine yet.

## Target User

Same as 2.0, plus:
- Users with large milestone plans (10+ milestones) where context waste matters
- Users working on large codebases where full architecture injection is wasteful
- Teams planning to use Tekhton's future parallel execution capabilities

## Current Architecture (2.0 Baseline)

Milestones are stored inline in CLAUDE.md as `#### Milestone N: Title` headings.
`parse_milestones()` extracts them to `NUMBER|TITLE|ACCEPTANCE_CRITERIA` format.
The entire CLAUDE.md is available to agents at every stage. Milestone operations
(advance, mark done, split, archive) all manipulate blocks within CLAUDE.md using
`_extract_milestone_block()` and `_replace_milestone_block()`.

Context injection is assembled per-stage in `stages/coder.sh` (and similar) by
concatenating shell variables (`ARCHITECTURE_BLOCK`, `MILESTONE_BLOCK`, etc.) into
prompt templates. The context budget system (`lib/context.sh`) measures and logs
component sizes but has no mechanism to selectively include or exclude milestone
content.

Architecture context comes from reading the full `ARCHITECTURE.md` file into
`ARCHITECTURE_CONTENT`. There is no ranking, filtering, or task-relevance scoring.

---

## System Design: Milestone DAG Infrastructure

### Problem

Milestones are strictly sequential and fully embedded in CLAUDE.md. There is no
mechanism to express dependency relationships (milestone B depends on A and C),
no way to identify which milestones could run in parallel, and no path toward
DAG-based parallel execution. Every milestone definition consumes context on every
agent invocation regardless of relevance.

### Design

**Directory structure:**
```
<project>/.claude/milestones/
    MANIFEST.cfg              # DAG definition (pipe-delimited)
    m01-dag-infrastructure.md # Full milestone specification
    m02-sliding-window.md
    m03-indexer-infra.md
    ...
```

**Manifest format** (`MANIFEST.cfg`):
```
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|DAG Infrastructure|pending||m01-dag-infra.md|foundation
m02|Sliding Window|pending|m01|m02-sliding-window.md|foundation
m03|Indexer Infra|pending|m02|m03-indexer-infra.md|indexing
```

Fields:
- `id` — stable short identifier (`m01`, `m02`). Never renumbered on insert.
- `title` — human-readable name
- `status` — `pending`, `active`, `done`, `skipped`
- `depends_on` — comma-separated milestone IDs (empty = no dependencies)
- `file` — filename within `.claude/milestones/`
- `parallel_group` — advisory label for future parallel execution batching

One line per milestone. Comments (`#`) and blank lines allowed. Parseable with
`IFS='|' read -r id title status deps file group`.

**Milestone files** contain the full specification: description, files to
create/modify, acceptance criteria, watch for, seeds forward. Identical structure
to current inline `#### Milestone N:` headings.

**Core module** (`lib/milestone_dag.sh`):

Data structures — parallel bash arrays with associative index:
```bash
declare -a _DAG_IDS=() _DAG_TITLES=() _DAG_STATUSES=()
declare -a _DAG_DEPS=() _DAG_FILES=() _DAG_GROUPS=()
declare -A _DAG_IDX=()   # _DAG_IDX[id]=array_index for O(1) lookup
```

Functions:
- `load_manifest(path)` — parse MANIFEST.cfg into arrays, return 0 if valid
- `save_manifest(path)` — atomic write (tmpfile + mv) of arrays to MANIFEST.cfg
- `has_milestone_manifest()` — return 0 if MANIFEST.cfg exists and is non-empty
- `dag_get_status(id)` / `dag_set_status(id, status)` — read/write status
- `dag_get_file(id)` / `dag_get_title(id)` / `dag_get_deps(id)` — field accessors
- `dag_deps_satisfied(id)` — return 0 if all deps have status=done
- `dag_get_frontier()` — space-separated IDs: pending milestones with all deps done
- `dag_get_active()` — return ID of the active milestone (or empty)
- `dag_find_next([current_id])` — next milestone to execute (active > frontier)
- `dag_id_to_number(id)` / `dag_number_to_id(number)` — conversion for display
- `validate_manifest()` — check dep references exist, detect cycles (DFS with
  visited set), verify files exist, exactly 0-1 active milestones

**Migration module** (`lib/milestone_dag_migrate.sh`):

- `migrate_inline_milestones(claude_md, milestone_dir)` — extract all inline
  milestones from CLAUDE.md into individual files, generate MANIFEST.cfg.
  Uses existing `_extract_milestone_block()` for block extraction.
  Dependencies inferred from sequential order (each depends on previous) unless
  explicit "depends on Milestone N" references found in text.
  File naming: `m{NN}-{slugified-title}.md`
- `_slugify(title)` — convert title to filename-safe slug

**Dual-path wrapper** (`lib/milestones.sh`):

`parse_milestones_auto(claude_md)` — if manifest exists, return milestone data
from it in the SAME `NUMBER|TITLE|ACCEPTANCE_CRITERIA` format as
`parse_milestones()`. Otherwise, fall back to `parse_milestones()`. All
downstream consumers (`get_milestone_count`, `get_milestone_title`,
`find_next_milestone`, `check_milestone_acceptance`) work unchanged.

**Adapted operations** (milestone_ops.sh, milestone_archival.sh,
milestone_split.sh, milestone_metadata.sh):

Each gains a DAG-aware code path guarded by `has_milestone_manifest()`:
- `mark_milestone_done()` → also calls `dag_set_status(id, "done")` + `save_manifest()`
- `find_next_milestone()` → calls `dag_find_next()` instead of sequential scan
- `archive_completed_milestone()` → reads file directly, appends to archive
- `split_milestone()` → writes sub-milestone files + manifest rows
- `emit_milestone_metadata()` → writes into milestone file instead of CLAUDE.md

### Config Keys

```bash
MILESTONE_DAG_ENABLED=true          # Use manifest+files vs inline CLAUDE.md
MILESTONE_DIR=".claude/milestones"  # Directory for milestone files
MILESTONE_MANIFEST="MANIFEST.cfg"   # Manifest filename within MILESTONE_DIR
MILESTONE_AUTO_MIGRATE=true         # Auto-extract inline milestones on first run
```

### Why This Design

- Pipe-delimited manifests are trivially parseable in bash with `IFS='|' read`.
  No jq, no Python, no new dependencies.
- Individual files enable git-level change tracking per milestone and clean diffs.
- The parallel-arrays + associative-index data structure is the standard bash 4+
  pattern for structured data (matching `_CONF_KEYS_SET` patterns in config.sh).
- Auto-migration means zero manual work for existing projects.
- The DAG data model costs nothing to store but enables future parallel execution.

---

## System Design: Milestone Sliding Window

### Problem

The `MILESTONE_BLOCK` variable injected into agent prompts is currently a static
4-line instruction string. The agent's actual milestone context comes from reading
the full CLAUDE.md, which contains ALL milestone definitions. There is no mechanism
to selectively inject only the relevant milestones.

### Design

**Window assembly** (`lib/milestone_window.sh`):

`build_milestone_window(model)` assembles a character-budgeted milestone context
block from the manifest. Priority order:

1. **Active milestone** (status=active) — full file content, always included
2. **Frontier milestones** (deps satisfied, pending) — first paragraph +
   acceptance criteria
3. **On-deck milestones** (one unsatisfied dep from frontier) — title +
   one-line description only

The window fills greedily, stopping when the character budget is exhausted.

**Budget calculation:**
```
available = (CONTEXT_BUDGET_PCT / 100 * model_window * CHARS_PER_TOKEN) - claude_md_base_chars
milestone_budget = min(available * MILESTONE_WINDOW_PCT / 100, MILESTONE_WINDOW_MAX_CHARS)
```

**Output format** (stored in `MILESTONE_BLOCK` template variable):
```markdown
## Milestone Mode — Active Milestone

### Milestone 3: Indexer Infrastructure
[full content of m03-indexer-infra.md]

---

## Upcoming Milestones (context only — do NOT implement)

### Milestone 4: Tree-Sitter Repo Map (frontier)
[first paragraph + acceptance criteria]

### Milestone 5: Pipeline Integration (on-deck)
[title + one-line description]
```

**Integration points:**
- `stages/coder.sh` — calls `build_milestone_window()` when manifest exists
- No prompt template changes — `MILESTONE_BLOCK` variable already exists
- Context accounting via `_add_context_component()` registration

**Plan generation integration** (`stages/plan_generate.sh`):

After the agent produces CLAUDE.md content (which includes inline milestones),
the shell post-processes:
1. Extract milestone blocks using `parse_milestones()`
2. Write each to an individual file in `.claude/milestones/`
3. Generate MANIFEST.cfg
4. Remove milestone blocks from CLAUDE.md, insert pointer comment

The agent's prompt and expected output format are unchanged.

**Auto-migration** at startup (`tekhton.sh`):

If `MILESTONE_DAG_ENABLED=true` and `MILESTONE_AUTO_MIGRATE=true` and no manifest
exists but inline milestones are detected in CLAUDE.md, automatically run
`migrate_inline_milestones()`.

### Config Keys

```bash
MILESTONE_WINDOW_PCT=30             # % of context budget for milestones
MILESTONE_WINDOW_MAX_CHARS=20000    # Hard cap on window chars
```

### Why This Design

- Character budgeting integrates with the existing context accounting system
  from v2 (CONTEXT_BUDGET_PCT, CHARS_PER_TOKEN).
- Greedy filling with priority ordering ensures the most important milestone
  (the active one) always gets full content, with diminishing detail for
  less-relevant milestones.
- The agent continues to generate monolithic CLAUDE.md during `--plan` — the
  shell handles the extraction. This avoids changing agent prompts or training
  agents on a new output format.

---

## System Design: Tree-Sitter Repo Map Generator

### Problem

Agents receive the full ARCHITECTURE.md and Repository Layout regardless of
task relevance. A coder modifying two files gets the signatures of every file
in the project. This wastes tokens and dilutes signal with noise.

### Design

See CLAUDE.md Milestones 3-8 for the detailed indexer design. Summary:

**Repo map pipeline:**
1. Tree-sitter parses source files → extracts definition/reference tags
2. File-relationship graph built from cross-references
3. PageRank with task-keyword personalization ranks files
4. Token-budgeted output emits only ranked signatures (no bodies)

**Stage-specific slicing:**
- Scout: full ranked map
- Coder: task-relevant slice (scout-identified files + dependencies)
- Reviewer: changed files + reverse dependencies (callers)
- Tester: changed files + test file counterparts

**Optional LSP enrichment** (Serena MCP):
Agents gain `find_symbol`, `find_referencing_symbols` tools for live,
accurate cross-reference queries supplementing the static repo map.

**Cross-run persistence:**
Tag cache (mtime-based invalidation), task→file history (JSONL),
personalization blending (keyword 0.6, history 0.3, recency 0.1).

### Config Keys

```bash
REPO_MAP_ENABLED=false              # Enable tree-sitter repo map
REPO_MAP_TOKEN_BUDGET=2048          # Max tokens for map output
REPO_MAP_CACHE_DIR=".claude/index"  # Index cache directory
REPO_MAP_LANGUAGES="auto"           # Languages to index (or "auto")
REPO_MAP_HISTORY_ENABLED=true       # Track task→file associations
REPO_MAP_HISTORY_MAX_RECORDS=200    # Max history entries
SERENA_ENABLED=false                # Enable Serena LSP via MCP
SERENA_PATH=".claude/serena"        # Serena installation directory
SERENA_CONFIG_PATH=""               # Generated MCP config path
SERENA_LANGUAGE_SERVERS="auto"      # LSP servers (or "auto")
SERENA_STARTUP_TIMEOUT=30           # Seconds to wait for startup
SERENA_MAX_RETRIES=2                # Health check retry attempts
```

---

## Scope Boundaries

### In Scope (3.0)
- Milestone DAG with manifest + individual files
- Character-budgeted sliding window
- Auto-migration from inline CLAUDE.md milestones
- Plan generation producing milestone files + manifest
- Tree-sitter repo map generator with PageRank ranking
- Stage-specific repo map slicing
- Optional Serena LSP integration via MCP
- Cross-run tag cache and task→file history
- Security agent with severity-gated rework + escalation policy
- Task intake / PM agent with clarity evaluation + auto-tweaking
- AI artifact detection with archive/merge/tidy workflow
- Brownfield deep analysis (workspaces, services, CI/CD, IaC, doc quality)
- Watchtower dashboard (static HTML, 4-tab interface, auto-refresh)
- UI / dashboard for pipeline transparency and milestone progress
- Express mode (zero-config execution with auto-detection)
- Configurable pipeline order with TDD test-first support
- Project health scoring with belt system
- Autonomous runtime improvements (quota-aware, milestone reset)
- Pipeline diagnostics and recovery guidance
- Test integrity audit (6-point rubric)
- Version migration framework with watermarking
- Distribution with install script and update checking
- Documentation site (MkDocs + GitHub Pages)
- DevX improvements: init UX, dry-run, rollback, human notes CLI

### Out of Scope (Future / V4)
- Parallel milestone execution (multiple agent teams in worktrees)
- Dedicated tech debt agent (background worker on own git branch)
- Semantic similarity for task→file matching (vs keyword-based)
- Environment awareness (API discovery, MCP detection, container execution)
- Containerized pipeline execution with permission levels

### Stretch
- Repository Layout section compression when repo map is active
- Automatic `parallel_group` inference from file overlap analysis

---

## New Files Summary

**lib/ (shell orchestration):**
- `milestone_dag.sh` — DAG infrastructure (manifest parse, queries, validation)
- `milestone_dag_migrate.sh` — inline→file migration
- `milestone_window.sh` — sliding window assembly
- `indexer.sh` — repo map orchestration + Python tool invocation
- `mcp.sh` — MCP server lifecycle management (Serena)

**tools/ (Python, optional dependency):**
- `repo_map.py` — tree-sitter parser + PageRank ranker
- `tag_cache.py` — disk-based tag cache
- `tree_sitter_languages.py` — language detection + grammar loading
- `requirements.txt` — pinned Python dependencies
- `setup_indexer.sh` — indexer virtualenv setup
- `setup_serena.sh` — Serena MCP server setup
- `serena_config_template.json` — MCP config template

**tests/:**
- `test_milestone_dag.sh` — DAG parsing, queries, cycle detection, migration
- `test_milestone_window.sh` — budget calculation, priority ordering

## Modified Files Summary

- `lib/milestones.sh` — add `parse_milestones_auto()` dual-path wrapper
- `lib/milestone_ops.sh` — DAG-aware `find_next_milestone()`, `mark_milestone_done()`
- `lib/milestone_archival.sh` — file-based archival path
- `lib/milestone_split.sh` — file-based splitting path
- `lib/milestone_metadata.sh` — metadata in milestone files
- `lib/config_defaults.sh` — new config keys + clamps
- `lib/config.sh` — MILESTONE_DIR path resolution
- `lib/context.sh` — repo map as named context component
- `stages/coder.sh` — milestone window + repo map injection
- `stages/review.sh` — repo map slice injection
- `stages/tester.sh` — repo map slice injection
- `stages/plan_generate.sh` — milestone file extraction post-processing
- `lib/orchestrate_helpers.sh` — DAG-aware auto-advance
- `tekhton.sh` — source new modules, DAG init, auto-migration, setup commands
- `templates/pipeline.conf.example` — new config sections
- `prompts/coder.prompt.md` — repo map + Serena conditional blocks
- `prompts/reviewer.prompt.md` — repo map conditional block
- `prompts/tester.prompt.md` — repo map conditional block
- `prompts/scout.prompt.md` — repo map conditional block
- `prompts/architect.prompt.md` — repo map conditional block

## Backward Compatibility

| Feature | Default | Opt-in Mechanism |
|---------|---------|-----------------|
| Milestone DAG | on (auto-detect) | MILESTONE_DAG_ENABLED=false to disable |
| Sliding window | on when DAG active | MILESTONE_WINDOW_PCT / MAX_CHARS |
| Auto-migration | on | MILESTONE_AUTO_MIGRATE=false to disable |
| Repo map | off | REPO_MAP_ENABLED=true |
| Serena LSP | off | SERENA_ENABLED=true |
| Cross-run cache | on when repo map on | REPO_MAP_HISTORY_ENABLED=false |
| Security agent | **on** | SECURITY_AGENT_ENABLED=false to disable |
| Task intake/PM | **on** | INTAKE_AGENT_ENABLED=false to disable |
| AI artifact detection | on | ARTIFACT_DETECTION_ENABLED=false |
| Workspace detection | on | DETECT_WORKSPACES_ENABLED=false |
| CI/CD inference | on | DETECT_CI_ENABLED=false |
| Doc quality assessment | on | DOC_QUALITY_ASSESSMENT_ENABLED=false |
| Express mode | **on** | TEKHTON_EXPRESS_ENABLED=false to require --init |
| Pipeline order (TDD) | standard | PIPELINE_ORDER=test_first for TDD |
| Dry-run cache | on | DRY_RUN_CACHE_TTL (default 3600s) |
| Run checkpoint | **on** | CHECKPOINT_ENABLED=false to disable |
| Health scoring | **on** | HEALTH_ENABLED=false to disable |
| Health re-assess | off | HEALTH_REASSESS_ON_COMPLETE=true |
| Quota pause/resume | **on** (Tier 1) | Always active (reactive detection) |
| Quota proactive | off | CLAUDE_QUOTA_CHECK_CMD to enable |
| Loop counter reset | **on** | Built into orchestration logic |
| Pipeline diagnostics | **on** | --diagnose always available |

---

## System Design: Security Agent (M09)

### Problem

Tekhton 2.0 has no dedicated security review. The reviewer catches vulnerabilities
opportunistically, but security is not its focus. Codebases handling auth, PII,
payments, or infrastructure need a purpose-built security stage. Additionally,
some vulnerabilities (e.g., a library that became CVE-listed that morning) are
unfixable in the moment and should not stop the pipeline — they should be escalated
to a human with appropriate severity context.

### Design

**Pipeline placement (serial, V4-parallel-ready):**
```
Scout → Coder → Build Gate → Security Agent → Reviewer → Tester
                                  ↑
                     security rework loop (bounded)
```

The security agent runs after the build gate, before the reviewer. This is serial
in V3; the data model and report format are designed so that V4 can transition to
parallel execution alongside the reviewer with merged findings.

**Severity-gated rework loop:**

```
Security scan → classify findings
  ├─ CRITICAL/HIGH + fixable=yes → coder rework → build gate → re-scan
  │                                (max SECURITY_MAX_REWORK_CYCLES)
  ├─ CRITICAL/HIGH + fixable=no  → SECURITY_UNFIXABLE_POLICY:
  │                                  escalate → HUMAN_ACTION_REQUIRED.md + continue
  │                                  halt → pipeline exit
  │                                  waiver → SECURITY_NOTES.md + continue
  ├─ MEDIUM/LOW → SECURITY_NOTES.md (reviewer context, never triggers rework)
  └─ Clean → proceed to reviewer
```

**Fast-path skip:** Docs-only, config-only, or asset-only changes skip the
security scan entirely. Determined by parsing CODER_SUMMARY.md file types.

**Knowledge base (dual-mode):**
- **Offline:** Static rules in the security role file (~200 lines covering OWASP
  Top 10, injection, auth, secrets, crypto misuse). Always available.
- **Online:** When SECURITY_ONLINE_SOURCES is configured and connectivity detected,
  cross-reference CVE databases (Snyk, NVD, GHSA). Graceful fallback to offline.
- **Waivers:** Optional SECURITY_WAIVER_FILE for pre-approved CVE/pattern exclusions.

**Report format (SECURITY_REPORT.md):**
Each finding: severity, category (OWASP ID), file:line, description, fixable flag,
suggested fix. Machine-parseable by the shell for rework routing.

**Downstream injection:**
- Reviewer sees SECURITY_FINDINGS_BLOCK (unfixed items as context)
- Tester sees SECURITY_FIXES_BLOCK (applied fixes to test)

### Config Keys

```bash
SECURITY_AGENT_ENABLED=true              # Opt-out (default ON)
CLAUDE_SECURITY_MODEL=${CLAUDE_STANDARD_MODEL}
SECURITY_MAX_TURNS=15
SECURITY_MIN_TURNS=8
SECURITY_MAX_TURNS_CAP=30
MILESTONE_SECURITY_MAX_TURNS=$(( SECURITY_MAX_TURNS * 2 ))
SECURITY_MAX_REWORK_CYCLES=2
SECURITY_BLOCK_SEVERITY=HIGH             # Minimum severity triggering rework
SECURITY_UNFIXABLE_POLICY=escalate       # escalate | halt | waiver
SECURITY_OFFLINE_MODE=auto               # auto | offline | online
SECURITY_ONLINE_SOURCES=""               # snyk, nvd, ghsa (optional)
SECURITY_ROLE_FILE=.claude/agents/security.md
SECURITY_NOTES_FILE=SECURITY_NOTES.md
SECURITY_REPORT_FILE=SECURITY_REPORT.md
SECURITY_WAIVER_FILE=""                  # Pre-approved waivers (optional)
```

### Why This Design

- Opt-out model ("401k principle"): users who don't know this exists get security
  by default. Conscious opt-out required to disable.
- Severity gating prevents the "infinite rejection loop" problem — only fixable
  CRITICAL/HIGH items trigger rework, and the loop is bounded.
- The unfixable policy (escalate/halt/waiver) lets users configure their risk
  tolerance. A startup iterating fast sets `waiver`; a fintech sets `halt`.
- Dual-mode knowledge base works offline (no internet = no excuse for no security)
  while benefiting from live data when available.
- Serial placement in V3 avoids the complexity of parallel execution but the
  report format is parallel-ready for V4.

---

## System Design: Task Intake / PM Agent (M10)

### Problem

Tekhton 2.0 requires a senior developer who can write precise tasks with acceptance
criteria, file paths, and clear scope boundaries. This locks out users who have
ideas and understand what they want but can't express it in the formal structure
Tekhton expects. Vague tasks lead to wasted pipeline runs, split failures, and
confused agents.

### Design

**Pipeline placement (pre-stage gate):**
```
Intake Gate → [Architect Audit] → Scout → Coder → Security → Reviewer → Tester
```

The intake agent runs once per milestone before the pipeline commits resources.
It is NOT a new CLI command — it's a pre-stage in the existing flow.

**Four verdicts:**

| Verdict | Condition | Action |
|---------|-----------|--------|
| PASS | Confidence ≥ INTAKE_TWEAK_THRESHOLD | Proceed immediately, no interaction |
| TWEAKED | Confidence between thresholds | Auto-tweak milestone, annotate with `[PM: ...]`, proceed |
| SPLIT_RECOMMENDED | Task too large | Present sub-milestones, pause for human approval |
| NEEDS_CLARITY | Confidence < INTAKE_CLARITY_THRESHOLD | Write questions to CLARIFICATIONS.md, pause |

**Clarity rubric (agent-evaluated):**
- Is the scope bounded? (Can a developer know when they're done?)
- Are acceptance criteria testable? (Can they be verified by a machine?)
- Are there implicit assumptions that need stating?
- Could two competent developers interpret this differently?

**Calibration philosophy:** The agent defaults to PASS. It is a helpful colleague,
not a bureaucratic gate. Prompt examples are heavily weighted toward PASS verdicts.
The thresholds (40/70) are starting points — metrics logging enables data-driven
calibration over time.

**Skip-on-resume:** The intake agent hashes milestone content (sha256sum) and
caches results in the session directory. Resumed runs don't re-evaluate unchanged
milestones.

**Non-milestone mode:** When the user passes a raw task string (no DAG), TWEAKED
verdicts update the TASK variable and persist the tweaked version to
`INTAKE_TWEAKED_TASK.md` in the session directory for resume safety.

### Config Keys

```bash
INTAKE_AGENT_ENABLED=true                # Opt-out (default ON)
CLAUDE_INTAKE_MODEL=opus                 # Judgement calls need the best model
INTAKE_MAX_TURNS=10                      # Fast evaluation, not coding
INTAKE_CLARITY_THRESHOLD=40              # Below → NEEDS_CLARITY
INTAKE_TWEAK_THRESHOLD=70                # Below (but above clarity) → TWEAKED
INTAKE_CONFIRM_TWEAKS=false              # Pause for human review of tweaks?
INTAKE_AUTO_SPLIT=false                  # Auto-add recommended splits to DAG?
INTAKE_ROLE_FILE=.claude/agents/intake.md
INTAKE_REPORT_FILE=INTAKE_REPORT.md
```

### Why This Design

- Pre-stage (not pre-pipeline) means each milestone gets evaluated, including
  auto-advanced milestones in --complete mode.
- Four verdicts cover the full spectrum from "this is fine" to "I'm lost."
- Opus model default is intentional: this is a judgement call where model quality
  directly impacts user experience, and it runs once per milestone (bounded cost).
- Two separate thresholds (clarity/tweak) give users fine-grained control over
  gate aggressiveness without coupling the "I need help" and "this needs polish"
  decisions.
- Reusing existing infrastructure (clarification protocol, split_milestone,
  milestone file format) minimizes new code.

---

## System Design: Brownfield AI Artifact Detection (M11)

### Problem

Modern codebases frequently have AI tool configurations from multiple sources:
Cursor, Copilot, Aider, Cline, Continue, Windsurf, Roo, or even a prior Tekhton
installation. When a user runs `tekhton --init`, these existing configurations
are silently ignored or overwritten. This creates confusion when Tekhton's
generated config contradicts rules already in place from other tools, and wastes
valuable project knowledge that was captured in those configurations.

### Design

**Detection engine** (`lib/detect_ai_artifacts.sh`):

Scans for 10+ AI tool patterns at two levels:
- **Configuration level** (high confidence): `.cursor/`, `.cursorrules`,
  `.github/copilot/`, `.aider*`, `.cline/`, `.continue/`, `.windsurf/`,
  `.windsurfrules`, `.roomodes`, `.ai/`, existing `.claude/` + `CLAUDE.md`
- **Code level** (lower confidence): AI-generated comment patterns, verbose
  boilerplate JSDoc, agent-style directive language in ARCHITECTURE.md

Output: `TOOL|PATH|TYPE|CONFIDENCE` per artifact.

Special case: `.claude/` is scanned at file-level granularity (not directory-level)
to distinguish Tekhton artifacts (pipeline.conf, agents/) from Claude Code
artifacts (settings.json, commands/).

**Handling workflow** (`lib/artifact_handler.sh`):

Interactive menu per artifact group:
- **(A) Archive** — move to `.claude/archived-ai-config/` with manifest
- **(M) Merge** — agent-assisted content extraction into MERGE_CONTEXT.md.
  Conflicts marked with `[CONFLICT: ...]` for synthesis resolution.
- **(T) Tidy** — remove with confirmation + optional git commit + .gitignore cleanup
- **(I) Ignore** — leave in place with warning

Prior Tekhton installs get a specialized **Reinit** path preserving pipeline.conf.

Non-interactive mode: `ARTIFACT_HANDLING_DEFAULT=archive|tidy|ignore` for CI/headless.

**Merge pipeline:**
```
detect_ai_artifacts() → handle_ai_artifacts()
                            ├─ archive → move files
                            ├─ merge → agent → MERGE_CONTEXT.md
                            │                      ↓
                            │              synthesis pipeline
                            │              (consumes alongside PROJECT_INDEX.md)
                            ├─ tidy → remove + git commit
                            └─ ignore → warn + continue
```

### Why This Design

- Detection at two levels (config vs code) avoids false positives while catching
  the obvious cases with high confidence.
- Agent-assisted merge (not blind concat) understands both source and target
  formats, producing clean Tekhton-native output.
- The four options (A/M/T/I) cover all user preferences without forcing a choice.
- Granular `.claude/` scanning handles the shared-directory problem between
  Tekhton and Claude Code.

---

## System Design: Brownfield Deep Analysis (M12)

### Problem

The current `--init` detection heuristics work well for simple, single-project
repositories but struggle with complex brownfield codebases: monorepos with
workspaces, multi-service repos, polyglot stacks, and projects where the CI
pipeline is the authoritative source of truth for build/test commands (not the
manifest files).

### Design

**Three new detection engines:**

1. **Workspace detection** (`detect_workspaces()`): npm/yarn/pnpm workspaces,
   lerna, nx, Cargo workspaces, Go workspaces, Gradle multi-project, Maven
   multi-module. Per-subproject enumeration with configurable cap (default 50).

2. **Service detection** (`detect_services()`): docker-compose services, Procfile
   process types, Kubernetes manifests. Maps service → directory → tech stack.

3. **CI/CD inference** (`detect_ci_config()`): GitHub Actions, GitLab CI,
   CircleCI, Jenkinsfile, Bitbucket Pipelines, plus Dockerfiles for language
   version confirmation. CI-detected commands take highest confidence — they're
   what actually runs in production.

**Additional detections:**
- Infrastructure-as-code: Terraform, Pulumi, CDK, CloudFormation, Ansible
- Test frameworks: pytest, jest, vitest, mocha, etc. (separate from TEST_CMD)
- Linters and formatters: eslint, ruff, black, clippy, etc.
- Pre-commit hooks as authoritative lint/format source

**Command priority cascade:**
```
1. CI/CD config        (highest confidence — actually runs in prod)
2. Makefile / Taskfile
3. Package manager scripts
4. Convention fallback  (current behavior, lowest confidence)
```

**Documentation quality assessment** (`_assess_doc_quality()`):
- Scores 0-100 based on: README presence/depth, CONTRIBUTING.md, API docs,
  architecture docs, inline doc density
- Synthesis agent calibrates inference depth from score:
  - High (>70): trust and preserve existing docs
  - Low (<30): infer aggressively from code patterns

**Monorepo UX:** When workspaces detected, asks: "Manage root or specific
subproject?" Lists detected subprojects. Does NOT solve the full monorepo
problem — seeds forward to V4.

### Why This Design

- CI/CD is the highest-confidence source because it's tested and maintained by
  the team. Manifest heuristics can be stale.
- Doc quality scoring lets the synthesis agent adapt its behavior: well-documented
  projects get preservation, poorly-documented ones get generation.
- Infrastructure detection feeds directly into the security agent's context —
  Terraform misconfigs are a major vulnerability class.
- Test framework detection (separate from TEST_CMD) lets the tester agent write
  framework-appropriate test code.

---

## System Design: Watchtower Dashboard (M13-M14)

### Problem

Tekhton is a black box. The terminal scrolls colored output but users can't
answer basic questions: Is it stuck? What did it change? Should I be worried
about that security finding? How much is left? Is it getting better over time?
This opacity is acceptable for a senior dev who reads markdown files, but it's
a dealbreaker for the broader audience V3 targets.

### Design

**Architecture: static HTML + JS data files (no server)**

The pipeline writes `.js` data files that assign to `window.TK_*` globals.
A static HTML file loads them via `<script>` tags (works on `file://` because
`<script src>` same-directory is exempt from CORS). Auto-refresh via
`setTimeout(location.reload)` provides pseudo-polling.

```
Pipeline (shell)                    Browser
┌───────────────┐                 ┌──────────────────┐
│ emit_dashboard │─── writes ───▶ │ data/run_state.js │
│ _event()      │                 │ data/timeline.js  │
│ _run_state()  │                 │ data/milestones.js│
│ _milestones() │                 │ data/security.js  │
│ _security()   │                 │ data/reports.js   │
│ _reports()    │                 │ data/metrics.js   │
│ _metrics()    │                 ├──────────────────┤
└───────────────┘                 │ index.html        │◀── user opens
                                  │ app.js (renders)  │
                                  │ style.css         │
                                  └──────────────────┘
```

Zero server. Zero dependencies. Zero build tools. Open `index.html` in a browser.

**Four-tab interface:**

| Tab | Purpose | Data source |
|-----|---------|-------------|
| Live Run | What's happening right now | run_state.js, timeline.js |
| Milestone Map | DAG visualization, plan status | milestones.js |
| Reports | Stage-by-stage results, findings | reports.js, security.js |
| Trends | Historical efficiency, patterns | metrics.js |

**Interactivity model (V3):**
Read-only with helpful hints. When the pipeline is paused for human input
(NEEDS_CLARITY, security waiver), the dashboard shows the questions and provides
copy-to-clipboard file paths / commands. True bidirectional interaction (answer
questions in the browser) requires a server — V4.

**Responsive design:** Three breakpoints (1200px, 768px, <768px). The Live Run
tab is optimized for glanceability at small sizes (status badge + stage bar +
timeline). The Milestone Map degrades to a list at small sizes. The Trends tab
drops charts and shows summary stats only.

**Lifecycle:**
- Created by `tekhton --init` (DASHBOARD_ENABLED=true by default)
- Disabled via config: next run cleans up `.claude/dashboard/`
- Re-enabled via config: next run recreates it
- Static files (HTML/CSS/JS) are one-time copies from Tekhton templates
- Data files are regenerated on each meaningful pipeline event

**Verbosity levels** (DASHBOARD_VERBOSITY in config):
- `minimal`: stage completions + final verdicts only
- `normal` (default): stage transitions + verdicts + findings + build results
- `verbose`: all of normal + turn counts, rework events, context budget stats

### Config Keys

```bash
DASHBOARD_ENABLED=true              # Generate Watchtower dashboard
DASHBOARD_VERBOSITY=normal          # minimal | normal | verbose
DASHBOARD_HISTORY_DEPTH=50          # Runs to include in Trends tab
DASHBOARD_REFRESH_INTERVAL=5        # Seconds between auto-refreshes
DASHBOARD_DIR=".claude/dashboard"   # Dashboard output directory
```

### Why This Design

- Static files + JS globals is the simplest architecture that works without a
  server. The `<script src>` same-directory exemption from CORS makes it
  possible. No fetch(), no AJAX, no build step.
- Auto-refresh via page reload is crude but correct for V3. It reloads the data
  scripts, which is exactly what we need. V4's WebSocket push replaces this.
- Four tabs prevent clutter while covering the four questions users actually ask:
  "what's happening?", "what's the plan?", "what did it do?", "is it improving?"
- CSS-only swimlanes for the DAG avoid a JS graphing dependency. The DAG
  visualization upgrades to SVG with proper graph layout in V4.
- Dark theme default because this typically runs on a second monitor while the
  dev works in their IDE. Light theme available for preference.
- 50KB size constraint forces discipline. This is a utility, not a web app.

---

## System Design: Project Health Scoring (M15)

### Problem

Users adopting Tekhton on brownfield projects have no way to measure whether
Tekhton is actually improving their codebase. They invest time and API quota
but can't answer "Is my project better now?" with a number. For stakeholders
and team leads, this makes Tekhton an untestable proposition.

### Design

**Five-dimension health assessment:**

| Dimension | Weight | What it measures |
|-----------|--------|-----------------|
| Test health | 30% | Test file presence, framework, naming, pass rate (opt-in) |
| Code quality | 25% | Linter config, magic numbers, TODO density, function length, type safety |
| Dependency health | 15% | Lock files, vuln scanner config, version freshness |
| Documentation | 15% | README depth, contributing guide, API docs, inline density |
| Project hygiene | 15% | .gitignore, .env safety, CI/CD, changelog |

Composite score: weighted average (0-100). Weights configurable.

**Belt system** (optional, memorable):
White (0-19) → Yellow (20-39) → Orange (40-59) → Green (60-74) → Blue (75-89) → Black (90-100)

**Lifecycle:**
1. `--init` runs baseline → HEALTH_BASELINE.json
2. Health findings feed into synthesis (low test score → milestones prioritize tests)
3. PM agent sees health context (calibrates priorities)
4. `--health` for standalone re-assessment
5. Optional re-assessment on completion (HEALTH_REASSESS_ON_COMPLETE)
6. Watchtower Trends shows health trend line

**Critical constraint:** All checks are read-only. Never execute project code
unless HEALTH_RUN_TESTS=true (opt-in).

### Config Keys

```bash
HEALTH_ENABLED=true
HEALTH_REASSESS_ON_COMPLETE=false
HEALTH_RUN_TESTS=false
HEALTH_SAMPLE_SIZE=20
HEALTH_WEIGHT_TESTS=30
HEALTH_WEIGHT_QUALITY=25
HEALTH_WEIGHT_DEPS=15
HEALTH_WEIGHT_DOCS=15
HEALTH_WEIGHT_HYGIENE=15
```

### Why This Design

- Five dimensions cover what actually correlates with project maintainability.
- Read-only checks mean the assessment is always safe on untrusted repos.
- The belt system makes scores memorable: "We went from Yellow to Green Belt."
- Feeding health context into the PM agent creates a virtuous cycle.

---

## System Design: Autonomous Runtime Improvements (M16)

### Problem

The --complete outer loop punishes productive work. A pipeline that successfully
completes 4 milestones then fails once has used 4 of 5 attempts on successes.
Meanwhile, rate limits from the Claude CLI cause hard failures instead of
graceful pauses.

### Design

**1. Milestone success resets the outer loop counter**

```
Before:  Success → Success → Success → Fail → Fail → STOP (5 attempts)
After:   Success(0) → Success(0) → Success(0) → Fail(1) → Fail(2) → ...
```

Counter only counts consecutive no-progress cycles.

**2. Quota-aware pause/resume**

Tier 1 (Reactive — zero setup): Detect rate-limit errors from CLI output →
enter QUOTA_PAUSED → disable timeouts → probe every 5min → resume on success.

Tier 2 (Proactive — optional): `CLAUDE_QUOTA_CHECK_CMD` runs a user-provided
script that returns remaining percentage. Pause when below QUOTA_RESERVE_PCT.
No API keys in Tekhton — the user's script handles credentials.

**3. Increased safety limits:** MAX_AUTONOMOUS_AGENT_CALLS 20→200 (safety valve
only), MILESTONE_MAX_SPLIT_DEPTH 3→6 (PM agent catches bad splits).

### Config Keys

```bash
QUOTA_RETRY_INTERVAL=300
QUOTA_RESERVE_PCT=10
CLAUDE_QUOTA_CHECK_CMD=""
QUOTA_MAX_PAUSE_DURATION=14400
MAX_AUTONOMOUS_AGENT_CALLS=200
MILESTONE_MAX_SPLIT_DEPTH=6
```

### Why This Design

- Success-resets-counter is a tiny code change with transformative behavior.
  Productive pipelines run until they finish, not until a counter expires.
- Tier 1 quota handling requires zero configuration. Every user gets it.
- Tier 2 is a clean plugin interface. Tekhton never touches credentials.
- The 200 call limit is a true safety valve, not a workflow constraint.

---

## System Design: Pipeline Diagnostics & Recovery (M17)

### Problem

When a pipeline run fails, users are left staring at terminal output with no
guidance on what went wrong or how to fix it. The knowledge of "build failure →
fix and restart from coder" vs "review loop → increase cycles or fix manually"
is tribal knowledge that even the system's creator forgets between milestones.

### Design

**`tekhton --diagnose` command:**

Pure shell logic — no agent calls. Reads pipeline state files and applies a
priority-ordered ruleset to classify the failure and suggest recovery actions.

**10 diagnostic rules (priority-ordered):**

| Rule | Pattern | Key suggestion |
|------|---------|----------------|
| BUILD_FAILURE | BUILD_ERRORS.md non-empty | Fix manually or --start-at coder |
| REVIEW_REJECTION_LOOP | 3+ review cycles | Increase cycles or fix feedback manually |
| SECURITY_HALT | Security HALT verdict | Add waivers or change policy to escalate |
| INTAKE_NEEDS_CLARITY | Intake paused | Answer CLARIFICATIONS.md |
| QUOTA_EXHAUSTED | Rate limit detected | Wait for refresh (auto-resumes) |
| STUCK_LOOP | Max attempts, no progress | Simplify task or manual split |
| TURN_EXHAUSTION | Agent hit max turns | Increase turn budget or simplify scope |
| SPLIT_DEPTH | Max split depth reached | Manual breakdown needed |
| TRANSIENT_ERROR | Server errors | Re-run with --resume |
| UNKNOWN | No pattern matched | Check agent logs |

**Forward-compatible rule registry:** Rules for future stages (security, intake,
quota) check for the presence of relevant state files. If the stage hasn't been
implemented yet, the rule silently skips. New stages just need to write their
state files in expected locations — no --diagnose code changes needed.

**Auto-hint on failure:** Every failed run prints
"Run 'tekhton --diagnose' for recovery suggestions."

**Recurring failure detection:** If the same failure type occurred in the last
3 runs, the diagnosis notes the pattern and suggests escalating to manual
intervention.

**Output:** DIAGNOSIS.md (full report), terminal summary (colored, copy-pasteable
commands), dashboard data (data/diagnosis.js for Watchtower).

### Why This Design

- Zero agent calls means --diagnose is instant and free. No quota cost.
- Priority-ordered rules give the most specific diagnosis first (build failure
  beats generic stuck loop).
- Forward-compatible design means we never revisit this code when adding stages.
- Every suggestion includes an exact copy-pasteable command.

---

## Updated Pipeline Flow (V3 Complete)

```
tekhton --init
  ├─ AI artifact detection (M11)    ← NEW
  ├─ Tech stack detection
  ├─ Workspace/service/CI detection (M12)  ← NEW
  ├─ Project crawl → PROJECT_INDEX.md
  ├─ Health baseline assessment (M15) ← NEW
  ├─ Config generation (CI-informed)
  └─ Synthesis → DESIGN.md + CLAUDE.md + milestones/

tekhton "task" or tekhton --milestone
  ├─ Milestone DAG load (M01-M02)
  ├─ Quota check (M16, if Tier 2 configured) ← NEW
  ├─ Intake gate / PM agent (M10)    ← NEW
  ├─ [Architect audit]
  ├─ Scout + Coder + Build Gate
  ├─ Security scan + rework (M09)    ← NEW
  ├─ Reviewer + rework loop
  ├─ Tester + validation
  ├─ [Cleanup sweep]
  ├─ [Health re-assessment (M15, if enabled)] ← NEW
  └─ Milestone success → reset loop counter (M16) ← NEW
```

## Updated New Files Summary

**lib/ (shell orchestration):**
- `milestone_dag.sh` — DAG infrastructure (M01)
- `milestone_dag_migrate.sh` — inline→file migration (M01)
- `milestone_window.sh` — sliding window assembly (M02)
- `indexer.sh` — repo map orchestration (M03)
- `mcp.sh` — MCP server lifecycle management (M06)
- `detect_ai_artifacts.sh` — AI tool config detection (M11)
- `artifact_handler.sh` — artifact archive/merge/tidy workflow (M11)
- `express.sh` — zero-config detection + in-memory config (M26)
- `pipeline_order.sh` — configurable stage ordering + TDD support (M27)
- `dashboard.sh` — Watchtower data emission + lifecycle (M13)
- `dashboard_parsers.sh` — Report parsing for dashboard data (M13)
- `health.sh` — Health scoring engine + assessment lifecycle (M15)
- `health_checks.sh` — Individual dimension check functions (M15)
- `quota.sh` — Quota-aware pause/resume + rate limit detection (M16)
- `diagnose.sh` — Diagnostic engine + report generation (M17)
- `diagnose_rules.sh` — Forward-compatible diagnostic rule definitions (M17)

**stages/ (pipeline stages):**
- `security.sh` — security scan + rework routing (M09)
- `intake.sh` — task clarity evaluation + PM gate (M10)

**prompts/ (agent templates):**
- `security_scan.prompt.md` — security analysis prompt (M09)
- `security_rework.prompt.md` — security fix rework prompt (M09)
- `intake_scan.prompt.md` — clarity evaluation prompt (M10)
- `intake_tweak.prompt.md` — milestone refinement prompt (M10)
- `artifact_merge.prompt.md` — AI config merge prompt (M11)
- `tester_write_failing.prompt.md` — TDD pre-flight test prompt (M27)

**templates/ (copied to target projects):**
- `security.md` — security agent role definition (M09)
- `intake.md` — intake/PM agent role definition (M10)
- `express_pipeline.conf` — auto-generated config template (M26)

**lib/ (DevX improvements):**
- `init_report.sh` — Post-init focused summary + INIT_REPORT.md (M22)
- `init_config_sections.sh` — Sectioned config file generator (M22)
- `dry_run.sh` — Dry-run orchestration + cache management (M23)
- `checkpoint.sh` — Pre-run git checkpoint + rollback (M24)
- `notes_cli.sh` — CLI note management commands (M25)
- `report.sh` — CLI run report summary (M17 fold-in)

**completions/ (shell completion):**
- `tekhton.bash` — Bash completion (M19)
- `tekhton.zsh` — Zsh completion (M19)
- `tekhton.fish` — Fish completion (M19)

**templates/watchtower/ (static dashboard files):**
- `index.html` — Dashboard shell with 4-tab navigation (M14)
- `app.js` — Vanilla JS rendering logic (M14)
- `style.css` — Responsive dark/light theme styles (M14)

**tools/ (Python, optional dependency):**
- `repo_map.py` — tree-sitter parser + PageRank ranker (M04)
- `tag_cache.py` — disk-based tag cache (M04)
- `tree_sitter_languages.py` — language detection + grammar loading (M04)
- `requirements.txt` — pinned Python dependencies (M03)
- `setup_indexer.sh` — indexer virtualenv setup (M03)
- `setup_serena.sh` — Serena MCP server setup (M06)
- `serena_config_template.json` — MCP config template (M06)

## System Design: Developer Experience Improvements (M22-M25)

### Problem

Tekhton V2 was built by a senior developer for senior developers. V3 needs to
be accessible to a wider audience — people with ideas who don't know how to write
acceptance criteria, teams trying out Tekhton for the first time, and users who
need confidence that the pipeline is trustworthy before letting it loose on their
codebase. Four specific pain points:

1. **Post-init confusion.** After `--init`, users face an 80+ key config file
   with no guidance on what matters.
2. **No preview mode.** Users can't see what the pipeline WOULD do without
   committing turns. The scout is non-deterministic, so running and re-running
   may produce different results.
3. **No rollback.** If the pipeline writes bad code, the only recovery is
   manual git operations. New users may not be comfortable with this.
4. **Hidden notes system.** HUMAN_NOTES.md is powerful but undiscoverable.
   Manual markdown editing is a friction barrier.

### Design

**M22: Init UX Overhaul.** The post-init experience becomes a focused summary
showing what was detected, what needs attention, and numbered next steps. The
config file gets clear section headers (Essential → Models → Pipeline → Security
→ Features → Quotas) with `# VERIFY` markers on low-confidence detections. A
persistent INIT_REPORT.md feeds both the CLI and Watchtower.

**M23: Dry-Run & Preview.** `tekhton --dry-run` runs scout + intake only, shows
a preview, and caches results. The cache is keyed on task hash + git HEAD sha +
TTL (default 1 hour). The next actual run detects the cache and offers to continue
from it, ensuring the preview matches execution. Cache invalidates automatically
on code changes or task changes. This builds trust: see what it plans, approve,
then execute.

**M24: Run Safety Net.** Pre-run git checkpoint (stash uncommitted changes,
record HEAD sha). `--rollback` cleanly reverts: `git revert` for committed
changes (non-destructive, preserves history), `git stash pop` for pre-run state
restoration. Only the most recent run is rollback-able. Safety checks prevent
rollback when additional commits exist or when uncommitted changes would be lost.
Never uses `git reset --hard`.

**M25: Human Notes UX.** `tekhton note "Fix the bug" --tag BUG` adds a properly
formatted entry via CLI. `note --list`, `note --done`, `note --clear` for
management. Post-run display includes usage tips. Notes summary feeds Watchtower
and the PM agent.

### Fold-ins to Existing Milestones

In addition to the four new milestones, the DevX audit identified improvements
that fold naturally into existing planned milestones:

- **M10 (PM Agent):** `--add-milestone` command for adding single milestones
  to the DAG without running --replan
- **M13 (Watchtower Data):** Enhanced CLI progress heartbeat showing turn count
  in the agent spinner (e.g., "Coder (4m12s, 14/25 turns)")
- **M17 (Diagnostics):** `tekhton report` command for successful run summaries,
  smart crash handler with first-aid advice, context-rich resume prompt
- **M19 (Distribution):** Shell completion (bash/zsh/fish), grouped help text,
  changelog in update notifications

### Why V3, Not V4

These improvements directly address the V3 goal of accessibility. Every hour
a new user spends confused by config, scared to run the pipeline, or unable to
undo a bad result is an hour that erodes trust. The safety net and preview mode
are especially critical for beta users — they need to trust Tekhton before they
can recommend it.

---

## System Design: Express Mode / Zero-Config Execution (M26)

### Problem

Tekhton requires `--init` before it can do anything. That's 4 steps (install →
init → configure → run) before a developer sees value. Superpowers and similar
tools let you start immediately. For evaluation, one-off tasks, and quick fixes,
the configuration ceremony is a barrier to adoption.

### Design

**Three-tier onboarding:**

| Tier | Entry point | Time to first run | Depth |
|------|-------------|-------------------|-------|
| Tier 0: Express | `tekhton "task"` (no init) | ~5 seconds | Auto-detected defaults |
| Tier 1: Quick init | `tekhton --init --quick` | ~15 seconds | Detection + confirm |
| Tier 2: Full init | `tekhton --init` | ~10 minutes | Interview + synthesis |

**Express mode flow:**
```
tekhton "Add login page" (no pipeline.conf exists)
  ├─ Detect: "No config found. Running Express Mode."
  ├─ Fast detection (<3s): language, build cmd, test cmd, project name
  ├─ Generate in-memory config with conservative defaults
  ├─ Run normal pipeline (scout → coder → security → review → test)
  └─ On success: persist .claude/pipeline.conf with detected values
```

**Key constraints:**
- Express detection is a FAST SUBSET of M12's full detection engine. No workspace
  detection, no CI/CD parsing, no doc quality assessment. Those are --init features.
- Agent role files fall back to built-in templates from `$TEKHTON_HOME/templates/`
  when project-local files don't exist.
- Express mode is fully resumable (state saved same as configured mode).
- Config persistence is opt-out (EXPRESS_PERSIST_CONFIG=false for ephemeral mode).

### Config Keys

```bash
TEKHTON_EXPRESS_ENABLED=true     # Allow zero-config execution
EXPRESS_PERSIST_CONFIG=true      # Write config on successful completion
EXPRESS_PERSIST_ROLES=false      # Don't copy role files (use built-in templates)
```

### Why This Design

- The "Docker run" analogy: `docker run nginx` works without a Dockerfile. Then you
  write a Dockerfile when you want to customize. Express mode is Tekhton's equivalent.
- Conservative defaults mean express mode is safe — Sonnet model, security ON, intake
  ON, standard turn limits. It won't burn quota or skip safety.
- Persisting config on completion means the second run is faster and customizable.
- The fallback to built-in role templates requires exactly one code change (role file
  resolution) and works for all agent types.

---

## System Design: Configurable Pipeline Order / TDD Support (M27)

### Problem

Tekhton's stage order is hardcoded: Scout → Coder → Security → Review → Test.
This is optimal for feature development (unknown API surface), but suboptimal for
bug fixes (known interface) where TDD's test-first approach produces better results
with fewer rework cycles.

### Design

**Pipeline order as config:**

```bash
PIPELINE_ORDER=standard      # Scout → Coder → Security → Review → Test
PIPELINE_ORDER=test_first    # Scout → Test(fail) → Coder → Security → Review → Test(verify)
PIPELINE_ORDER=auto          # V4: PM agent decides per-milestone
```

**Test-first flow:**
```
Scout → Tester (write_failing) → Coder → Build Gate → Security → Review → Tester (verify_passing)
```

The tester runs twice with different modes:
1. **write_failing**: Write tests against acceptance criteria that SHOULD FAIL.
   Output: TESTER_PREFLIGHT.md with test files and expected failures.
2. **verify_passing**: Normal test pass (existing behavior). Verify the coder's
   implementation makes all tests pass.

The coder sees TESTER_PREFLIGHT.md as context: "Make these tests pass."

**When test-first wins vs loses:**

| Scenario | Best order | Why |
|----------|-----------|-----|
| Bug fix (known interface) | test_first | Test encodes expected behavior, coder fixes |
| New feature (unknown API) | standard | Tester can't predict the interface |
| Refactoring | standard | Tests test existing behavior, not new |
| Adding to existing module | test_first | Interface exists, test contracts are clear |

### Config Keys

```bash
PIPELINE_ORDER=standard                  # standard | test_first | auto (V4)
TDD_PREFLIGHT_FILE=TESTER_PREFLIGHT.md  # Pre-flight test output
TESTER_WRITE_FAILING_MAX_TURNS=10       # Budget for test-write pass
```

### Why This Design

- Config-driven ordering (not hardcoded) sets the foundation for V4's `auto` mode
  where the PM agent chooses per-milestone.
- Two tester invocations is the simplest implementation: same stage function, different
  mode variable, different prompt. No new stage infrastructure needed.
- The coder seeing TESTER_PREFLIGHT.md gives it a clear "done" signal — all tests pass
  = done. This reduces scope creep and over-engineering.
- test_first costs more (two tester passes) but produces more targeted code. The
  trade-off is explicit in the config comments so users make an informed choice.

---

## System Design: UI/UX Design Intelligence (M57–M60)

### Problem Statement

Tekhton produces high-quality non-visual code but leaves significant quality gaps
when building user interfaces. Testing across greenfield and brownfield projects
with visual components reveals a consistent pattern: the pipeline treats UI
implementation identically to backend work. The coder receives zero design guidance,
the reviewer checks four behavioral bullets (CSS class references, E2E coverage,
event handlers, aria attributes), and quality judgment is limited to "does it load
without crashing?"

The root causes are structural:

1. **The coder is design-blind.** `coder.prompt.md` contains no `{{IF:UI_PROJECT_DETECTED}}`
   block. A coder building a React dashboard gets the same prompt as one writing a
   database migration — no component structure guidance, no design system awareness,
   no accessibility mandates, no responsive patterns.

2. **No design system awareness.** Detection identifies testing frameworks (Playwright,
   Cypress) and UI frameworks (React, Vue) but not design systems (Tailwind, MUI,
   shadcn, Flutter ThemeData, SwiftUI environment values). The coder cannot know
   "this project uses Tailwind with a custom theme config" so it invents bespoke
   styles instead of using what exists.

3. **No specialist for visual/UX concerns.** Security, performance, and API each
   get a dedicated specialist with an 8-category checklist and `[BLOCKER]`/`[NOTE]`
   output. UI/UX gets 4 bullets in the reviewer prompt — no dedicated review pass,
   no structured findings, no rework routing for accessibility violations or broken
   responsive layouts.

4. **Platform blindness.** The existing UI detection is web-centric (scans for
   `package.json` deps, `.tsx`/`.vue` files, CSS modules). Flutter apps, SwiftUI
   apps, Jetpack Compose projects, and game engine projects all produce visual
   interfaces but share almost nothing in terms of design conventions, component
   patterns, or testing approaches. A single hardcoded set of UI guidance cannot
   cover this spectrum.

### Design Philosophy

1. **Platform adapters, not hardcoded guidance.** UI knowledge is organized into
   platform-specific directories. Each platform provides detection, coder guidance,
   review criteria, and tester patterns. Adding a new platform means adding files
   to a directory, not editing core pipeline code.

2. **Enrich existing agents, don't fork them.** The coder gets richer context via
   prompt injection — no "UI coder" variant. The specialist framework handles
   review depth. No new pipeline stages.

3. **Universal principles with platform-specific expression.** State presentation
   (loading/error/empty), accessibility, component composition, and responsive/adaptive
   layout are universal. How they manifest (CSS media queries vs. Flutter LayoutBuilder
   vs. SwiftUI GeometryReader) is platform-specific.

4. **Detection-gated, zero overhead for non-UI projects.** Every feature is
   conditional on `UI_PROJECT_DETECTED`. Non-UI projects see no prompt bloat, no
   extra specialist invocations, no detection latency.

5. **Extensible by users.** A `.claude/platforms/<name>/` directory in the target
   project overrides or extends Tekhton's built-in platform adapters. Projects with
   unusual stacks can provide custom guidance without forking Tekhton.

### System Architecture

#### Platform Adapter Convention

UI knowledge is organized as a file-based adapter system:

```
tekhton/
├── platforms/                              # Platform-specific UI knowledge
│   ├── _base.sh                            # Platform resolution + universal helpers
│   ├── _universal/                         # Cross-platform guidance (always included)
│   │   ├── coder_guidance.prompt.md        # State handling, a11y, composition
│   │   └── specialist_checklist.prompt.md  # Universal review criteria
│   ├── web/                                # Web: React, Vue, Svelte, Angular, HTML
│   │   ├── detect.sh                       # Design system detection (web-specific)
│   │   ├── coder_guidance.prompt.md        # CSS systems, responsive, web a11y
│   │   ├── specialist_checklist.prompt.md  # Web-specific review criteria
│   │   └── tester_patterns.prompt.md       # E2E patterns (Playwright, Cypress, etc.)
│   ├── mobile_flutter/                     # Flutter/Dart
│   │   ├── detect.sh                       # ThemeData, MaterialApp, widget tree
│   │   ├── coder_guidance.prompt.md        # Widget composition, themes, adaptive
│   │   ├── specialist_checklist.prompt.md  # Flutter-specific review criteria
│   │   └── tester_patterns.prompt.md       # Widget tests, integration, golden
│   ├── mobile_native_ios/                  # Swift/SwiftUI/UIKit
│   │   ├── detect.sh                       # SwiftUI views, UIKit xibs, asset catalogs
│   │   ├── coder_guidance.prompt.md        # HIG compliance, SF Symbols, SwiftUI idioms
│   │   ├── specialist_checklist.prompt.md  # iOS-specific review criteria
│   │   └── tester_patterns.prompt.md       # XCTest, UI testing, snapshot tests
│   ├── mobile_native_android/              # Kotlin/Jetpack Compose/XML layouts
│   │   ├── detect.sh                       # Compose, Material3, resource system
│   │   ├── coder_guidance.prompt.md        # Compose idioms, Material Design, adaptive
│   │   ├── specialist_checklist.prompt.md  # Android-specific review criteria
│   │   └── tester_patterns.prompt.md       # Espresso, Compose testing, screenshot
│   └── game_web/                           # Phaser, PixiJS, Three.js, Babylon.js
│       ├── detect.sh                       # Engine detection, asset pipeline
│       ├── coder_guidance.prompt.md        # Game loop, scene graph, asset management
│       ├── specialist_checklist.prompt.md  # Game-specific review criteria
│       └── tester_patterns.prompt.md       # Headless rendering, state-based testing
```

#### Platform Resolution Flow

```
detect_ui_framework()          # Existing — sets UI_PROJECT_DETECTED, UI_FRAMEWORK
    │
    ▼
detect_ui_platform()           # NEW — maps framework + project type → platform dir
    │                          #   flutter → mobile_flutter
    │                          #   swiftui → mobile_native_ios
    │                          #   react/vue/svelte/angular → web
    │                          #   phaser/pixi/three/babylon → game_web
    │                          #   jetpack-compose → mobile_native_android
    │                          #   generic (2+ UI signals) → web (safe default)
    │
    ▼
source platforms/<platform>/detect.sh    # Platform-specific design system detection
    │                                    #   Sets: DESIGN_SYSTEM, DESIGN_SYSTEM_CONFIG,
    │                                    #          COMPONENT_LIBRARY_DIR
    │
    ▼
load_platform_fragments()      # NEW — reads .prompt.md files from platform dir
    │                          #   Sets: UI_CODER_GUIDANCE, UI_SPECIALIST_CHECKLIST,
    │                          #          UI_TESTER_PATTERNS
    │                          #   Prepends _universal/ content, then platform content
    │                          #   Checks .claude/platforms/<name>/ for user overrides
    ▼
(variables available for prompt rendering)
```

#### Coder Prompt Integration

Add a `{{IF:UI_PROJECT_DETECTED}}` block to `coder.prompt.md` (currently absent):

```markdown
{{IF:UI_CODER_GUIDANCE}}

## UI Implementation Guidance
This is a UI project. Follow these guidelines for visual implementation.
{{UI_CODER_GUIDANCE}}
{{ENDIF:UI_CODER_GUIDANCE}}
```

The `UI_CODER_GUIDANCE` variable is assembled from three layers (in order):
1. `platforms/_universal/coder_guidance.prompt.md` — state handling, accessibility
   principles, component composition (always present)
2. `platforms/<platform>/coder_guidance.prompt.md` — framework-specific patterns
3. Design system context — if `DESIGN_SYSTEM` was detected, a block naming the
   system and its config file path

#### UI/UX Specialist

New built-in specialist following the existing `specialist_security` pattern:

- **Prompt**: `prompts/specialist_ui.prompt.md` — platform-agnostic skeleton that
  loads `{{UI_SPECIALIST_CHECKLIST}}` from the resolved platform adapter
- **Enablement**: `SPECIALIST_UI_ENABLED` — auto-set to `true` when
  `UI_PROJECT_DETECTED=true` (new pattern: detection-gated default). Explicitly
  overridable to `false` via `pipeline.conf`.
- **Diff relevance** (`_specialist_diff_relevant "ui"`): `.tsx`, `.jsx`, `.vue`,
  `.svelte`, `.css`, `.scss`, `.html`, `.dart`, `.swift`, `.kt`, `**/components/**`,
  `**/pages/**`, `**/views/**`, `**/screens/**`, `**/widgets/**`, `**/scenes/**`
- **Output**: `SPECIALIST_UI_FINDINGS.md` → consumed by reviewer via
  `{{UI_FINDINGS_BLOCK}}` (same as `{{SECURITY_FINDINGS_BLOCK}}` pattern)
- **Blocker threshold**: Broken accessibility (no keyboard/gesture nav, missing focus
  management), missing state handling (no loading/error states on async UI), design
  system violation that breaks visual consistency. Aesthetic preferences are `[NOTE]`.

**Universal checklist categories** (8, in `_universal/specialist_checklist.prompt.md`):
1. Component structure & reusability
2. Design system / token consistency
3. Responsive / adaptive behavior
4. Accessibility (platform-appropriate: WCAG for web, HIG for iOS, Material a11y
   for Android, engine-specific for games)
5. State presentation (loading, error, empty, success)
6. Interaction patterns (forms, modals/sheets, navigation, transitions)
7. Visual hierarchy & layout consistency
8. Platform convention adherence

**Platform specialist checklists** add items specific to their domain. Example —
`web/specialist_checklist.prompt.md` adds: CSS specificity management, hydration
correctness (SSR), bundle impact of component libraries, progressive enhancement.
`mobile_flutter/specialist_checklist.prompt.md` adds: unnecessary widget rebuilds,
`const` constructor usage, platform channel UI thread safety.

#### Scout Enhancement

Expand the existing `{{IF:UI_PROJECT_DETECTED}}` block in `scout.prompt.md` to
also identify:
- The design system in use (component library, theme configuration)
- Existing reusable components in scope
- The project's breakpoint/adaptive layout conventions

This enriches `SCOUT_REPORT.md` so the coder receives structured design context
alongside the file map.

#### Tester Guidance Expansion

Replace the monolithic `tester_ui_guidance.prompt.md` with a composed approach:
existing content migrates to `platforms/web/tester_patterns.prompt.md`, and each
platform provides its own patterns. The tester prompt's `{{TESTER_UI_GUIDANCE}}`
variable is assembled from the resolved platform's `tester_patterns.prompt.md`.

New patterns added across platforms:
- State management UI (loading/error/empty state rendering)
- Modal/sheet/dialog behavior (focus trap, dismiss, scroll lock)
- Keyboard/gesture navigation
- Focus management (return focus after dismiss, skip-to-content)
- Multi-step flows (wizard state, back nav, step validation)

### Platform-Specific Detection Details

#### Web (`platforms/web/detect.sh`)

Detects:
- **CSS framework**: `tailwind.config.*` → Tailwind; `bootstrap` in deps → Bootstrap;
  `bulma` in deps → Bulma; `@unocss` → UnoCSS
- **Component library**: `@mui/material` → MUI; `@chakra-ui` → Chakra;
  `components.json` with `"$schema".*shadcn` → shadcn/ui; `@radix-ui` → Radix;
  `antd` → Ant Design; `@headlessui` → Headless UI
- **Design tokens**: `tailwind.config.*` theme section; `*.tokens.css`;
  `variables.css`/`variables.scss`; CSS custom property files
- **Component directory**: `src/components/ui/`, `components/common/`, `src/ui/`

Exports: `DESIGN_SYSTEM`, `DESIGN_SYSTEM_CONFIG`, `COMPONENT_LIBRARY_DIR`

#### Flutter (`platforms/mobile_flutter/detect.sh`)

Detects:
- **Theme system**: `ThemeData` usage in `lib/`; `MaterialApp`/`CupertinoApp` in
  main; custom theme file (`*theme*.dart`, `*color*.dart`)
- **Widget library**: `flutter_bloc`/`riverpod`/`provider` state management;
  custom widget directory (`lib/widgets/`, `lib/ui/`, `lib/components/`)
- **Design tokens**: Theme extension classes, `ColorScheme` customization

#### iOS (`platforms/mobile_native_ios/detect.sh`)

Detects:
- **UI framework**: SwiftUI (`import SwiftUI` in sources) vs. UIKit (`UIViewController`
  subclasses, `.xib`/`.storyboard` files)
- **Design system**: Asset catalog (`Assets.xcassets`), custom color sets, SF Symbols
  usage, custom `ViewModifier` files
- **Component patterns**: `Views/` or `Screens/` directory, `ViewModels/`

#### Android (`platforms/mobile_native_android/detect.sh`)

Detects:
- **UI framework**: Jetpack Compose (`@Composable` in sources) vs. XML layouts
  (`res/layout/*.xml`)
- **Design system**: Material3 (`material3` in deps), custom theme (`Theme.kt`,
  `Color.kt`, `Type.kt`), resource-based theming (`res/values/colors.xml`,
  `res/values/themes.xml`)
- **Component patterns**: `ui/` package, `composables/` directory, `screens/` directory

#### Web Games (`platforms/game_web/detect.sh`)

Detects:
- **Engine**: `phaser` → Phaser; `pixi.js`/`@pixi` → PixiJS; `three` → Three.js;
  `@babylonjs` → Babylon.js (from `package.json` deps)
- **Asset pipeline**: `assets/` or `public/assets/` directory, sprite sheets,
  tilemap files, audio directories
- **Scene structure**: `scenes/` directory, scene class patterns

### User Override Mechanism

Users can extend or override platform adapters by placing files in their project:

```
<project>/.claude/platforms/<platform_name>/
├── detect.sh                       # Additional detection (sourced AFTER built-in)
├── coder_guidance.prompt.md        # Appended to built-in guidance
├── specialist_checklist.prompt.md  # Appended to built-in checklist
└── tester_patterns.prompt.md       # Appended to built-in patterns
```

User files are **appended** to built-in content, not replacing it. This ensures
the universal and platform-specific base is always present while allowing projects
to add custom rules (e.g., "always use our `<AppButton>` wrapper, never raw
`<button>`").

A fully custom platform (e.g., for Godot, Unity, or an internal framework) can be
defined entirely in `.claude/platforms/custom_<name>/` with all four files. The
platform name is then set via `UI_PLATFORM=custom_<name>` in `pipeline.conf`.

### Config Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SPECIALIST_UI_ENABLED` | `auto` | `auto` = enabled when `UI_PROJECT_DETECTED=true`. Set `true`/`false` to override. |
| `SPECIALIST_UI_MODEL` | `CLAUDE_STANDARD_MODEL` | Model for UI specialist agent |
| `SPECIALIST_UI_MAX_TURNS` | `8` | Turn limit for UI specialist |
| `UI_PLATFORM` | `auto` | Override auto-detected platform. Set to a platform directory name. |
| `UI_PLATFORM_DIR` | (computed) | Resolved platform directory path (read-only) |
| `DESIGN_SYSTEM` | (detected) | Detected design system name (e.g., `tailwind`, `mui`, `material3`) |
| `DESIGN_SYSTEM_CONFIG` | (detected) | Path to the design system config file |
| `COMPONENT_LIBRARY_DIR` | (detected) | Path to the project's reusable component directory |

### Milestone Breakdown

| ID | Title | Depends | Parallel Group | Scope |
|----|-------|---------|---------------|-------|
| M57 | UI Platform Adapter Framework | M56 | — | `platforms/` directory, `_base.sh`, `_universal/`, `detect_ui_platform()`, `load_platform_fragments()`, prompt engine integration, user override mechanism |
| M58 | Web UI Platform Adapter | M57 | ui_platforms | `platforms/web/` — design system detection, coder guidance, specialist checklist, tester patterns. Migrate `tester_ui_guidance.prompt.md`. |
| M59 | UI/UX Specialist Reviewer | M57 | ui_platforms | `specialist_ui.prompt.md`, auto-enable logic, diff relevance filter, `{{UI_FINDINGS_BLOCK}}` injection, `{{UI_CODER_GUIDANCE}}` in coder prompt |
| M60 | Mobile & Game Platform Adapters | M57 | ui_platforms | `platforms/mobile_flutter/`, `platforms/mobile_native_ios/`, `platforms/mobile_native_android/`, `platforms/game_web/` — detect, coder guidance, specialist checklist, tester patterns |

M58, M59, and M60 share a parallel group because they are independent once M57
establishes the framework. In practice they will execute sequentially in the
current single-agent pipeline, but the DAG correctly models their independence.

### Scope Boundaries — What This Does NOT Include

- **Visual regression testing** (screenshot comparison) — requires vision model
  integration. V4 candidate.
- **Design mockup comparison** — requires image input to agents. V4 candidate.
- **Storybook / component catalog integration** — useful but not essential for the
  core design intelligence problem.
- **Custom design system generation** — Tekhton is a pipeline, not a design tool.
- **Native game engine platforms** (Unity C#, Unreal C++, Godot GDScript) — deferred
  to user-contributed platform adapters or a future milestone. The `game_web` adapter
  covers browser-based game engines only.
- **React Native** — architecturally distinct from both web React and native mobile.
  Deferred to a future `mobile_react_native/` adapter milestone.

### Why This Design

- **Platform adapters are content directories, not code plugins.** No plugin
  registration API, no dynamic loading, no version compatibility matrix. A platform
  is 4 markdown/shell files in a directory with a naming convention. This is the
  simplest possible extension mechanism that supports the full platform spectrum.
- **Enrichment over replacement.** The coder is enhanced with context, not replaced
  with a "UI coder" variant. One prompt chain to maintain. The specialist adds
  review depth through the proven specialist framework — no new pipeline stages,
  no new rework loops, no new agent invocation infrastructure.
- **Universal + platform layering.** Every UI project gets baseline guidance (state
  handling, accessibility, composition). Platform-specific content is additive.
  An unrecognized platform still gets the universal layer — degradation is graceful,
  not cliff-edge.
- **Auto-enable with explicit override.** `SPECIALIST_UI_ENABLED=auto` means UI
  projects get the specialist without configuration, but operators can disable it.
  This matches the security agent pattern (default-on) rather than the other
  specialists (default-off), because UI quality gaps are as common as security gaps
  in real-world projects.
- **User overrides are append-only.** This prevents users from accidentally losing
  the universal accessibility and state-handling guidance. If a project truly needs
  to replace built-in guidance entirely, they can set `UI_PLATFORM=custom_<name>`
  and provide a complete adapter.

---

## V4 Forward Seeds

The following capabilities are explicitly designed for but not built in V3:

- **Parallel milestone execution** — DAG edges + parallel_group field (M01) enable
  future multi-worktree agent teams. Security agent report format (M09) supports
  parallel-with-reviewer mode.
- **Tech debt agent** — SECURITY_NOTES.md + NON_BLOCKING_LOG.md (M09) form the
  backlog. Parallel execution infrastructure required first.
- **Environment awareness** — Service detection (M12) + infrastructure detection
  (M12) provide the inventory. API/MCP discovery and container execution are V4.
- **Historical learning** — Intake confidence scores (M10) + run metrics (v2)
  enable threshold calibration. Security waiver patterns (M09) enable policy
  evolution.
- **Dashboard evolution** — Watchtower V3 (M13-M14) is static HTML with file
  polling. V4 replaces this with a localhost server (WebSocket push, bidirectional
  interaction: answer clarifications, approve waivers, trigger runs). V5 adds
  cloud-hosted option for team visibility + mobile access.
- **Metric connectors** — The TK_* data format from Watchtower is designed as
  the universal schema for metric export. V4/V5 adds connectors for DataDog,
  NewRelic, Prometheus, and custom webhook targets.
- **Health score evolution** — V4 adds security posture dimension (from M09
  findings history), accessibility dimension (from M59 UI specialist findings),
  performance dimension. Enterprise users can set minimum health scores as
  deployment gates.
- **Quota intelligence** — V4 ships default quota check scripts for common
  setups (Pro subscription, API key, team plan). Parallel workers share a
  quota pool to prevent N workers exhausting quota N times faster.
- **Multi-platform support** — Abstraction layer for Cursor, Codex, Gemini CLI,
  OpenCode support. Agent invocation, hook mechanisms, and prompt formats
  adapted per platform. Express mode (M26) serves as the common entry point.
  Competitive pressure from Superpowers (5+ platforms today). V4 because it
  requires abstracting the entire agent invocation path.
- **Auto pipeline ordering** — PM agent (M10) evaluates each milestone and
  recommends standard or test_first order based on task type. Bug fixes →
  test_first. New features → standard. Data-driven from rework cycle history.
  Requires PM maturity and calibration data from V3 runs.
- **Visual regression testing** — Vision model integration for screenshot-based
  comparison. The UI platform adapter framework (M57) provides the injection
  points; V4 adds actual screenshot capture and vision model evaluation.
- **Design mockup comparison** — Image input to agents for comparing
  implementation against design specs (Figma exports, wireframes). Requires
  vision model capabilities.
- **Native game engine adapters** — Unity (C#), Unreal (C++), Godot (GDScript)
  platform adapters for `platforms/`. The adapter framework (M57) and user
  override mechanism support community-contributed adapters in the interim.
- **React Native adapter** — Architecturally distinct from both web React and
  native mobile. `platforms/mobile_react_native/` with bridge-aware detection,
  native module guidance, and platform-split testing patterns.

---

## Retrospective (April 2026)

### Summary

Tekhton V3 delivered all 51 planned milestones across 7 themes:

- **Milestone DAG & Indexing** (M1–M8) — File-based milestones with dependency
  tracking, sliding context window, tree-sitter repo maps with PageRank, Serena
  LSP integration. The core V3 promise: context-aware agent prompts.
- **Quality & Safety** (M9–M10, M20, M28–M30, M33, M39, M43–M44) — Dedicated
  security agent, intake/PM gate, test integrity, UI test awareness, build gate
  hardening, test-aware coding, and jr coder test-fix gate.
- **Watchtower Dashboard** (M13–M14, M34–M38) — Browser-based monitoring with
  six tabs, smart refresh, data fidelity fixes, and V4 parallel-teams readiness.
- **Brownfield Intelligence** (M11–M12, M15, M22) — AI artifact detection, deep
  analysis, health scoring, and init UX overhaul.
- **Developer Experience** (M17–M19, M21, M23–M27, M31–M32) — Diagnostics, docs
  site, migration framework, dry-run, rollback, express mode, TDD, browser
  planning.
- **Acceleration** (M40–M50) — Notes rewrite, triage, tag-specialized paths,
  run memory, timing reports, context caching, skip logic, progress transparency.
- **Runtime** (M16) — Quota management and usage-aware pacing.

### Deviations from Original Plan

The original V3 design focused narrowly on the Milestone DAG and Intelligent
Indexing (8 milestones). During execution, scope expanded significantly to include
Watchtower, security agent, intake agent, brownfield improvements, and a full
developer experience suite. This was driven by user feedback and the recognition
that context-aware prompting alone wasn't sufficient — the pipeline needed better
safety, observability, and ease of use to realize the full benefit of V3's
architectural changes.

The core DAG and indexer milestones (M1–M8) were delivered as designed. The
Watchtower dashboard evolved beyond the original spec (two milestones) into a
six-milestone effort with significantly richer functionality. The acceleration
theme (M40–M50) was added late in the initiative to address performance and
usability feedback from real-world V3 usage.

### What Worked Well

- Self-applicable development: Tekhton built its own V3 features using the V2
  pipeline, then switched to the V3 pipeline mid-initiative
- File-based milestones eliminated CLAUDE.md bloat and enabled clean git history
  per milestone
- The intake agent reduced rework cycles by catching ambiguous tasks early
- Browser-based planning dramatically improved the planning interview experience

### What to Improve in V4

- The Watchtower dashboard is static HTML with file polling; V4 should use a
  localhost server with WebSocket push for real-time updates
- Express mode works but lacks persistence; repeated runs on the same project
  should benefit from cached configuration
- Parallel milestone execution is data-model-ready but not yet implemented
