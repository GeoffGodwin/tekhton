# Milestone 57: UI Platform Adapter Framework
<!-- milestone-meta
id: "57"
status: "done"
-->

## Overview

Tekhton's UI awareness is currently web-centric and hardcoded: a handful of
`{{IF:UI_PROJECT_DETECTED}}` blocks in scout, reviewer, and tester prompts
inject the same guidance regardless of whether the project is a React SPA, a
Flutter mobile app, a SwiftUI iOS app, or a Phaser browser game. The coder
prompt has no UI block at all.

This milestone establishes a **platform adapter framework** — a file-based
convention where each UI platform (web, mobile_flutter, mobile_native_ios,
mobile_native_android, game_web) provides detection logic, coder guidance,
specialist review criteria, and tester patterns as files in a named directory.

Depends on Milestone 56. Seeds Milestones 58 (web adapter), 59 (UI specialist),
and 60 (mobile & game adapters).

## Scope

### 1. Platform Directory Structure (`platforms/` — NEW)

Create the `platforms/` directory at the Tekhton repo root:

```
platforms/
├── _base.sh                            # Platform resolution + fragment loading
├── _universal/                         # Always-included guidance
│   ├── coder_guidance.prompt.md        # Universal UI coder guidance
│   └── specialist_checklist.prompt.md  # Universal specialist checklist
├── web/                                # (populated by M58)
├── mobile_flutter/                     # (populated by M60)
├── mobile_native_ios/                  # (populated by M60)
├── mobile_native_android/              # (populated by M60)
└── game_web/                           # (populated by M60)
```

Platform directories are created as empty directories with a `.gitkeep` for M58
and M60 to populate. Only `_base.sh` and `_universal/` contain content in this
milestone.

### 2. Platform Resolution (`platforms/_base.sh`)

New file sourced by `tekhton.sh` after `detect.sh`. Provides:

**`detect_ui_platform()`** — Maps the already-detected `UI_FRAMEWORK` and
project type to a platform directory name. Resolution rules:

| Detected Framework/Signal | Project Type | Platform Dir |
|--------------------------|-------------|-------------|
| `flutter` | any | `mobile_flutter` |
| `swiftui` | any | `mobile_native_ios` |
| Package.swift + UIKit signals | any | `mobile_native_ios` |
| `jetpack-compose` / Kotlin + Android signals | any | `mobile_native_android` |
| `phaser` / `pixi` / `three` / `babylon` | any | `game_web` |
| `react` / `vue` / `svelte` / `angular` / `next.js` | any | `web` |
| `playwright` / `cypress` / `testing-library` / `puppeteer` | any | `web` |
| `generic` (2+ UI signals) | `web-game` | `game_web` |
| `generic` (2+ UI signals) | `mobile-app` | `mobile_flutter` |
| `generic` (2+ UI signals) | any other | `web` |
| (none — `UI_PROJECT_DETECTED` is false) | any | (empty — skip) |

The function:
- Checks `UI_PLATFORM` config first — if set to anything other than `auto`, uses
  that value directly (supports `custom_<name>` for user-defined platforms)
- Falls through to auto-detection only when `UI_PLATFORM=auto` or empty
- Sets `UI_PLATFORM` and `UI_PLATFORM_DIR` globals
- Returns 0 if a platform was resolved, 1 if not (non-UI project)

**`load_platform_fragments()`** — Reads `.prompt.md` files from the resolved
platform directory and assembles them into prompt variables:

1. Read `_universal/coder_guidance.prompt.md` → start of `UI_CODER_GUIDANCE`
2. Read `<platform>/coder_guidance.prompt.md` → append to `UI_CODER_GUIDANCE`
3. Read `_universal/specialist_checklist.prompt.md` → start of `UI_SPECIALIST_CHECKLIST`
4. Read `<platform>/specialist_checklist.prompt.md` → append to `UI_SPECIALIST_CHECKLIST`
5. Read `<platform>/tester_patterns.prompt.md` → set `UI_TESTER_PATTERNS`

For each file, also check `${PROJECT_DIR}/.claude/platforms/<platform>/` for a
user override file. If present, append its content after the built-in content.

If a platform directory or file doesn't exist, skip it gracefully (the universal
layer is always present).

Sets globals: `UI_CODER_GUIDANCE`, `UI_SPECIALIST_CHECKLIST`, `UI_TESTER_PATTERNS`

