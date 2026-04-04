# Milestone 59: UI/UX Specialist Reviewer
<!-- milestone-meta
id: "59"
status: "pending"
-->

## Overview

Tekhton has three built-in specialist reviewers (security, performance, API) that
each provide focused, domain-expert review passes after the main reviewer approves.
UI/UX quality has no equivalent — the reviewer's 4-bullet `{{IF:UI_PROJECT_DETECTED}}`
block is thin compared to the 8-category checklists the specialists provide, and
there is no rework routing for accessibility violations or design system misuse.

This milestone adds a UI/UX specialist reviewer following the exact same pattern
as the existing specialists: a prompt template, auto-enablement logic, diff
relevance filtering, and findings consumption by the reviewer.

Depends on Milestone 57. Parallel-safe with M58 and M60 (uses the platform
adapter framework but doesn't require specific platform content — falls back to
universal checklist).

## Scope

### 1. Specialist Prompt (`prompts/specialist_ui.prompt.md` — NEW)

Follows the 6-section pattern established by `specialist_security.prompt.md`:

```markdown
You are a **UI/UX specialist reviewer** for {{PROJECT_NAME}}.

## Security Directive
[standard anti-prompt-injection block]

## Your Role
You perform a focused UI/UX quality review of code changes made by the coder
agent. You are NOT a general code reviewer — focus exclusively on user interface
quality, accessibility, and design consistency.

## Context
Task: {{TASK}}
{{IF:ARCHITECTURE_CONTENT}}
--- BEGIN FILE CONTENT: ARCHITECTURE ---
{{ARCHITECTURE_CONTENT}}
--- END FILE CONTENT: ARCHITECTURE ---
{{ENDIF:ARCHITECTURE_CONTENT}}

{{IF:DESIGN_SYSTEM}}
## Design System: {{DESIGN_SYSTEM}}
This project uses {{DESIGN_SYSTEM}} as its design system.
{{IF:DESIGN_SYSTEM_CONFIG}}
Configuration file: {{DESIGN_SYSTEM_CONFIG}} — read this to understand available
theme values, tokens, and component configurations.
{{ENDIF:DESIGN_SYSTEM_CONFIG}}
{{IF:COMPONENT_LIBRARY_DIR}}
Reusable component directory: {{COMPONENT_LIBRARY_DIR}} — check for existing
components before flagging missing abstractions.
{{ENDIF:COMPONENT_LIBRARY_DIR}}
{{ENDIF:DESIGN_SYSTEM}}

## Required Reading
1. `CODER_SUMMARY.md` — what was built and what files were touched
2. Only the files listed under 'Files created or modified' in CODER_SUMMARY.md
   that have UI-related extensions (.tsx, .jsx, .vue, .svelte, .css, .scss,
   .html, .dart, .swift, .kt, or files in components/pages/views/screens/widgets
   directories)
3. `{{PROJECT_RULES_FILE}}` — only if checking a specific UI/design rule

## UI/UX Review Checklist
Review the changed UI files against these criteria:

{{UI_SPECIALIST_CHECKLIST}}

## Required Output
Write `SPECIALIST_UI_FINDINGS.md` with this format:

# UI/UX Review Findings

## Blockers
- [BLOCKER] <file:line> — <description and remediation>
(or 'None')

## Notes
- [NOTE] <file:line> — <description and recommendation>
(or 'None')

## Summary
<1-2 sentence summary of UI/UX quality>

Rules:
- Use `[BLOCKER]` only for:
  - Accessibility violations that prevent keyboard/screen reader users from
    using the feature (missing focus management, no keyboard navigation,
    broken semantic structure)
  - Missing state handling that produces blank/broken screens (no loading
    state on async data, unhandled error state)
  - Design system violations that break visual consistency across the app
    (raw values where tokens exist, custom components duplicating library
    components)
- Use `[NOTE]` for:
  - Improvement suggestions for UX flow
  - Minor accessibility enhancements (better labels, improved contrast)
  - Performance optimizations (lazy loading, code splitting)
  - Platform convention suggestions that don't break functionality
- Be specific: include file paths, line numbers, and concrete fixes
- Do not flag issues in files that were NOT modified in this change
- Do not flag aesthetic preferences as blockers — those are notes
```

The `{{UI_SPECIALIST_CHECKLIST}}` variable is assembled by `load_platform_fragments()`
(M57): universal checklist + platform-specific additions. If no platform adapter
is resolved, only the universal checklist is injected.

### 2. Auto-Enable Logic (`lib/specialists.sh`)

Add UI specialist to the built-in specialist collection with auto-enable behavior:

```bash
# In run_specialist_reviews(), after collecting built-in specialists:

# UI specialist: auto-enable when UI project detected
local ui_enabled="${SPECIALIST_UI_ENABLED:-auto}"
if [[ "$ui_enabled" == "auto" ]]; then
    if [[ "${UI_PROJECT_DETECTED:-}" == "true" ]]; then
        ui_enabled="true"
    else
        ui_enabled="false"
    fi
fi
if [[ "$ui_enabled" == "true" ]]; then
    specialists+=("ui")
fi
```

This is distinct from the other specialists which default to `false`. The `auto`
value means: "enable me when the detection engine says this is a UI project."
Users can explicitly set `SPECIALIST_UI_ENABLED=false` to disable it even for
UI projects.

