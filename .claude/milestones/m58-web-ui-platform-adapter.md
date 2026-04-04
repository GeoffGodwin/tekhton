# Milestone 58: Web UI Platform Adapter
<!-- milestone-meta
id: "58"
status: "pending"
-->

## Overview

With the platform adapter framework (M57) in place, this milestone populates the
`platforms/web/` directory — the first and most common platform adapter. It provides
design system detection for web projects, coder guidance for CSS frameworks and
component libraries, a specialist review checklist for web-specific concerns, and
tester patterns that migrate and expand the existing `tester_ui_guidance.prompt.md`.

Depends on Milestone 57.

## Scope

### 1. Web Design System Detection (`platforms/web/detect.sh`)

A shell script sourced by `source_platform_detect()` from `_base.sh`. Detects:

**CSS Frameworks:**
- Tailwind CSS: `tailwind.config.ts`, `tailwind.config.js`, `tailwind.config.cjs`,
  `tailwind.config.mjs`, or `tailwindcss` in `package.json` deps →
  `DESIGN_SYSTEM=tailwind`, `DESIGN_SYSTEM_CONFIG=<config file path>`
- Bootstrap: `bootstrap` in `package.json` deps → `DESIGN_SYSTEM=bootstrap`
- Bulma: `bulma` in `package.json` deps → `DESIGN_SYSTEM=bulma`
- UnoCSS: `unocss` or `@unocss` in `package.json` deps →
  `DESIGN_SYSTEM=unocss`, `DESIGN_SYSTEM_CONFIG=uno.config.ts` (if exists)

**Component Libraries:**
- MUI: `@mui/material` in deps → `DESIGN_SYSTEM=mui` (overrides CSS framework)
- Chakra UI: `@chakra-ui/react` in deps → `DESIGN_SYSTEM=chakra`
- shadcn/ui: `components.json` with shadcn schema → `DESIGN_SYSTEM=shadcn`
- Radix: `@radix-ui/react-*` in deps (without shadcn) → `DESIGN_SYSTEM=radix`
- Ant Design: `antd` in deps → `DESIGN_SYSTEM=antd`
- Headless UI: `@headlessui/react` or `@headlessui/vue` → `DESIGN_SYSTEM=headlessui`
- Vuetify: `vuetify` in deps → `DESIGN_SYSTEM=vuetify`
- Element Plus: `element-plus` in deps → `DESIGN_SYSTEM=element-plus`

Component libraries take precedence over CSS frameworks when both are present
(e.g., a project using MUI + Tailwind reports `DESIGN_SYSTEM=mui`).

**Design Tokens:**
- Tailwind theme: if `DESIGN_SYSTEM=tailwind`, set `DESIGN_SYSTEM_CONFIG` to the
  config file path (the theme section contains the tokens)
- CSS custom property files: scan for `variables.css`, `variables.scss`,
  `tokens.css`, `tokens.scss`, `theme.css`, `theme.scss` in `src/` and root →
  set `DESIGN_SYSTEM_CONFIG` if found and not already set

**Component Directory:**
- Scan for: `src/components/ui/`, `src/components/common/`, `src/ui/`,
  `components/ui/`, `components/common/`, `app/components/ui/`
- Set `COMPONENT_LIBRARY_DIR` to the first existing directory

**Implementation notes:**
- Uses the same grep-based `package.json` parsing as `detect.sh` (`_extract_json_keys`,
  `_check_dep`) — no jq dependency
- Must `source "${TEKHTON_HOME}/lib/detect.sh"` is already loaded (it is, since
  `_base.sh` is sourced after detect.sh)
- All detection is best-effort — missing signals result in empty variables, not errors
- Must pass `shellcheck` and `bash -n`

### 2. Web Coder Guidance (`platforms/web/coder_guidance.prompt.md`)

Platform-specific coder guidance appended after the universal guidance. Content:

**CSS & Styling:**
- Use the project's CSS methodology. If Tailwind: use utility classes, avoid
  `@apply` for one-off styles, use theme values (`text-primary`, `bg-surface`)
  not raw hex/rgb. If CSS modules: scope styles to components. If styled-components
  or CSS-in-JS: colocate styles with components.
- Never use `!important` unless overriding a third-party library.
- Use relative units (`rem`, `em`, `%`, `vw/vh`) over absolute `px` for layout.
  `px` is acceptable for borders, shadows, and icon sizes.
- Responsive: mobile-first with `min-width` breakpoints. Use the project's
  breakpoint system (Tailwind config, CSS variables, or framework breakpoints).
  Test at 375px (mobile), 768px (tablet), 1280px (desktop) minimum.

**Component Patterns:**
- React: functional components with hooks. Props interface defined with TypeScript
  types. Forward refs on interactive components. Use `children` for composition.
- Vue: Single File Components with `<script setup>` (Vue 3) or Options API matching
  project convention. Scoped styles. Props with type validation.
- Svelte: Component props with `export let`. Reactive declarations. Scoped styles
  by default.
- Angular: Component decorator with appropriate change detection. Input/Output
  decorators. OnPush when possible.
- Use the project's state management pattern. Don't introduce a new state library.

**Web Accessibility (WCAG 2.1 AA):**
- Semantic HTML: `<button>` for actions, `<a>` for navigation, `<nav>`, `<main>`,
  `<article>`, `<section>` with accessible names.
- Form inputs: `<label>` elements associated with inputs. Error messages linked
  with `aria-describedby`. Required fields marked with `aria-required`.
- Focus management: visible focus indicators on all interactive elements. Focus
  moves logically with tabbing. Focus trapped in modals. Focus restored on
  modal close.
- Dynamic content: `aria-live` regions for async updates. Loading states
  announced to screen readers. Route changes announced.
- Color: do not convey information through color alone. Minimum 4.5:1 contrast
  for normal text, 3:1 for large text.

**Performance:**
- Lazy-load routes and heavy components. Use dynamic `import()` for code splitting.
- Images: use `loading="lazy"`, provide `width`/`height` or aspect ratio, use
  appropriate format (WebP with fallback).
- Avoid layout shift: reserve space for async content (skeleton screens, fixed
  dimensions on media elements).

### 3. Web Specialist Checklist (`platforms/web/specialist_checklist.prompt.md`)

Web-specific additions to the universal 8-category checklist:

1. **CSS specificity management** — No `!important` cascading. Styles don't leak
   between components. CSS module or scoped styles used consistently.
2. **SSR/hydration correctness** — If the project uses SSR (Next.js, Nuxt, SvelteKit),
   verify no hydration mismatches. No `window`/`document` access during server render
   without guards. Dynamic content handled with client-only wrappers.
3. **Bundle impact** — New dependencies are justified. No full-library imports when
   tree-shakeable alternatives exist (e.g., `import { Button } from '@mui/material'`
   not `import * as MUI`).
4. **Progressive enhancement** — Core functionality works without JavaScript where
   feasible. Form submissions have server-side handling if applicable.
5. **SEO considerations** — Pages have appropriate `<title>`, `<meta description>`,
   heading hierarchy. Dynamic routes have meaningful URLs.
6. **Asset optimization** — Images have alt text and appropriate dimensions. Fonts
   loaded with `font-display: swap` or equivalent. No render-blocking resources
   in critical path.

### 4. Web Tester Patterns (`platforms/web/tester_patterns.prompt.md`)

Migrate the content from `prompts/tester_ui_guidance.prompt.md` into this file.
The existing content covers:
- Decision tree for E2E test writing
- Page load, form submission, navigation patterns
- Framework-specific code examples (Playwright, Cypress, Selenium, Puppeteer,
  Testing Library, Detox)
- Anti-patterns