**`source_platform_detect()`** — Sources the platform's `detect.sh` if it exists:
1. Source `${TEKHTON_HOME}/platforms/<platform>/detect.sh`
2. Source `${PROJECT_DIR}/.claude/platforms/<platform>/detect.sh` (user override)

The platform detect scripts are expected to set: `DESIGN_SYSTEM`,
`DESIGN_SYSTEM_CONFIG`, `COMPONENT_LIBRARY_DIR`. These are optional — if a
platform's detect.sh doesn't set them, they remain empty.

**Helper functions:**

- `_read_platform_file()` — Reads a file with 1MB size limit (same safety as
  `_safe_read_file` in prompts.sh). Returns content or empty string.
- `_resolve_platform_dir()` — Returns the full path to the built-in platform
  directory, or empty if it doesn't exist.
- `_resolve_user_platform_dir()` — Returns the full path to the user's platform
  override directory, or empty if it doesn't exist.

### 3. Universal UI Guidance (`platforms/_universal/`)

**`coder_guidance.prompt.md`** — Platform-agnostic UI guidance for the coder:

- **State presentation**: Every view/screen/component that fetches data MUST handle
  loading, error, and empty states. No blank screens while data loads.
- **Accessibility floor**: Use semantic elements/widgets over generic containers.
  Every interactive element must be reachable via keyboard/gesture navigation.
  Provide text alternatives for images. Ensure sufficient contrast. Support
  screen reader announcements for dynamic content changes.
- **Component composition**: Prefer small, reusable components with clear prop/parameter
  interfaces. Separate data fetching from presentation. Avoid prop drilling beyond
  2 levels — use context/provider/state management.
- **Adaptive layout**: Design for the narrowest supported viewport first. Use the
  project's existing breakpoint/layout system — do not invent new breakpoints.
- **Design system adherence**: If a design system is detected (see below), use its
  tokens, components, and patterns. Do not use raw color values, pixel sizes, or
  custom components when the design system provides an equivalent.

**`specialist_checklist.prompt.md`** — Universal 8-category review checklist:

1. **Component structure & reusability** — Components have clear single responsibility.
   Props/parameters are typed. No god-components doing everything.
2. **Design system / token consistency** — Uses project design tokens for colors,
   spacing, typography. No hardcoded values that bypass the design system.
3. **Responsive / adaptive behavior** — Layout adapts correctly to supported viewport
   sizes. No horizontal overflow. Touch targets meet minimum size (44x44pt iOS,
   48x48dp Android, 44x44px web).
4. **Accessibility** — Semantic structure. Keyboard/gesture navigable. Screen reader
   labels on interactive elements. Sufficient color contrast. Focus management on
   navigation/modal changes.
5. **State presentation** — Loading, error, and empty states are handled. No
   unhandled promise/future rejections that produce blank screens.
6. **Interaction patterns** — Form validation provides inline feedback. Modals/sheets
   trap focus and support dismiss. Navigation is consistent with platform conventions.
7. **Visual hierarchy & layout consistency** — Heading levels are sequential. Spacing
   follows a consistent rhythm. Typography scale matches project conventions.
8. **Platform convention adherence** — Follows platform-specific guidelines (HIG for
   iOS, Material for Android, WCAG for web, engine best practices for games).

### 4. Pipeline Integration

**`tekhton.sh` changes:**

Add `source "${TEKHTON_HOME}/platforms/_base.sh"` after the existing detection
engine sourcing. Call the platform resolution functions after `detect_ui_framework()`:

```bash
# After existing detection calls:
if [[ "${UI_PROJECT_DETECTED:-}" == "true" ]]; then
    detect_ui_platform
    if [[ -n "${UI_PLATFORM_DIR:-}" ]]; then
        source_platform_detect
        load_platform_fragments
    fi
fi
```

**`coder.prompt.md` changes:**

Add a UI guidance block (currently absent from the coder prompt):

```markdown
{{IF:UI_CODER_GUIDANCE}}

## UI Implementation Guidance
This is a UI project. Follow these guidelines for visual implementation.

{{UI_CODER_GUIDANCE}}
{{ENDIF:UI_CODER_GUIDANCE}}
```

Insert after the `{{IF:AFFECTED_TEST_FILES}}` block and before the
`## Test Maintenance` section.

If `DESIGN_SYSTEM` is detected, append a block to `UI_CODER_GUIDANCE`:

