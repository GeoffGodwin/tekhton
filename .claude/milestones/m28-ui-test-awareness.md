#### Milestone 28: UI Test Awareness & E2E Prompt Integration
<!-- milestone-meta
id: "28"
status: "done"
-->

Teach the pipeline that user interfaces exist and require UI-level testing.
Update prompts across PM agent, tester, scout, and reviewer to detect UI
projects, require UI-verifiable acceptance criteria, and guide the tester
toward writing E2E tests when appropriate. Add UI_TEST_CMD and
UI_FRAMEWORK config keys so projects with existing E2E infrastructure
(Playwright, Cypress, Selenium, etc.) get those tests run as part of the
pipeline.

This milestone is prompt-and-config changes only — no new infrastructure.
It addresses the root cause of the Watchtower class of bug: milestones
that produce UI artifacts pass all acceptance criteria while the actual
visual output is broken, because nobody thought to test at the UI level.

Files to create:
- `prompts/tester_ui_guidance.prompt.md` — Conditional block injected into
  the tester prompt when a UI project is detected. Contains:
  - Framework-specific E2E test guidance for the top 6 frameworks:
    Playwright, Cypress, Selenium, Puppeteer, Testing Library, Detox (mobile)
  - A decision tree: "If the milestone creates/modifies UI components,
    write E2E tests that verify rendering and interaction, not just logic."
  - Common UI test patterns: page loads without errors, critical elements
    visible, form submission works, navigation functions, responsive breakpoints
  - Anti-patterns: "Don't test implementation details (CSS class names,
    DOM structure). Test user-visible behavior."
  - The guidance adapts based on UI_FRAMEWORK config: if Playwright is
    configured, give Playwright-specific examples. If no framework configured,
    give framework-agnostic guidance and recommend Playwright as default.

Files to modify:
- `lib/config_defaults.sh` — Add:
  UI_TEST_CMD="" (command to run E2E/UI tests, separate from TEST_CMD),
  UI_FRAMEWORK="" (playwright|cypress|selenium|puppeteer|testing-library|
  detox|auto|"" — auto detects from project, "" disables UI awareness),
  UI_PROJECT_DETECTED=false (set by detection engine, not user-configured),
  UI_VALIDATION_ENABLED=true (enable UI validation gate when UI detected).

- `lib/config.sh` — Validate UI_FRAMEWORK is one of the known values or
  empty. Validate UI_TEST_CMD is a runnable command when set.

- `lib/detect.sh` — Add UI project detection to the existing detection engine:
  New function: `detect_ui_framework($project_dir)` checks for:
  - Playwright: playwright.config.ts/js, @playwright/test in package.json
  - Cypress: cypress.config.ts/js, cypress/ directory
  - Selenium: selenium in requirements.txt/pom.xml, webdriver configs
  - Testing Library: @testing-library/* in package.json
  - Detox: .detoxrc.js, detox in package.json
  - Generic web UI: src/**/*.tsx, src/**/*.vue, src/**/*.svelte,
    templates/**/*.html, app/views/**/*.erb
  Sets UI_PROJECT_DETECTED=true and UI_FRAMEWORK when found.
  Detection runs during --init AND at pipeline startup (cached in session).

- `lib/detect_commands.sh` — Add UI test command detection:
  When UI framework detected, infer UI_TEST_CMD:
  - Playwright: "npx playwright test"
  - Cypress: "npx cypress run"
  - package.json scripts containing "e2e", "test:e2e", "test:ui"
  - CI/CD config referencing E2E test steps
  CI source takes priority (same cascade as TEST_CMD detection in M12).

- `stages/intake.sh` — Update PM agent context injection:
  When UI_PROJECT_DETECTED=true, inject a UI awareness block into the
  intake prompt: "This is a UI project using {{UI_FRAMEWORK}}. Milestones
  that create or modify user-facing components should include UI-verifiable
  acceptance criteria (e.g., 'page loads without console errors', 'form
  submits and shows confirmation', 'component renders at mobile breakpoint').
  Flag milestones that produce UI artifacts without such criteria."

- `prompts/intake_scan.prompt.md` — Add to the clarity rubric:
  "(7) If this milestone produces or modifies UI components and the project
  has UI testing infrastructure, do the acceptance criteria include at least
  one UI-verifiable criterion? If not, flag for addition."

- `prompts/tester.prompt.md` — Add conditional UI guidance block:
  `{{IF:UI_PROJECT_DETECTED}}
  {{TESTER_UI_GUIDANCE}}
  {{ENDIF:UI_PROJECT_DETECTED}}`
  Where TESTER_UI_GUIDANCE is rendered from tester_ui_guidance.prompt.md
  with framework-specific content based on UI_FRAMEWORK.

- `prompts/scout.prompt.md` — Add UI component identification:
  "When examining files in scope, identify any UI components (React
  components, Vue templates, HTML files, CSS/SCSS modules). Note these
  in your scout report under a '## UI Components in Scope' section so
  the tester knows to write E2E tests for them."