### 3. Diff Relevance Filter (`lib/specialists.sh`)

Add a `ui)` case to `_specialist_diff_relevant()`:

```bash
ui)
    relevance_patterns='\.tsx$|\.jsx$|\.vue$|\.svelte$|\.css$|\.scss$|\.sass$|\.less$|\.html$|\.dart$|\.swift$|\.kt$|\.kts$|/components/|/pages/|/views/|/screens/|/widgets/|/scenes/|/ui/|/styles/|/theme/|\.storyboard$|\.xib$'
    ;;
```

This is intentionally broad — the UI specialist should run whenever any visual
file is touched. False positives (running on a non-visual `.kt` file) are
low-cost because the specialist reads `CODER_SUMMARY.md` first and scopes to
UI-related files within it.

### 4. Findings Consumption (`prompts/reviewer.prompt.md`)

Add a `{{IF:UI_FINDINGS_BLOCK}}` section to the reviewer prompt, following the
same pattern as `{{SECURITY_FINDINGS_BLOCK}}`:

```markdown
{{IF:UI_FINDINGS_BLOCK}}
## UI/UX Findings (from UI Specialist)
The following UI/UX findings were identified by the UI specialist reviewer.
Do not duplicate the UI specialist's work — focus on code quality and correctness.
{{UI_FINDINGS_BLOCK}}
{{ENDIF:UI_FINDINGS_BLOCK}}
```

Insert after the existing `{{IF:SECURITY_FINDINGS_BLOCK}}` block.

The `UI_FINDINGS_BLOCK` variable is populated the same way `SECURITY_FINDINGS_BLOCK`
is — by reading `SPECIALIST_UI_FINDINGS.md` after the specialist runs.

### 5. Variable Export for Prompt Rendering

Ensure the following variables are exported before prompt rendering when the UI
specialist is active:

- `DESIGN_SYSTEM` — from platform detect.sh
- `DESIGN_SYSTEM_CONFIG` — from platform detect.sh
- `COMPONENT_LIBRARY_DIR` — from platform detect.sh
- `UI_SPECIALIST_CHECKLIST` — from `load_platform_fragments()`
- `UI_FINDINGS_BLOCK` — from specialist output (populated after specialist runs)

These are already set by M57's pipeline integration; this milestone just ensures
the specialist prompt template references them correctly.

### 6. Coder Rework Integration

When the UI specialist reports `[BLOCKER]` items, the rework loop in
`stages/review.sh` already handles this via the existing `_route_specialist_rework()`
function — specialist blockers are aggregated into `SPECIALIST_BLOCKERS` and
trigger a rework cycle. No changes needed to the rework routing.

The `coder_rework.prompt.md` already receives specialist findings context via
the reviewer's report. No changes needed to the rework prompt.

### 7. Self-Tests

Add to `tests/`:

- `test_specialist_ui.sh` — Tests:
  - UI specialist is collected when `SPECIALIST_UI_ENABLED=true`
  - UI specialist is collected when `SPECIALIST_UI_ENABLED=auto` and
    `UI_PROJECT_DETECTED=true`
  - UI specialist is NOT collected when `SPECIALIST_UI_ENABLED=auto` and
    `UI_PROJECT_DETECTED` is unset
  - UI specialist is NOT collected when `SPECIALIST_UI_ENABLED=false`
  - Diff relevance filter matches `.tsx`, `.vue`, `.dart`, `.swift`, `.kt`,
    `/components/`, `/screens/`, `/widgets/` patterns
  - Diff relevance filter does NOT match `.go`, `.py`, `.rs` (non-UI files)
  - `specialist_ui.prompt.md` renders without errors (no unresolved `{{VAR}}`
    when required variables are set)

## Acceptance Criteria

- [ ] `prompts/specialist_ui.prompt.md` follows the established specialist
      prompt pattern (6 sections, `[BLOCKER]`/`[NOTE]` output format)
- [ ] `SPECIALIST_UI_ENABLED=auto` enables the specialist when
      `UI_PROJECT_DETECTED=true` and disables it otherwise
- [ ] `SPECIALIST_UI_ENABLED=false` disables the specialist even for UI projects
- [ ] `SPECIALIST_UI_ENABLED=true` enables the specialist even for non-UI projects
- [ ] Diff relevance filter correctly identifies UI-related files across all
      supported platform file extensions
- [ ] `{{UI_SPECIALIST_CHECKLIST}}` is injected from the platform adapter's
      specialist checklist (universal + platform-specific)
- [ ] `{{UI_FINDINGS_BLOCK}}` is injected into the reviewer prompt after the
      specialist runs
- [ ] `[BLOCKER]` items from the UI specialist trigger rework via the existing
      specialist rework routing
- [ ] The specialist prompt includes design system context (`{{DESIGN_SYSTEM}}`,
      `{{DESIGN_SYSTEM_CONFIG}}`, `{{COMPONENT_LIBRARY_DIR}}`) when detected
- [ ] All existing tests pass
- [ ] New test file `test_specialist_ui.sh` passes

## Files Created
- `prompts/specialist_ui.prompt.md`
- `tests/test_specialist_ui.sh`

## Files Modified
- `lib/specialists.sh` (add UI specialist collection, auto-enable logic,
  diff relevance case)
- `prompts/reviewer.prompt.md` (add `{{IF:UI_FINDINGS_BLOCK}}` section)