Add new patterns not in the existing file:
- **State management UI**: Assert loading spinner/skeleton visible during fetch,
  error message renders on API failure, empty state component shows when data
  array is empty
- **Modal/dialog behavior**: Focus moves into modal on open, escape key closes,
  click-outside closes (if applicable), focus returns to trigger on close,
  background scroll is locked
- **Keyboard navigation**: Tab order follows visual order, enter/space activates
  buttons and links, arrow keys navigate within menus/listboxes, escape closes
  dropdowns and overlays
- **Focus management**: After route change focus moves to main content or page
  title, after modal close focus returns to trigger element, skip-to-content
  link present and functional
- **Responsive behavior**: Test at mobile (375px) and desktop (1280px) viewports,
  navigation collapses to mobile menu, content reflows without horizontal scroll,
  touch targets meet minimum 44x44px

### 5. Backward Compatibility

The existing `prompts/tester_ui_guidance.prompt.md` is NOT deleted. The
`tester.prompt.md` template continues to use `{{TESTER_UI_GUIDANCE}}`. The
pipeline logic in `stages/tester.sh` (or wherever `TESTER_UI_GUIDANCE` is
assembled) is updated:

```bash
# If platform adapter provided tester patterns, use those
if [[ -n "${UI_TESTER_PATTERNS:-}" ]]; then
    export TESTER_UI_GUIDANCE="$UI_TESTER_PATTERNS"
else
    # Fall back to legacy monolithic file
    TESTER_UI_GUIDANCE=$(_safe_read_file "${TEKHTON_HOME}/prompts/tester_ui_guidance.prompt.md" "tester_ui_guidance")
    export TESTER_UI_GUIDANCE
fi
```

This ensures existing pipelines that don't resolve a platform adapter still get
the original tester UI guidance.

### 6. Self-Tests

Add to `tests/`:

- `test_platform_web.sh` — Tests:
  - `detect.sh` correctly identifies Tailwind, MUI, shadcn, Bootstrap, and other
    design systems from mock `package.json` files
  - Component directory detection finds `src/components/ui/`
  - Design system config path is correctly set
  - CSS custom property file detection works
  - Fragment files are syntactically valid (no broken markdown)

## Acceptance Criteria

- [ ] `platforms/web/detect.sh` passes `bash -n` and `shellcheck`
- [ ] Design system detection correctly identifies Tailwind, MUI, shadcn, Chakra,
      Ant Design, Radix, Headless UI, Bootstrap, Bulma, UnoCSS, Vuetify, Element Plus
- [ ] `DESIGN_SYSTEM_CONFIG` points to the correct config file for Tailwind and
      UnoCSS projects
- [ ] `COMPONENT_LIBRARY_DIR` is set when a component directory exists
- [ ] Component libraries take precedence over CSS frameworks in `DESIGN_SYSTEM`
- [ ] `coder_guidance.prompt.md` contains web-specific CSS, component, a11y, and
      performance guidance
- [ ] `specialist_checklist.prompt.md` adds web-specific review items to the
      universal checklist
- [ ] `tester_patterns.prompt.md` contains all content from the existing
      `tester_ui_guidance.prompt.md` plus new state/modal/keyboard/focus/responsive
      patterns
- [ ] Existing `tester_ui_guidance.prompt.md` is preserved as fallback
- [ ] `UI_TESTER_PATTERNS` overrides `TESTER_UI_GUIDANCE` when platform adapter
      provides it
- [ ] All existing tests pass
- [ ] New test file `test_platform_web.sh` passes

## Files Created
- `platforms/web/detect.sh`
- `platforms/web/coder_guidance.prompt.md`
- `platforms/web/specialist_checklist.prompt.md`
- `platforms/web/tester_patterns.prompt.md`
- `tests/test_platform_web.sh`

## Files Modified
- `stages/tester.sh` or `lib/prompts.sh` (TESTER_UI_GUIDANCE assembly logic)
