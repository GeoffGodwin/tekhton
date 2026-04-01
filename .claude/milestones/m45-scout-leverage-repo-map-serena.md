# Milestone 45: Scout Prompt — Leverage Repo Map & Serena
<!-- milestone-meta
id: "45"
status: "pending"
-->

## Overview

When tree-sitter repo maps and/or Serena LSP are available, Scout should use
them as primary discovery tools instead of blind `find`/`grep`. Currently,
Scout's core directive hardcodes "Use find, grep, and ls" even when the repo
map already provides ranked, task-relevant file signatures and Serena provides
precise symbol cross-references. This wastes Haiku turns re-discovering files
that tree-sitter already indexed.

This milestone was partially implemented in an earlier commit (conditional
prompt with `SCOUT_NO_REPO_MAP` flag). This milestone completes the work by
also adjusting Scout's tool allowlist and validating turn savings.

Depends on Milestone 42 (Tag-Specialized Execution Paths) for the tag-aware
execution structure.

## Scope

### 1. Complete Scout Prompt Conditional Rewrite

**File:** `prompts/scout.prompt.md`

Verify and refine the existing conditional directives:
- When `REPO_MAP_CONTENT` available: verify-and-refine strategy
- When `SERENA_ACTIVE`: LSP-based cross-referencing
- When neither: filesystem exploration fallback

### 2. Conditional Tool Allowlist

**File:** `stages/coder.sh`

When `REPO_MAP_CONTENT` is non-empty, reduce Scout's tool allowlist:
- Keep: Read, Glob, Grep, Write (for SCOUT_REPORT.md)
- Remove: `Bash(find:*)`, `Bash(cat:*)`, `Bash(ls:*)` — redundant when repo
  map provides the data

Add config key `SCOUT_REPO_MAP_TOOLS_ONLY` (default: true) to control this.

### 3. Turn Usage Validation

After implementing, verify that Scout turn usage drops when repo map is
available. The metrics system already tracks per-agent turns — compare runs
with and without repo map to validate savings.

## Acceptance Criteria

- When `REPO_MAP_ENABLED=true`, Scout prompt instructs verification-first strategy
- When `SERENA_ACTIVE=true`, Scout prompt instructs LSP-based cross-referencing
- When neither available, Scout falls back to existing find/grep behavior
- Scout produces identical SCOUT_REPORT.md format regardless of tooling mode
- Tool allowlist is reduced when repo map available (configurable)
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified files

Tests:
- `SCOUT_NO_REPO_MAP` is set when `REPO_MAP_CONTENT` is empty
- `SCOUT_NO_REPO_MAP` is unset when `REPO_MAP_CONTENT` is populated
- Tool allowlist changes based on `SCOUT_REPO_MAP_TOOLS_ONLY` config

Watch For:
- Scout is on Haiku — prompt must be clear and simple, not overloaded with
  conditional logic that confuses cheaper models.
- The repo map might be incomplete (e.g., tree-sitter can't parse some files).
  Scout should still be able to discover files the repo map missed.
- Removing Bash tools entirely could prevent Scout from checking file existence.
  Keep Read and Glob available always.

Seeds Forward:
- Milestone 43 (Test-Aware Coding) extends Scout's report with test file
  discovery, which benefits from the same repo map / Serena tooling
