# Tekhton 6.0 — Rewrite Considerations: Maintainability, Safety, and Performance

> **Status: Pre-initiative stub. Largely superseded by V4.**
> This document predates the V4 Go-rewrite decision (`DESIGN_v4.md`). The
> language-choice analysis below is retained as historical context — V4
> chose Go and is executing the Ship-of-Theseus migration described there.
> Anything that survives once V4 lands is fair game for a V6 follow-on
> (e.g. residual Python `tools/` absorption, test-suite migration). Review
> after V5 is feature-complete and revisit which observations still apply.

---

## Why a Rewrite Conversation Exists

Tekhton is written almost entirely in Bash. This was the right call for V1–V3:
shell is universally available, has no runtime dependencies, and lets the pipeline
run anywhere `claude` runs. The Python `tools/` layer was carved out precisely
because that workload (tree-sitter parsing, PageRank, tag caching) genuinely
required it.

However, the codebase has grown to ~80+ library files, ~200 test files, and 37,000+
lines of shell. The problems that justify revisiting the language choice are **not
performance** — LLM API calls are 95-99% of wall-clock time and no rewrite
changes that — but rather:

1. **Maintainability** — 80+ `.sh` source files with complex inter-dependencies are
   hard to navigate, especially for contributors unfamiliar with the architecture
2. **Type safety** — config key validation, prompt variable binding, and verdict
   parsing all fail at runtime with cryptic errors rather than at startup
3. **JSON handling** — JSONL parsing with grep/awk heuristics is fragile and
   has already been a source of bugs (causal log, run summary, DAG manifest)
4. **Parallelism** — V5's parallel execution engine was difficult to implement
   cleanly in shell; proper async primitives were awkward
5. **Testability** — unit testing shell functions requires either bats-core
   (heavy) or fragile subprocess invocations; mocking is painful

---

## Where the Most Value Lies

### 1. Maintainability  
**Highest-value targets: `lib/` library layer, `tekhton.sh` entry point**

The 80+ `lib/*.sh` files are the core complexity. Each is required to follow strict
sourcing order rules, cannot easily export typed interfaces, and has no IDE
support for cross-file navigation. A Python or Rust module system with explicit
imports, docstrings, and IDE-navigable call graphs would meaningfully reduce the
cognitive load of contributing to or debugging the pipeline.

`tekhton.sh` itself is 500+ lines of argument parsing, library sourcing, and
orchestration — a clear candidate for a properly typed CLI framework (e.g. Rust's
`clap`, Python's `typer`, or Go's `cobra`).

### 2. Type Safety  
**Highest-value targets: `lib/config.sh`, `lib/config_defaults.sh`, `lib/prompts.sh`**

137+ config keys are loaded from flat text files and interpolated into prompts with
zero type checking. A single misspelled key silently emits an empty string into an
agent prompt. Moving config loading to a typed language (Rust structs, Python
dataclasses/Pydantic, or Go structs) would make every key validated on startup
rather than mid-run. `lib/prompts.sh`'s `{{VAR}}` engine is essentially a string
templating system that would be safer and more expressive as a proper template
library (Jinja2, Tera, etc.).

### 3. JSON / JSONL Handling  
**Highest-value targets: `lib/causality.sh`, `lib/causality_query.sh`, `lib/finalize_summary.sh`, `lib/milestone_dag*.sh`**

These files do structured data work (event logs, run summaries, DAG manifests)
using grep, awk, and sed on JSONL/JSON. This is the most objectively fragile part
of the codebase — corner cases in key values can corrupt parses silently. Any
language with a real JSON library (`serde_json`, `json`, `encoding/json`) would
eliminate an entire class of bugs. The causal log query layer in particular would
benefit enormously from even a simple SQLite-backed store.

### 4. Parallelism  
**Highest-value targets: `lib/orchestrate.sh`, future parallel milestone executor**

