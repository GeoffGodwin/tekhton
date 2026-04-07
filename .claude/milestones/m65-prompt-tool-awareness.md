# Milestone 65: Prompt Tool Awareness — Serena & Repo Map Coverage
<!-- milestone-meta
id: "65"
status: "done"
-->

## Overview

An audit of all 42 prompt templates found that only 5 (scout, coder, reviewer,
coder_note_bug, coder_note_feat) have explicit instructions to use Serena MCP
tools and prefer them over grep/find. The remaining prompts — including
high-impact ones like tester, coder_rework, build_fix, and all specialists —
have zero tool guidance. Agents in these roles have Serena tools available via
`--mcp-config` but don't know to use them, causing fallback to manual grep/find
that wastes turns and time.

This milestone adds Serena and repo map guidance to prompts where agents do
code discovery or modification. Prompts that are planning-only, interview-only,
or never do file discovery are explicitly out of scope.

Depends on M61 (Repo Map Cache) so cached maps are available without
regeneration cost, and M56 for stable baseline.

## Already Done (Do Not Modify)

These prompts already have complete `{{IF:SERENA_ACTIVE}}` blocks. Use them
as templates for the new additions — do NOT modify them:

- `prompts/coder.prompt.md` (lines 22-30) — Full LSP block with role examples
- `prompts/scout.prompt.md` (lines 53-63) — Full LSP block with preference language
- `prompts/reviewer.prompt.md` (lines 21-28) — Full LSP block
- `prompts/coder_note_bug.prompt.md` (lines 22-30) — Copy of coder block
- `prompts/coder_note_feat.prompt.md` — Copy of coder block

## Scope

### 1. High-Impact Prompts (Tier 1 — Code-Changing Agents)

These agents write/modify code and benefit most from file discovery tools.
Add **expanded** `{{IF:SERENA_ACTIVE}}` blocks with role-specific examples.

**`prompts/tester.prompt.md`:**
- Add `{{IF:SERENA_ACTIVE}}` block with tester-specific guidance:
  "Use `find_symbol` to look up class/function signatures before writing test
  assertions. Use `get_symbol_definition` to verify constructor parameters."
- Add repo map preference language to existing `{{IF:REPO_MAP_CONTENT}}` block:
  "Use the repo map as your primary source for identifying test targets. Do NOT
  grep for class definitions — the repo map has already indexed them."
- **Note:** tester.prompt.md is already the longest prompt (~119 lines). Keep
  additions concise (≤15 lines for both blocks combined).

**`prompts/coder_rework.prompt.md`:**
- Add `{{IF:SERENA_ACTIVE}}` block: "Use `find_symbol` to locate the exact
  functions mentioned in review blockers before modifying them."
- Add `{{IF:REPO_MAP_CONTENT}}` block (currently absent) with standard
  preference language.

**`prompts/build_fix.prompt.md`:**
- Add `{{IF:SERENA_ACTIVE}}` block: "Use `find_symbol` to resolve import paths
  and verify symbol names before fixing build errors."
- Keep it brief — build fix prompts are intentionally short.

**`prompts/tester_resume.prompt.md`:**
- Add brief `{{IF:SERENA_ACTIVE}}` block (3 lines max — agent already has
  context from initial invocation, just needs a reminder).

### 2. Medium-Impact Prompts (Tier 2 — Code-Analyzing Agents)

These agents analyze code and verify cross-references. Add the **standard
block** (see Section 4 below).

**`prompts/architect.prompt.md`:**
- Add `{{IF:SERENA_ACTIVE}}` block — drift analysis benefits from
  `find_referencing_symbols` to verify caller/callee relationships
- Strengthen existing `{{IF:REPO_MAP_CONTENT}}` block (lines 14-20) with
  preference language: "Use the repo map as your primary file discovery source.
  Do NOT use `find` or `grep` for broad file discovery."

**`prompts/specialist_security.prompt.md`:**
- Add standard `{{IF:SERENA_ACTIVE}}` block — security review should use
  `find_referencing_symbols` to trace data flow through auth/input handlers

**`prompts/specialist_performance.prompt.md`:**
- Add standard `{{IF:SERENA_ACTIVE}}` block — performance review benefits from
  `find_referencing_symbols` to identify hot-path callers

**`prompts/specialist_api.prompt.md`:**
- Add standard `{{IF:SERENA_ACTIVE}}` block — API review should verify contract
  consistency across endpoints using `find_symbol`

**Note:** `prompts/specialist_ui.prompt.md` exists but is out of scope for this
milestone — UI review doesn't typically need LSP-level code navigation.

### 3. Lower-Impact Prompts (Tier 3 — Brief Notes)

These are short-lived agents with narrow scope. Add a **one-line** Serena note.

**`prompts/jr_coder.prompt.md`:**
- Add brief `{{IF:SERENA_ACTIVE}}` note (jr coder fixes specific files, but
  may need to verify signatures)

**`prompts/architect_sr_rework.prompt.md`** and **`prompts/architect_jr_rework.prompt.md`:**
- Add brief `{{IF:SERENA_ACTIVE}}` notes for rework file discovery

**`prompts/build_fix_minimal.prompt.md`:**
- This prompt is currently ~1 line. Adding Serena guidance would triple it.
  Add a SINGLE line inside `{{IF:SERENA_ACTIVE}}`:
  "LSP tools available: `find_symbol`, `find_referencing_symbols` — use for
  import resolution."

