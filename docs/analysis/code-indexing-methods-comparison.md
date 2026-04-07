# Code Indexing & Discovery Methods for AI Coding Agents
## A Comparative Analysis for Tekhton v3

**Date:** 2026-03-20
**Context:** Evaluating whether a graph-based code indexer for Tekhton v3 is the
best approach vs. adopting or adapting existing solutions.

---

## 1. Tekhton's Current Approach (v1/v2)

Tekhton currently has **no code index**. File discovery happens entirely inside
agent context windows:

| Stage | Discovery Method | Cost |
|-------|-----------------|------|
| Scout | `find`/`grep`/`ls` (10-file cap) | O(codebase) per invocation |
| Coder | Architecture.md prose + Glob/Grep | O(all injected blocks + discovery) |
| Reviewer | Reads only files in CODER_SUMMARY.md | O(files modified) |
| Tester | Coverage gaps + source reads | O(gaps × files) |

**Key bottlenecks:**
- ARCHITECTURE.md is injected as full prose to every agent (~500-1000 tokens even
  for small changes)
- Scout runs inside the context window — every file-system traversal burns tokens
- No cross-run learning — the same files are "discovered" on every invocation
- No structural awareness — agents grep for keywords, not call-graph relationships
- The planned Context Compiler (v2 M2) adds keyword-based section filtering but
  nothing structural

**Token waste estimate:** Agents spend 4.3-6.5% of context on discovery in
well-indexed systems (Aider). Tekhton likely spends 15-30% on architecture prose
re-reading and ad-hoc file search, based on the full injection of ARCHITECTURE.md,
GLOSSARY.md, prior reports, and non-blocking notes to every agent.

---

## 2. Existing Approaches — Taxonomy

### 2.1 Graph + PageRank (Aider)

**How it works:**
1. Tree-sitter parses all source files into ASTs
2. Extracts definitions and references as `Tag(file, line, name, kind)` tuples
3. Builds a NetworkX MultiDiGraph: nodes = files, edges = reference relationships
4. Runs PageRank with personalization factors (chat-mentioned files get boosted)
5. Binary-searches to fit top-ranked symbols into a token budget
6. Outputs a "repo map" — a compressed view of the most relevant symbols

**Key properties:**
- **Deterministic** — no embeddings, no GPU, no vector DB
- **Offline** — works without external services
- **40+ language support** via tree-sitter grammars
- **Token-efficient** — 4.3-6.5% of context window vs 54-70% for iterative search
- **Cached** — disk-based tag cache with mtime tracking avoids re-parsing unchanged files
- **Personalized** — files mentioned in conversation get PageRank boost

**Limitations:**
- Graph captures structural relationships, not semantic similarity
- PageRank is a static centrality measure — doesn't adapt to task-specific relevance
  beyond personalization
- No type hierarchy or inheritance graph (just def/ref edges)
- Standalone tool (RepoMapper MCP exists but is community-maintained)

