#### Milestone 29: UI Validation Gate & Headless Smoke Testing
Add a UI validation gate that runs headless browser smoke tests against
UI artifacts produced by the pipeline. This catches the class of bugs
where code compiles, unit tests pass, and E2E tests pass (or don't exist),
but the actual rendered output is broken — missing resources, JS errors,
layout failures, or degraded behavior like the Watchtower blink bug.

This milestone provides infrastructure for projects that DON'T have their
own E2E test framework configured. For projects WITH E2E tests (covered
by M28's UI_TEST_CMD), the validation gate runs AFTER E2E tests as an
additional safety net.

Requires a headless browser (Chromium via Playwright or Puppeteer).
Soft-fails gracefully when no headless browser is available, with clear
diagnostic output explaining what's missing and how to install it.

Files to create:
- `lib/ui_validate.sh` — UI validation gate orchestrator:
  **Core function: `run_ui_validation()`**
  Called from the build gate (lib/gates.sh) after UI_TEST_CMD (if any).
  Workflow:
  1. Check prerequisites: headless browser available? Node.js available?
     If not, emit a clear diagnostic message:
     "UI validation skipped: headless browser not available.
      To enable: npm install -g playwright && npx playwright install chromium
      Or: apt-get install chromium-browser (for system Chromium)
      See: [docs link] for full setup instructions."
     Log to Watchtower as UI_VALIDATION_SKIPPED event. Continue pipeline
     (soft fail, not hard fail).
  2. Determine validation targets from CODER_SUMMARY.md:
     - Static HTML files created/modified → validate directly
     - Web app with dev server → start server, validate, stop server
     - Watchtower dashboard → special-case self-validation
     Detection heuristic: check file extensions in CODER_SUMMARY.md
     (.html, .htm, .jsx, .tsx, .vue, .svelte) and presence of
     UI_SERVE_CMD in config.
  3. For each validation target, run the smoke test script (see below).
  4. Parse results, write UI_VALIDATION_REPORT.md.
  5. If failures found: route to coder rework (same as build failure).

  **Prerequisite detection: `_check_headless_browser()`**
  Checks in order:
  1. `npx playwright --version` (preferred — Playwright bundles Chromium)
  2. `npx puppeteer --version` (fallback)
  3. `chromium-browser --version` or `chromium --version` (system)
  4. `google-chrome --headless --version` (system Chrome)
  Returns the command to use, or empty string if none found.
  Caches result in session dir (don't re-detect every gate run).

  **Server management: `_start_ui_server()` / `_stop_ui_server()`**
  When UI_SERVE_CMD is configured (e.g., "npm run dev", "python -m http.server"):
  - Start the server in background, capture PID
  - Wait for the server to be ready (poll localhost:UI_SERVE_PORT with
    curl, timeout after UI_SERVER_STARTUP_TIMEOUT seconds)
  - If server fails to start, log diagnostic and soft-fail
  - After validation completes, kill the server process
  For static HTML files: use `python3 -m http.server` as a minimal server
  (Python is already an optional dep for tree-sitter).

- `tools/ui_smoke_test.js` — Headless browser smoke test script:
  A standalone Node.js script that Tekhton invokes as a subprocess.
  Accepts: URL or file path, optional viewport size, optional timeout.
  Performs these checks:
  1. **Page load:** Navigate to URL, wait for load event. FAIL if timeout.
  2. **Console errors:** Capture all console.error messages during load
     and for 3 seconds after. FAIL if any errors (configurable severity).
  3. **Missing resources:** Check for 404s on CSS, JS, image, font loads.
     FAIL if any referenced resources return 404.
  4. **Basic rendering:** Check that document.body has non-zero dimensions
     and contains at least one visible element. FAIL if page is blank.
  5. **Crash detection:** Check for uncaught exceptions, unhandled promise
     rejections. FAIL if any.
  6. **Flicker detection:** Take 3 screenshots at 2-second intervals.
     Compare pixel hashes. If they differ significantly between consecutive
     frames (indicating page is re-rendering/flickering), report as WARNING
     (not failure — flicker is a UX issue, not a crash).
  Output: JSON result with pass/fail per check, console errors captured,
  missing resources listed, screenshots saved (for human review and future
  vision-in-the-loop).

  The script uses Playwright if available, falls back to Puppeteer.
  If neither is available as a Node module, the shell orchestrator
  already detected this and skipped (see _check_headless_browser above).

  **Viewport testing:** Runs checks at two viewports by default:
  - Desktop: 1280x800
  - Mobile: 375x812
  Configurable via UI_VALIDATION_VIEWPORTS in pipeline.conf.

- `lib/ui_validate_report.sh` — Report parser and formatter:
  Reads the JSON output from ui_smoke_test.js, produces:
  - UI_VALIDATION_REPORT.md (human-readable, stored alongside other reports)
  - Watchtower event data (for dashboard rendering)
  - Coder context block (if failures found, injected into rework prompt)
  Report format:
  ```markdown
  ## UI Validation Report
  ### Results
  | Target | Load | Console | Resources | Rendering | Verdict |
  |--------|------|---------|-----------|-----------|---------|
  | /index.html (desktop) | ✅ | ✅ | ✅ | ✅ | PASS |
  | /index.html (mobile)  | ✅ | ⚠️ 1 warn | ✅ | ✅ | PASS |

  ### Console Errors
  (none)

  ### Missing Resources
  (none)

  ### Flicker Detection
  ⚠️ index.html: page content changes between frame 1 and frame 2
     (possible auto-refresh or animation — review manually)

  ### Screenshots
  Saved to .claude/ui-validation/screenshots/
  ```

- `prompts/ui_rework.prompt.md` — Rework prompt for UI validation failures:
  "The UI validation gate detected issues with the rendered output.
  Read UI_VALIDATION_REPORT.md for details. Fix the issues and ensure
  the page loads cleanly in both desktop and mobile viewports.
  Common causes:
  - Console errors: missing imports, undefined variables, API call failures
  - Missing resources: wrong file path, file not generated, wrong directory
  - Blank page: JS crash before rendering, missing root element
  - Flicker: auto-refresh loop, CSS transition on load, state oscillation"

Files to modify:
- `lib/gates.sh` — Insert UI validation after UI_TEST_CMD in the build gate:
  ```
  # Existing: BUILD_CHECK_CMD → ANALYZE_CMD → UI_TEST_CMD (M28)
  # New:      → run_ui_validation() (M29)
  ```
  UI validation runs AFTER E2E tests. If E2E tests already caught the
  problem, UI validation confirms it's fixed after rework.

- `lib/config_defaults.sh` — Add:
  UI_SERVE_CMD="" (command to start a dev/preview server),
  UI_SERVE_PORT=3000 (port the dev server listens on),
  UI_SERVER_STARTUP_TIMEOUT=30 (seconds to wait for server ready),
  UI_VALIDATION_VIEWPORTS="1280x800,375x812" (viewport sizes to test),
  UI_VALIDATION_TIMEOUT=30 (seconds per page load timeout),
  UI_VALIDATION_CONSOLE_SEVERITY=error (error|warn — what level fails),
  UI_VALIDATION_FLICKER_THRESHOLD=0.05 (pixel diff ratio for flicker warning),
  UI_VALIDATION_RETRY=true (retry once on failure before routing to rework),
  UI_VALIDATION_SCREENSHOTS=true (save screenshots for review).

- `lib/config.sh` — Validate UI_SERVE_PORT is numeric, viewports match
  NNNNxNNNN format, timeout values are positive integers.

- `lib/prompts.sh` — Register UI_VALIDATION_REPORT_CONTENT and
  UI_VALIDATION_FAILURES_BLOCK template variables.

- `prompts/coder_rework.prompt.md` — Add conditional UI failures block:
  `{{IF:UI_VALIDATION_FAILURES_BLOCK}}
  ## UI Validation Failures
  The rendered UI has issues detected by headless browser testing.
  These MUST be fixed — they indicate the user-facing output is broken.
  {{UI_VALIDATION_FAILURES_BLOCK}}
  {{ENDIF:UI_VALIDATION_FAILURES_BLOCK}}`

- `lib/hooks.sh` or `lib/finalize.sh` — Include UI_VALIDATION_REPORT.md
  in archive step. Include UI validation results in RUN_SUMMARY.json.
  Clean up screenshots older than 5 runs.

- `lib/finalize_display.sh` — When UI validation ran:
  Include pass/fail count in the completion banner.
  When screenshots were captured, note their location.

- `templates/pipeline.conf.example` — Extend UI testing section:
  ```
  # --- UI Validation (headless browser smoke tests) ---
  # UI_SERVE_CMD=""                    # Dev server command (e.g., "npm run dev")
  # UI_SERVE_PORT=3000                 # Dev server port
  # UI_VALIDATION_VIEWPORTS="1280x800,375x812"  # Viewport sizes
  # UI_VALIDATION_CONSOLE_SEVERITY=error  # error | warn
  # UI_VALIDATION_SCREENSHOTS=true     # Save screenshots for review
  ```

- **Watchtower self-test (special case):**
  Add a built-in validation target for Tekhton's own Watchtower dashboard.
  When Watchtower files are modified (detected from CODER_SUMMARY.md),
  the validation gate automatically tests the generated dashboard:
  - Serve .claude/dashboard/ via python3 http.server
  - Run smoke test against localhost:PORT/index.html
  - Verify: page loads, no console errors, data panels render,
    auto-refresh doesn't cause visible flicker
  This is Tekhton testing its own output — no user configuration needed.
  Guarded by WATCHTOWER_SELF_TEST=true (default when Watchtower enabled).

Acceptance criteria:
- `_check_headless_browser()` detects Playwright, Puppeteer, system
  Chromium, and system Chrome in priority order
- When no headless browser available: clear diagnostic message printed
  with install instructions, pipeline continues (soft fail), Watchtower
  logs UI_VALIDATION_SKIPPED event
- `ui_smoke_test.js` checks: page load, console errors, missing resources,
  basic rendering, crash detection, flicker detection
- Smoke test runs at both desktop and mobile viewports by default
- Console errors at configured severity level trigger validation failure
- Missing resources (404 on CSS/JS/images) trigger validation failure
- Blank page (zero-dimension body) triggers validation failure
- Flicker detection reports as WARNING, not failure
- Screenshots captured and saved to .claude/ui-validation/screenshots/
- UI_VALIDATION_REPORT.md produced with structured results table
- Validation failures route to coder rework with UI_VALIDATION_FAILURES_BLOCK
- UI_VALIDATION_RETRY: failure retried once before routing to rework
- Dev server management: starts before validation, stops after, handles
  startup timeout with diagnostic output
- Static HTML files validated directly via minimal Python HTTP server
- Watchtower self-test: automatically validates dashboard when Watchtower
  files are modified, no user config needed
- Non-UI projects and projects without headless browser see zero change
  in behavior (soft fail + skip)
- All existing tests pass
- `bash -n lib/ui_validate.sh lib/ui_validate_report.sh` passes
- `shellcheck lib/ui_validate.sh lib/ui_validate_report.sh` passes

Watch For:
- **Headless browser installation is the #1 friction point.** The diagnostic
  message when it's missing must be crystal clear. Include exact commands
  for the 3 most common environments: macOS (`brew install chromium`),
  Ubuntu/Debian (`apt-get install chromium-browser`), and npm global
  (`npm install -g playwright && npx playwright install chromium`).
  Link to the docs site (M18) troubleshooting page.
- **Dev server startup is non-deterministic.** The server might be "ready"
  (process started) but not yet accepting connections. The readiness poll
  must use actual HTTP requests, not just process existence checks. Use
  `curl -s -o /dev/null -w "%{http_code}" http://localhost:$PORT` in a
  loop with 1-second intervals.
- **Port conflicts.** UI_SERVE_PORT might already be in use (dev left a
  server running). Detect this before starting: check if port is occupied,
  if so try PORT+1 through PORT+10, or fail with a clear message.
- **Screenshots can be large.** At 1280x800, a PNG screenshot is ~500KB.
  Two viewports × 3 frames = 6 screenshots = ~3MB per validation run.
  Prune aggressively (keep last 5 runs only) and use JPEG for non-baseline
  screenshots to save space.
- **Flicker detection false positives.** Pages with intentional animations
  (loading spinners, transitions) will trigger the flicker detector.
  The threshold must be tuned to ignore small animated regions. Compare
  full-page pixel hashes, not individual regions. A page that's 95%
  identical between frames is fine — one that's 50% different is not.
- **ui_smoke_test.js must be self-contained.** It cannot require npm install
  in the Tekhton repo. It should use whatever Playwright/Puppeteer is
  globally installed or available in the project's node_modules. If
  neither exists, the shell-side prerequisite check already skipped.
- **CI environments.** Many CI runners have headless Chromium pre-installed
  but Playwright is NOT installed. The fallback chain (Playwright →
  Puppeteer → system Chromium → system Chrome) must handle this. For
  system Chromium, ui_smoke_test.js uses puppeteer-core with
  executablePath pointing to the detected binary.

Seeds Forward:
- V4 vision-in-the-loop: screenshots from this gate become the input
  for a vision-capable Claude agent that can judge "does this look right?"
- V4 visual regression: screenshots saved here become the baseline for
  future comparison (pixel diff between runs)
- The flicker detection algorithm is reusable for V4 performance monitoring
  (detecting layout thrash, excessive re-renders)
- The dev server management functions are reusable for any future feature
  that needs to interact with a running project (e.g., API testing)

Migration impact:
- New config keys: UI_SERVE_CMD, UI_SERVE_PORT, UI_SERVER_STARTUP_TIMEOUT,
  UI_VALIDATION_VIEWPORTS, UI_VALIDATION_TIMEOUT, UI_VALIDATION_CONSOLE_SEVERITY,
  UI_VALIDATION_FLICKER_THRESHOLD, UI_VALIDATION_RETRY,
  UI_VALIDATION_SCREENSHOTS, WATCHTOWER_SELF_TEST
- New files in .claude/: ui-validation/screenshots/ (auto-created on first run)
- New files in project: UI_VALIDATION_REPORT.md (per-run artifact)
- Modified file formats: RUN_SUMMARY.json gains ui_validation results
- Breaking changes: None
- Migration script update required: YES — V3 migration adds UI validation
  config keys to pipeline.conf