### 4. Standardized Guidance Blocks

**Standard block (Tier 2):**
```markdown
{{IF:SERENA_ACTIVE}}
## LSP Tools Available
You have LSP tools via MCP: `find_symbol`, `find_referencing_symbols`,
`get_symbol_definition`. These provide exact cross-reference data.
**Prefer LSP tools over grep/find for symbol lookup.**
{{ENDIF:SERENA_ACTIVE}}
```

**Brief note (Tier 3):**
```markdown
{{IF:SERENA_ACTIVE}}
LSP tools available via MCP (`find_symbol`, `find_referencing_symbols`) —
prefer over grep for symbol lookup.
{{ENDIF:SERENA_ACTIVE}}
```

**Tier 1 prompts** get the standard block PLUS role-specific examples (see
Section 1 for per-prompt guidance).

### 5. Repo Map Preference Language

For prompts that have `{{IF:REPO_MAP_CONTENT}}` but lack preference instructions,
add explicit guidance inside the existing conditional block:

```markdown
Use the repo map as your primary file discovery source. Do NOT use `find` or
`grep` for broad file discovery — the repo map has already done that work.
```

Apply to:
- `tester.prompt.md` — has REPO_MAP_CONTENT block but no preference language
- `architect.prompt.md` — has REPO_MAP_CONTENT block, needs stronger language
- `coder_rework.prompt.md` — currently has NO REPO_MAP_CONTENT block (add one)

**Do NOT modify** prompts that already have strong preference language:
- `scout.prompt.md` (line 12-21) already says "Use it as your primary file
  discovery source instead of blind find/grep" — leave as-is
- `coder.prompt.md` already has adequate repo map guidance — leave as-is

### 6. Out-of-Scope Prompts

The following prompts are explicitly NOT modified by this milestone. They are
planning, interview, or synthesis prompts that don't do code-level file discovery:

- `plan_generate.prompt.md`, `plan_interview.prompt.md`, `plan_interview_followup.prompt.md`
- `init_synthesize_*.prompt.md`
- `intake_scan.prompt.md`, `notes_triage.prompt.md`
- `milestone_split.prompt.md`, `replan.prompt.md`, `clarification.prompt.md`
- `cleanup.prompt.md`, `analyze_cleanup.prompt.md`
- `seed_contracts.prompt.md`
- `tester_write_failing.prompt.md` (TDD mode — writes tests from spec, not code)
- `tester_ui_guidance.prompt.md` (UI-specific, not code navigation)
- `security_rework.prompt.md` (already gets full coder tools + reviewer report)

## Migration Impact

No new config keys. All additions are inside `{{IF:...}}` conditional blocks —
zero impact when Serena or repo map are disabled. Zero prompt size increase for
non-Serena, non-indexed runs.

## Acceptance Criteria

- All Tier 1 prompts have Serena + repo map guidance with role-specific examples
- All Tier 2 prompts have standard Serena guidance block
- All Tier 3 prompts have brief Serena notes
- No prompt has contradictory "use grep to find" instructions alongside Serena guidance
- All `{{IF:SERENA_ACTIVE}}` blocks render correctly:
  - With `SERENA_ACTIVE="true"` → block content appears
  - With `SERENA_ACTIVE=""` → block content is absent
- All `{{IF:REPO_MAP_CONTENT}}` blocks that this milestone touches include
  preference language
- All existing tests pass
- All modified prompt templates have balanced `{{IF:VAR}}` / `{{ENDIF:VAR}}` pairs
  (verify with: `grep -c 'IF:' file` == `grep -c 'ENDIF:' file` for each file)

Tests:
- Render each modified prompt with SERENA_ACTIVE=true — verify block appears
- Render each modified prompt with SERENA_ACTIVE="" — verify block is absent
- Render tester prompt with REPO_MAP_CONTENT populated — verify preference text
- Verify no modified prompt contains bare "use grep" or "use find" without it
  being inside a fallback conditional (e.g., scout's no-repo-map path is OK)
- Verify all `{{IF:*}}` / `{{ENDIF:*}}` pairs are balanced in modified files

Watch For:
- Prompt size inflation: each Serena block adds ~100-150 tokens. For the tester
  (which already has the longest prompt), keep additions to ≤15 lines. Verify
  rendered prompt stays within context budget using `_add_context_component`
  tracking in `lib/context.sh`.
- Don't over-instruct: the standard block should be brief. Claude already knows
  how to use MCP tools — the prompt just needs to say "prefer them."
- Conditional blocks must handle the case where Serena is available but the MCP
  server failed to start (SERENA_ACTIVE="" even though SERENA_ENABLED=true).
  This is correct behavior — `{{IF:SERENA_ACTIVE}}` handles it automatically.
- `scout.prompt.md` line 26 says "Use find, grep, and ls to locate files" — this
  is the no-repo-map fallback path and is intentional. Do NOT remove it.
- The template engine (`prompts.sh:101-127`) uses sed to strip `{{IF:VAR}}`
  markers. Ensure no prompt contains these markers as literal text (e.g., in
  documentation examples). If needed, escape with a backslash.

Seeds Forward:
- Tool-aware agents should show reduced grep/find usage in future runs
- M62 timing data can measure before/after impact on tester stage duration