**Source:** [aider.chat/2023/10/22/repomap.html](https://aider.chat/2023/10/22/repomap.html)

### 2.2 LSP-Based Semantic Retrieval (Serena)

**How it works:**
1. Wraps existing Language Server Protocol (LSP) servers via `multilspy`
2. Every modern LSP (Pyright, rust-analyzer, typescript-language-server) already
   maintains a full symbol graph with type information
3. Exposes MCP tools: `find_symbol`, `find_referencing_symbols`, `insert_after_symbol`
4. Agent queries symbols by name → gets definitions, references, types
5. Never reads entire files — works at symbol granularity

**Key properties:**
- **30+ languages** via existing LSP servers
- **Compiler-grade accuracy** — uses the same analysis that powers IDE features
- **Zero custom indexing** — leverages infrastructure that already exists
- **Symbol-level operations** — `find_symbol("UserService")` returns only that class
- **MCP integration** — works as a tool the agent can call, not pre-injected context
- **Free, open-source** (github.com/oraios/serena)

**Architecture details:**
- Built on **Solid-LSP** (`src/solidlsp`), a synchronous Python wrapper around
  Microsoft's `multilspy` — deliberate sync design to avoid asyncio contamination
- **Two-tier persistent cache** in `.solidlsp/cache/<language_id>/`: raw LSP
  responses + processed DocumentSymbol trees with parent/child relationships
- Cache keyed by **content hash** — edits auto-invalidate, no stale reads
- **Lazy language server init** — servers start only when a file of that language
  is first accessed (startup cost scales with languages used, not supported)
- **Serialized task queue** — tool calls are sequential, not parallel
- Persistent **project memory** (`.serena/memories/`) stores project understanding
  across sessions — avoids re-discovering structure each time
- ~36 tools total, ~26 exposed by default. 21.8k GitHub stars, MIT licensed.

**Limitations:**
- Requires LSP servers installed (Pyright, rust-analyzer, gopls, etc.)
- LSP startup can be slow for large projects (initial analysis pass)
- No cross-file relevance ranking — agent must know what to ask for
- Agent-driven discovery still burns tokens on tool calls (though <10ms cached)
- Serialized task queue means no parallel symbol lookups
- JetBrains plugin available as alternative backend

**Source:** [github.com/oraios/serena](https://github.com/oraios/serena)

### 2.3 Embedding + Vector Search (Greptile, CocoIndex)

**How it works:**
1. Indexes entire codebase by splitting into semantic chunks (per-function level)
2. Generates vector embeddings for each chunk
3. Optionally translates code to natural language before embedding (improves recall)
4. Builds a code graph mapping relationships between functions, classes, dependencies
5. Queries via cosine similarity against the embedded corpus

**Key properties (Greptile):**
- **Semantic understanding** — finds code by meaning, not just keyword
- **Graph overlay** — relationships between chunks provide structural context
- **Continuous indexing** — updates as code changes
- **Commercial product** — $180M valuation, well-funded

**Key properties (CocoIndex/ccc):**
- **AST-based chunking** — uses tree-sitter for intelligent code splitting
- **Local or cloud embeddings** — SentenceTransformers locally (free) or cloud
- **Embedded & portable** — no database setup required
- **CLI + MCP integration** — works with Claude, Codex, Cursor

**Limitations:**
- Requires embedding model (local GPU or API calls = cost)
- Vector DBs add operational complexity
- Semantic similarity ≠ structural dependency (can miss code that's structurally
  related but semantically different)
- Index size can be substantial for large repos
- Non-deterministic — embedding models evolve, results shift

### 2.4 SCIP (Sourcegraph)

**How it works:**
1. Language-specific indexers (compiler-backed) produce SCIP protocol buffers
2. Each Document has occurrences (source ranges → symbols) and symbol definitions
3. Symbols are human-readable strings (not opaque numeric IDs)
4. Supports Go-to-definition, Find-references at IDE fidelity
5. Streaming support for large codebases (process one file at a time)

**Key properties:**
- **Compiler-grade precision** — uses actual compiler frontends
- **8x smaller than LSIF**, 3x faster to process (per Meta/Glean benchmarks)
- **Protobuf schema** — machine-readable, language bindings available
- **File-level incrementality** — can re-index only changed files
- **IDE-fidelity navigation** — Go-to-definition, Find-references

**Limitations:**
- Requires language-specific indexers (scip-typescript, scip-java, scip-go, etc.)
- Not all languages have indexers yet
- Designed as a transmission format, not a query format
- Heavy infrastructure (Sourcegraph platform) for full benefit
- No built-in relevance ranking (it's an index, not a search system)

**Source:** [github.com/sourcegraph/scip](https://github.com/sourcegraph/scip)

### 2.5 LSP + AI Agents (LSAP, OpenCode, lsp-ai)

**Emerging approach:**
- LSAP (Language Server Agent Protocol) defines how AI coding agents interact
  with Language Servers
- OpenCode provides 30+ pre-configured language servers with auto-install
- lsp-ai is an open-source language server backend for AI-powered functionality
- Claude Code shipped native LSP support in Dec 2025 (v2.0.74) for 11 languages

**Key insight:** LSP already solves the code navigation problem. The challenge
is bridging LSP's synchronous, cursor-position-based API to an agent's
task-oriented query model. Go-to-definition via LSP takes ~50ms vs ~45s for
text search — a 900x speedup with zero false positives.

### 2.6 Knowledge Graph Engines (Graph RAG for Code)

**How it works:**
1. Build a full graph database of code entities and their relationships
2. Nodes = functions/classes/modules, edges = calls/imports/inheritance
3. Query with graph traversals or natural language

**Notable implementations:**
- **Axon** — indexes any codebase into a structural knowledge graph (dependencies,
  call chains, clusters, execution flows). Exposed via MCP. Includes force-directed
  graph visualization.
- **Code-Graph-RAG** — represents codebases in Memgraph (graph DB) with tree-sitter
  as the extraction layer. Supports graph search + grep fallback.
- **CodeGraphContext** — transforms codebases into queryable knowledge graphs for
  blast radius analysis and impact detection.

**Agent query patterns enabled:**
- "What functions call X?" (reverse call graph)
- "If I change file Y, what else breaks?" (blast radius)
- "What is the execution path from entry point to this function?" (call chain)

**Strengths:** Rich relationship queries no other approach can answer. Impact
analysis prevents blind edits.

**Limitations:** Expensive to build/maintain. No tool has solved real-time
incremental graph updates that keep pace with active development. Overkill for
small projects.

### 2.7 Code Intelligence MCP Servers (Agent-Oriented APIs)

A "Cambrian explosion" of MCP servers emerged in late 2025:

| Server | Approach | Key Capability |
|--------|----------|----------------|
| **Code Pathfinder** | 5-pass AST analysis | Call graphs, dataflow analysis |
| **CodeMCP (CKB)** | SCIP + tree-sitter fallback | Cross-file references |
| **Rhizome** | Tree-sitter + LSP (Rust) | File summarization, complexity |
| **code-graph-mcp** | Multi-language AST | 25+ languages, architecture analysis |
| **AiDex** | Tree-sitter pre-indexing | Persistent index, instant answers |
| **CodeGrok** | AST + vector embeddings | 10x context efficiency |

**The pattern:** These servers sit between agent and codebase, answering
structural queries so the agent doesn't read raw files to navigate.

### 2.8 Context Packing (Repomix, 16x Prompt)

**How it works:**
1. Concatenates relevant source files into a single prompt-ready document
2. User or heuristic selects which files to include
3. Applies token-aware truncation and formatting

**Key properties:**
- Simplest approach — no indexing, no graph, no embeddings
- Works today with any model
- Repomix (22k stars) has `--compress` flag using tree-sitter to extract only
  key code elements — can reduce a repo from ~60M to ~1.8M tokens
- Manual file selection is labor-intensive but precise

**Limitations:**
- No automated relevance detection
- Scales poorly with codebase size
- Token-inefficient for large projects without compression

### 2.9 Cursor's Custom Embedding Model (State-of-the-Art Semantic Search)

**How it works:**
1. Files chunked at function level, encrypted, sent to Cursor's backend
2. Custom embedding model generates vectors, stored in Turbopuffer (vector DB)
3. Sync via Merkle trees — diffs every ~10 minutes, re-indexes only changed files
4. Query via cosine similarity

**Key innovation (2025):** Cursor trains its embedding model using agent session
traces as training data. When an agent searches and opens files before finding
the right code, an LLM retrospectively ranks what would have been most helpful.
The embedding model learns from these rankings. This yielded **12.5% improvement
in QA accuracy** and **2.6% improvement in code retention** for large codebases.

**Strengths:** Self-improving semantic search. Merkle tree sync is clever.

**Limitations:** Requires cloud GPU infrastructure. Privacy concerns. No
structural/call-graph awareness — purely semantic similarity.

### 2.10 Key Research Finding: AST-Based Chunking Validated

The "cAST" research paper (arXiv, June 2025) validated that **AST-based chunking
consistently outperforms fixed-size chunking for code RAG** across multiple
retrievers and LLM generators. This confirms that tree-sitter-based approaches
have a fundamental advantage over naive text splitting.

---

## 3. Comparison Matrix

| Criterion | Tekhton (current) | Graph+PageRank (Aider) | LSP (Serena) | Embeddings (Greptile) | SCIP (Sourcegraph) | Knowledge Graphs (Axon) |
|-----------|-------------------|----------------------|-------------|---------------------|-------------------|----------------------|
| **Discovery complexity** | O(agent turns × codebase) | O(files) one-time + O(1) lookup | O(1) per symbol query | O(files) one-time + O(1) query | O(files) one-time + O(1) lookup | O(files) one-time + O(1) query |
| **Token efficiency** | 15-30% waste est. | 4.3-6.5% of context | Very low (symbol-level) | Low (semantic chunks) | Low (precise locations) | Low (structural queries) |
| **Language support** | Any (agent uses grep) | 40+ (tree-sitter) | 30+ (LSP servers) | Depends on embedder | ~10 (needs compiler) | Varies by parser |
| **Accuracy** | Agent-dependent | Structural (def/ref) | Compiler-grade | Semantic (approximate) | Compiler-grade | Structural (high) |
| **External dependencies** | None | tree-sitter | LSP servers | Embedding model + vector DB | SCIP indexers | Graph DB + parser |
| **Offline capable** | Yes | Yes | Yes | Partial (local embeddings) | Yes | Yes |
| **Deterministic** | No (agent behavior) | Yes | Yes | No (embedding variance) | Yes | Yes |
| **Cross-run caching** | None | Disk cache (mtime) | Two-tier cache (<10ms) | Persistent vector DB | Index files | Persistent graph DB |
| **Setup complexity** | Zero | Low (pip install) | Medium (LSP per language) | High (embeddings + DB) | High (indexers + platform) | High (graph DB + indexer) |
| **Relevance ranking** | None | PageRank | None (agent-driven) | Cosine similarity | None | Graph traversal |
| **Bash-only compatible** | Yes | No (Python) | No (Python) | No (Python + infra) | No (various) | No (various) |
| **Impact analysis** | None | Partial (edge weights) | Find references | None | Find references | Full blast radius |

### Key Insight: Layered Approaches Win

No single approach dominates. The most effective systems combine layers:
1. **Tree-sitter** as the universal parsing foundation
2. **Graph construction** (call graph, import graph) for structural navigation
3. **Embeddings** (optional) for semantic search when structural links don't exist
4. **LSP** for compiler-grade precision on specific symbol queries
5. **Token budgeting** to dynamically size what gets injected into the prompt

The biggest unsolved problem across the field is **real-time incremental graph
updates** — keeping a structural index current as code is actively being edited.

---

## 4. Analysis: What Should Tekhton v3 Do?

### 4.1 The Core Tension

Tekhton is **Bash 4+, project-agnostic, zero-external-dependency by design**. Every
approach above except "do nothing" requires either:
- A Python/Rust runtime (tree-sitter, LSP, embeddings)
- External services (vector DB, LSP servers)
- Language-specific tooling (SCIP indexers)

This creates a fundamental design decision: **Does Tekhton v3 break the Bash-only
constraint to gain structural code awareness?**

### 4.2 Option A: Build a Custom Graph Indexer (Proposed v3 Approach)

**What this means:**
- Build a dependency graph of the target project
- Walk the graph in O(log n) to find relevant files for a task
- Likely requires tree-sitter or a similar parser

**Verdict: Novel but partially redundant.**

Aider already proved that tree-sitter + PageRank works exceptionally well
(4.3-6.5% context utilization). Building a custom graph indexer from scratch
would be reinventing this wheel. However, Aider's approach is Python-based and
tightly coupled to Aider's architecture — it can't be trivially extracted.

The RepoMapper MCP server is a standalone extraction of Aider's repo map, but
it's community-maintained and may not be production-ready.

### 4.3 Option B: Integrate Serena as an MCP Tool

**What this means:**
- Agents call `find_symbol`, `find_referencing_symbols` instead of `grep`/`find`
- LSP provides compiler-grade accuracy for free
- No custom indexer needed — LSP servers already exist

**Verdict: Most practical for Tekhton's architecture.**

Serena maps perfectly to Tekhton's agent-tool model. Instead of injecting
ARCHITECTURE.md as prose and hoping the agent greps correctly, the scout and
coder stages would call symbol-level tools. This eliminates the biggest token
waste (full architecture injection) while maintaining Tekhton's orchestration
model.

**Trade-off:** Requires LSP servers to be installed in the target project's
environment. This violates the "zero external dependency" principle but is
arguably acceptable since LSP servers are standard developer tooling.

### 4.4 Option C: Adopt Aider's Repo Map as a Pre-Stage

**What this means:**
- Run a tree-sitter-based repo map generator before the scout stage
- Inject the compressed repo map instead of full ARCHITECTURE.md
- PageRank ensures only structurally relevant symbols appear

**Verdict: Best token efficiency, moderate integration effort.**

This could be implemented as a new "indexer" pre-stage that runs once per project
(cached) and produces a compressed repo map. The map replaces ARCHITECTURE.md
injection with a task-specific, token-budgeted symbol list.

**Trade-off:** Requires Python + tree-sitter as a dependency. Could be optional
(fallback to current behavior if not available).

### 4.5 Option D: Hybrid — Repo Map + Serena

**What this means:**
- Repo map provides the initial relevance ranking (what files matter)
- Serena provides drill-down capability (symbol-level operations within those files)
- Combined: the agent knows both what's relevant AND can navigate it precisely

**Verdict: Optimal but highest complexity.**

### 4.6 Option E: Enhanced Bash-Native Approach

**What this means:**
- Use `ctags` (universal-ctags) to build a tag database — available via package
  manager on every Linux/macOS system
- Parse the tags file in Bash to build a simple adjacency list
- Inject only symbols relevant to the task (keyword match on tag names)

**Verdict: Stays within Bash constraints, much weaker than tree-sitter.**

ctags provides definition locations but not references. Without reference tracking,
you can't build a dependency graph or do PageRank. This is a marginal improvement
over the current approach.

---

## 5. Recommendation

### Primary Recommendation: Option C (Aider-Style Repo Map) + Progressive Enhancement

**Phase 1 — Repo Map Pre-Stage (v3 Milestone):**
- Add an optional `tree-sitter` + `PageRank` based repo map generator as a pre-stage
- When available, inject the token-budgeted repo map instead of full ARCHITECTURE.md
- Fallback to current behavior when tree-sitter is not installed
- Config: `REPO_MAP_ENABLED=true`, `REPO_MAP_BUDGET_TOKENS=2048`

**Phase 2 — Serena Integration (v3 Milestone):**
- Add Serena MCP tools to agent tool lists (scout, coder, reviewer)
- Replace `find`/`grep` discovery with `find_symbol`/`find_referencing_symbols`
- When LSP servers are available, agents get compiler-grade navigation
- Fallback to grep/find when LSP is not available

**Phase 3 — Cached Index (v3 Milestone):**
- Cache the repo map and tag data between runs
- Invalidate only for changed files (mtime tracking, same as Aider)
- Cross-run learning: recent task→file associations inform future PageRank
  personalization

### Why Not Build Custom?

1. **Aider already proved the algorithm** — tree-sitter + PageRank is the
   state-of-the-art for deterministic, offline code indexing
2. **Serena already wraps LSP** — building a custom LSP wrapper is unnecessary
3. **The novel contribution of Tekhton is orchestration**, not indexing — focus
   engineering effort on what makes Tekhton unique (multi-agent pipeline,
   rework routing, milestone automation)
4. **The "graph in O(log n)" idea is essentially what PageRank provides** —
   top-ranked nodes are found in O(n) index time + O(1) lookup time, which
   amortized across runs is better than O(log n) per query

### Why Not Pure Embeddings?

1. **Non-deterministic** — embedding models produce different results over time
2. **External dependency** — requires embedding model (GPU or API)
3. **Semantic ≠ structural** — finding code that "looks similar" misses code
   that is structurally dependent but semantically different (e.g., a config
   loader that's called by the function you're modifying)
4. **Tekhton values determinism** (Rule #4 in CLAUDE.md) — embeddings violate this

---

## 6. Impact Estimate

| Metric | Current | With Repo Map | With Repo Map + Serena |
|--------|---------|--------------|----------------------|
| Context waste on discovery | 15-30% | 4-7% | 2-5% |
| Scout accuracy | Agent-dependent | Structurally informed | Compiler-grade |
| Cross-run cache hits | 0% | ~80% (mtime) | ~90% (LSP + mtime) |
| Setup complexity | Zero | `pip install tree-sitter` | + LSP servers |
| Language support | Any | 40+ | 30+ (compiler-grade) |

**Estimated token savings per run:** 30-50% reduction in total tokens consumed,
primarily from eliminating full ARCHITECTURE.md injection and reducing scout
exploration turns.

---

## 7. Tools Referenced

| Tool | Type | URL |
|------|------|-----|
| Aider Repo Map | Tree-sitter + PageRank | [aider.chat/docs/repomap](https://aider.chat/docs/repomap.html) |
| RepoMapper MCP | Standalone repo map | [github.com/pdavis68/RepoMapper](https://github.com/pdavis68/RepoMapper) |
| Serena | LSP-based MCP server (21.8k stars) | [github.com/oraios/serena](https://github.com/oraios/serena) |
| SCIP | Code intelligence protocol | [github.com/sourcegraph/scip](https://github.com/sourcegraph/scip) |
| CocoIndex (ccc) | AST + embeddings CLI | [github.com/cocoindex](https://github.com/cocoindex) |
| Greptile | Graph + embeddings (commercial) | [greptile.com](https://www.greptile.com) |
| Axon | Knowledge graph MCP | [github.com/harshkedia177/axon](https://github.com/harshkedia177/axon) |
| Code Pathfinder | 5-pass AST analysis MCP | [codepathfinder.dev/mcp](https://codepathfinder.dev/mcp) |
| Rhizome | Tree-sitter + LSP (Rust) MCP | [github.com/basidiocarp/rhizome](https://github.com/basidiocarp/rhizome) |
| code-graph-mcp | Multi-language AST MCP | [github.com/entrepeneur4lyf/code-graph-mcp](https://github.com/entrepeneur4lyf/code-graph-mcp) |
| Repomix | Context packing (22k stars) | [repomix.com](https://repomix.com/) |
| tree-sitter | Parser generator | [tree-sitter.github.io](https://tree-sitter.github.io/tree-sitter/) |
| tiktoken | Token counter (OpenAI) | [github.com/openai/tiktoken](https://github.com/openai/tiktoken) |
| LSAP | LSP for AI agents protocol | [github.com/lsp-client/LSAP](https://github.com/lsp-client/LSAP) |

---

## 8. Note on "TokToken"

No tool called "TokToken" exists in the AI/LLM code context management space.
The closest match is **tiktoken** (OpenAI's BPE tokenizer library, written in Rust
with Python bindings). tiktoken is a tokenizer — it counts tokens, not a code
indexer. Tekhton v2's `CHARS_PER_TOKEN=4` heuristic serves the same purpose
without the dependency.

Other tools in the adjacent space:
- **tokencost** (AgentOps-AI) — token counting + USD cost estimation for 400+ LLMs
- **token-lens** — analyzes AI prompts for token waste and caching opportunities
- **codebase-token-counter** — analyzes git repos for LLM context window fit