```
### Design System: {DESIGN_SYSTEM}
This project uses {DESIGN_SYSTEM}. Configuration: {DESIGN_SYSTEM_CONFIG}.
Use its tokens, components, and patterns. Do not use raw values when the
design system provides an equivalent. Read the config file for available
theme values.
```

If `COMPONENT_LIBRARY_DIR` is detected, also append:

```
### Reusable Components
Check {COMPONENT_LIBRARY_DIR} for existing components before creating new ones.
```

**`scout.prompt.md` changes:**

Expand the existing `{{IF:UI_PROJECT_DETECTED}}` block to also request:
- Identify the design system in use (component library, theme configuration)
- List existing reusable components relevant to the task
- Note the project's breakpoint/adaptive layout conventions

**`tester.prompt.md` changes:**

Replace the hardcoded `{{TESTER_UI_GUIDANCE}}` injection with
`{{UI_TESTER_PATTERNS}}` when the platform adapter provides it. Fall back to
the existing `tester_ui_guidance.prompt.md` content when no platform adapter
is resolved (backward compatibility).

**`config_defaults.sh` changes:**

Add defaults:
```bash
UI_PLATFORM="${UI_PLATFORM:-auto}"
SPECIALIST_UI_ENABLED="${SPECIALIST_UI_ENABLED:-auto}"
SPECIALIST_UI_MODEL="${SPECIALIST_UI_MODEL:-${CLAUDE_STANDARD_MODEL}}"
SPECIALIST_UI_MAX_TURNS="${SPECIALIST_UI_MAX_TURNS:-8}"
```

### 5. User Override Support

When `load_platform_fragments()` processes each fragment type, it checks:
1. `${TEKHTON_HOME}/platforms/<platform>/<file>` (built-in)
2. `${PROJECT_DIR}/.claude/platforms/<platform>/<file>` (user override — appended)

User files are **appended** to built-in content, not replacing it. This ensures
universal guidance is always present.

A fully custom platform is supported by setting `UI_PLATFORM=custom_<name>` in
`pipeline.conf`. The platform resolution skips auto-detection and looks directly
for `${PROJECT_DIR}/.claude/platforms/custom_<name>/` (user-provided) or
`${TEKHTON_HOME}/platforms/custom_<name>/` (if someone adds one to Tekhton).

### 6. Self-Tests

Add to `tests/`:

- `test_platform_base.sh` — Tests `detect_ui_platform()` resolution for each
  framework → platform mapping. Tests `load_platform_fragments()` with mock
  platform directories. Tests user override append behavior. Tests custom
  platform resolution. Tests graceful fallback when platform dir doesn't exist.

## Acceptance Criteria

- [ ] `platforms/_base.sh` passes `bash -n` and `shellcheck`
- [ ] `detect_ui_platform()` correctly maps all framework values from
      `detect_ui_framework()` to platform directory names
- [ ] `load_platform_fragments()` assembles `UI_CODER_GUIDANCE` from universal +
      platform content
- [ ] User override files in `.claude/platforms/<name>/` are appended to built-in
      content
- [ ] `UI_PLATFORM=custom_<name>` skips auto-detection and resolves to the named
      platform directory
- [ ] `coder.prompt.md` renders `{{UI_CODER_GUIDANCE}}` when `UI_PROJECT_DETECTED=true`
- [ ] Non-UI projects see no prompt changes (variables are empty, conditional blocks
      are stripped)
- [ ] `_universal/coder_guidance.prompt.md` and `_universal/specialist_checklist.prompt.md`
      contain the universal guidance content
- [ ] All existing tests pass
- [ ] New test file `test_platform_base.sh` passes

## Files Created
- `platforms/_base.sh`
- `platforms/_universal/coder_guidance.prompt.md`
- `platforms/_universal/specialist_checklist.prompt.md`
- `platforms/web/.gitkeep`
- `platforms/mobile_flutter/.gitkeep`
- `platforms/mobile_native_ios/.gitkeep`
- `platforms/mobile_native_android/.gitkeep`
- `platforms/game_web/.gitkeep`
- `tests/test_platform_base.sh`

## Files Modified
- `tekhton.sh` (source _base.sh, call platform resolution after detection)
- `prompts/coder.prompt.md` (add `{{IF:UI_CODER_GUIDANCE}}` block)
- `prompts/scout.prompt.md` (expand UI component identification block)
- `lib/config_defaults.sh` (add UI_PLATFORM, SPECIALIST_UI_* defaults)