- `prompts/reviewer.prompt.md` — Add UI review awareness:
  `{{IF:UI_PROJECT_DETECTED}}
  ## UI Review Considerations
  This is a UI project. When reviewing changes to UI components, verify:
  - CSS/style changes don't break existing visual layouts (check for
    removed classes still referenced elsewhere)
  - New components have corresponding E2E test coverage (if not, add
    to Coverage Gaps, not blockers — the tester handles this)
  - Interactive elements (buttons, forms, links) have event handlers
  - Accessibility attributes present (aria-label, role, alt text)
  {{ENDIF:UI_PROJECT_DETECTED}}`

- `lib/gates.sh` — Add UI test execution to the build gate:
  After the standard BUILD_CHECK_CMD and ANALYZE_CMD, if UI_TEST_CMD
  is set and non-empty, run it. Parse exit code:
  - 0: UI tests pass, continue
  - Non-zero: UI tests failed, write UI_TEST_ERRORS.md with output,
    route to coder rework (same as build failure)
  If UI_TEST_CMD is set but the command is not found (e.g., Playwright
  not installed), log a WARNING but do not fail the gate. Include the
  warning in CODER_SUMMARY.md so the reviewer sees it.

- `lib/prompts.sh` — Register template variables:
  UI_PROJECT_DETECTED, UI_FRAMEWORK, UI_TEST_CMD,
  TESTER_UI_GUIDANCE (rendered from tester_ui_guidance.prompt.md).

- `templates/pipeline.conf.example` — Add UI testing section:
  ```
  # --- UI Testing ---
  # UI_TEST_CMD=""           # E2E test command (e.g., "npx playwright test")
  # UI_FRAMEWORK=""          # auto | playwright | cypress | selenium | ...
  # UI_VALIDATION_ENABLED=true  # Enable UI validation gate
  ```

Acceptance criteria:
- `detect_ui_framework()` correctly identifies Playwright, Cypress,
  Selenium, Testing Library, and Detox from config files and dependencies
- Generic web UI detection works for React, Vue, Svelte, Rails, Django
  template projects without explicit E2E framework
- UI_TEST_CMD auto-detected from package.json scripts and CI config
- PM agent flags milestones producing UI artifacts without UI-verifiable
  acceptance criteria
- Tester agent receives framework-specific E2E test guidance when
  UI_PROJECT_DETECTED=true
- Scout report includes "UI Components in Scope" section when applicable
- Reviewer prompt includes UI review considerations for UI projects
- Build gate runs UI_TEST_CMD when configured, routes failures to rework
- Missing E2E framework (command not found) produces a warning, not a failure
- UI_TEST_CMD failures produce UI_TEST_ERRORS.md for coder context
- Non-UI projects see zero change in behavior
- All existing tests pass
- `bash -n` passes on all modified files
- `shellcheck` passes on all modified files

Watch For:
- UI detection must not be over-eager. A project with a single HTML README
  is not a "UI project." Look for MULTIPLE signals: framework dependencies
  + component files + routing config. Single HTML files alone are insufficient
  unless they're in a templates/ or views/ directory.
- The tester UI guidance must be concise — it's injected into every tester
  prompt for UI projects. Keep it under 100 lines. Use framework-specific
  conditional blocks to avoid bloating the prompt with irrelevant framework
  guidance.
- UI_TEST_CMD can be slow (Playwright tests take 30-60 seconds). Consider
  this in the activity timeout. The UI test gate should have its own
  timeout config (UI_TEST_TIMEOUT, default 120 seconds) separate from
  the build gate timeout.
- E2E tests are flaky by nature. A single failure shouldn't immediately
  trigger rework. Consider a retry (run UI_TEST_CMD twice on failure)
  before routing to rework.

Seeds Forward:
- M29 (UI Validation Gate) builds on this detection to add headless
  smoke testing for projects without E2E frameworks
- V4 vision-in-the-loop uses the UI detection to decide when screenshot
  comparison is worthwhile
- The UI_FRAMEWORK detection feeds into express mode (M26) — express
  mode for a React app should default to including E2E awareness

Migration impact:
- New config keys: UI_TEST_CMD, UI_FRAMEWORK, UI_PROJECT_DETECTED,
  UI_VALIDATION_ENABLED, UI_TEST_TIMEOUT
- New files in .claude/: none (detection is runtime, not persisted config)
- Modified file formats: CODER_SUMMARY.md may include UI test warnings,
  Scout report gains "UI Components in Scope" section
- Breaking changes: None
- Migration script update required: YES — V3 migration adds UI config
  keys to pipeline.conf with commented-out defaults
