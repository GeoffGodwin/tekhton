# Tekhton 3.0 — Intelligent Indexing, Milestone DAG & Pipeline Quality Design Document

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

## Updated Pipeline Flow (V3 Complete)

```
tekhton --init
  ├─ AI artifact detection (M11)    ← NEW
  ├─ Tech stack detection
  ├─ Workspace/service/CI detection (M12)  ← NEW
  ├─ Project crawl → PROJECT_INDEX.md
  ├─ Config generation (CI-informed)
  └─ Synthesis → DESIGN.md + CLAUDE.md + milestones/

tekhton "task" or tekhton --milestone
  ├─ Milestone DAG load (M01-M02)
  ├─ Intake gate / PM agent (M10)    ← NEW
  ├─ [Architect audit]
  ├─ Scout + Coder + Build Gate
  ├─ Security scan + rework (M09)    ← NEW
  ├─ Reviewer + rework loop
  ├─ Tester + validation
  └─ [Cleanup sweep]
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
- `dashboard.sh` — Watchtower data emission + lifecycle (M13)
- `dashboard_parsers.sh` — Report parsing for dashboard data (M13)

**stages/ (pipeline stages):**
- `security.sh` — security scan + rework routing (M09)
- `intake.sh` — task clarity evaluation + PM gate (M10)

**prompts/ (agent templates):**
- `security_scan.prompt.md` — security analysis prompt (M09)
- `security_rework.prompt.md` — security fix rework prompt (M09)
- `intake_scan.prompt.md` — clarity evaluation prompt (M10)
- `intake_tweak.prompt.md` — milestone refinement prompt (M10)
- `artifact_merge.prompt.md` — AI config merge prompt (M11)

**templates/ (copied to target projects):**
- `security.md` — security agent role definition (M09)
- `intake.md` — intake/PM agent role definition (M10)

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