V5 added parallel milestone execution. In shell, this means `&` background
processes, `wait`, and PID arrays — correct but unergonomic and hard to reason
about (race conditions, cleanup on SIGINT, shared file locks). In Go or Rust this
would be goroutines/tasks with channels for coordination. In Python it would be
`asyncio` or `concurrent.futures`. Any of these would make the parallel executor
significantly safer and more testable.

### 5. Testability  
**Highest-value targets: `lib/agent.sh`, `lib/gates.sh`, `lib/state.sh`, all of `stages/`**

The current test suite (~49,000 lines, 195 files, bats-core) tests shell functions
by sourcing them and asserting side effects on files. Mocking `run_agent()` requires
overriding shell functions globally. A proper language would allow:
- Dependency injection for the agent invocation layer (pure unit tests with no
  filesystem side effects)
- Interface-based mocking of the LLM provider
- Table-driven tests for all verdict parsing logic
- Property-based tests for prompt template rendering

The test-to-source ratio of 1.41:1 is commendable but the tests are harder to
write and maintain than they should be.

---

## Candidate Languages

| Language | Strengths for Tekhton | Weaknesses |
|----------|----------------------|------------|
| **Python** | Already present (`tools/`), fast to write, excellent JSON/async/testing story, familiar to most contributors | Not zero-dependency; slower than Rust/Go but irrelevant given LLM dominance |
| **Go** | Single binary, excellent parallelism, fast compile, good JSON, easy cross-compilation | Less familiar territory; no existing Go code in repo |
| **Rust** | Maximum type safety, best performance (again, irrelevant here), excellent CLI tooling | Steep learning curve; biggest rewrite effort |
| **Keep shell + improve** | No rewrite cost, universally deployable, works today | Doesn't solve any of the five problems above |

**Tentative recommendation (for V6 scoping):** Python, as an incremental
replacement rather than a big-bang rewrite. The `tools/` precedent already exists,
contributors are likely Python-familiar, and the library ecosystem (Pydantic,
anyio, pytest, Jinja2, `rich` for terminal output) maps cleanly to every pain
point listed above.

---

## Incremental Strategy (If Pursued)

A big-bang rewrite is high risk. An incremental approach:

1. **Phase 1 — JSON/data layer first.** Replace `lib/causality*.sh`, `lib/finalize_summary.sh`,
   and `lib/milestone_dag*.sh` with a Python data layer. The rest of the shell
   pipeline calls Python scripts via subprocess (already the pattern with `tools/`).
   Lowest risk; highest immediate reliability gain.

2. **Phase 2 — Config and prompt engine.** Replace `lib/config*.sh` and
   `lib/prompts.sh` with a typed config loader and Jinja2 template renderer.
   Eliminates the entire class of silent-empty-string prompt bugs.

3. **Phase 3 — Orchestration and stages.** Replace `tekhton.sh`, `lib/orchestrate*.sh`,
   and `stages/*.sh` with a proper CLI app and async stage runner. This is the
   largest phase and carries the most risk.

4. **Phase 4 — Test suite migration.** Rewrite bats-core tests as pytest. Net
   reduction in test code volume expected; significant increase in test quality.

---

## Decision Gate

Before committing V6 resources to a rewrite, answer these questions:

- Is V5 complete and stable enough to be the baseline for a rewrite?
- Has the contributor pain around the shell codebase been confirmed by more than
  one contributor?
- Is there a clear owner for the rewrite who understands both the current
  architecture and the target language well?
- Is there appetite for the test-suite migration effort? (This is often the
  underestimated cost of rewrites.)

If the answers are mostly yes, Phase 1 (data layer) is a safe V6 M01 candidate.
If uncertain, defer to V7 and instead invest V6 in consolidating the shell
codebase (reducing file count, strengthening types via `declare`, improving test
ergonomics with better bats patterns).

---

*Last updated: April 2026. Revisit after V5 feature-complete milestone.*
