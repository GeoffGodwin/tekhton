#### Milestone 22: Init UX Overhaul
<!-- milestone-meta
id: "22"
status: "done"
-->

Redesign the post-init experience to guide new users through what matters
instead of dumping them into an 80+ key config file. The init report becomes
a focused, actionable summary that highlights what was detected, what needs
attention, and exactly what to do next. Config file gets clear section
separation between essential and advanced settings.

Files to create:
- `lib/init_report.sh` — Post-init report generator:
  **Focused summary** (`emit_init_summary()`):
  Prints a structured, color-coded summary after init completes:
  ```
  ✓ Tekhton initialized for: my-project

  Detected:
    Language:    TypeScript (high confidence — from package.json)
    Framework:   Next.js 14 (from next.config.js)
    Build:       npm run build (from CI workflow)
    Test:        jest (from jest.config.ts)
    Lint:        eslint (from .eslintrc.json)

  ⚠ Needs attention:
    ARCHITECTURE_FILE not detected — create one or set to "" to skip
    No pre-existing tests found — tester will generate from scratch

  Health score: 45/100 (see INIT_REPORT.md for details)

  Next steps:
    1. Review essential config: .claude/pipeline.conf (lines 1-15)
    2. Start planning:  tekhton --plan "Describe your project goals"
    3. Open dashboard:  open .claude/dashboard/index.html
  ```
  When Watchtower is enabled, also prints: "Full report: .claude/dashboard/index.html"
  When Watchtower is disabled, prints: "Full report: INIT_REPORT.md"

  **Report file** (`emit_init_report_file()`):
  Writes INIT_REPORT.md with the complete detection results, health score
  breakdown, config decisions made, and anything that needs human review.
  This is the persistent artifact that Watchtower and `tekhton report`
  can consume later. Format is structured markdown with machine-parseable
  sections (for dashboard data extraction).

- `lib/init_config_sections.sh` — Config file section generator:
  Replaces the current flat config emission with clearly sectioned output:

  **Section 1: Essential (lines 1-20)**
  PROJECT_NAME, TEST_CMD, ANALYZE_CMD, BUILD_CHECK_CMD, ARCHITECTURE_FILE.
  Comment: "# Review these — auto-detected values may need adjustment"

  **Section 2: Models & Turns (lines 25-50)**
  CLAUDE_CODER_MODEL, CODER_MAX_TURNS, etc.
  Comment: "# Defaults work well — tune after a few runs if needed"

  **Section 3: Pipeline Behavior (lines 55-80)**
  MAX_REVIEW_CYCLES, CONTINUATION_ENABLED, etc.
  Comment: "# Advanced — most users never change these"

  **Section 4: Security (lines 85-100)**
  SECURITY_AGENT_ENABLED, SECURITY_BLOCK_SEVERITY, etc.
  Comment: "# Security is ON by default — adjust policy to your risk tolerance"

  **Section 5: Features (lines 105-130)**
  REPO_MAP_ENABLED, SERENA_ENABLED, WATCHTOWER_ENABLED, etc.
  Comment: "# Optional features — enable as needed"

  **Section 6: Quotas & Autonomy (lines 135-155)**
  USAGE_THRESHOLD_PCT, MAX_PIPELINE_ATTEMPTS, AUTONOMOUS_TIMEOUT, etc.
  Comment: "# Controls for autonomous mode (--complete, --auto-advance)"

  Each section has a clear header with ═══ separators and a one-line
  description of what the section controls.

  **VERIFY markers:** When detection confidence is below HIGH for a critical
  key (TEST_CMD, ANALYZE_CMD, BUILD_CHECK_CMD), append `# VERIFY` comment
  with the detection source. This tells the user which values need checking
  without making them read every key.

Files to modify:
- `lib/init.sh` — Replace current post-init output with `emit_init_summary()`.
  Current behavior: prints file list + generic "next steps."
  New behavior: calls `emit_init_summary()` which reads detection results,
  health score (M15), and Watchtower status to produce the focused summary.
  Also calls `emit_init_report_file()` to write the persistent report.

- `lib/init_config.sh` — Refactor config emission to use sectioned format
  from init_config_sections.sh. All existing config keys remain in the same
  positions (backward compatible for sed/grep-based tools). Only the
  COMMENTS and WHITESPACE change, not the key-value pairs.
  When upgrading (--reinit or migration), preserve user values but add new
  section headers if missing.

- `templates/pipeline.conf.example` — Update the example config with the
  new sectioned format. This is what users see when they open the file
  for the first time.

- `lib/detect_report.sh` — Ensure detection results are written to a
  structured format that `emit_init_summary()` can consume. Add
  confidence levels to each detection (HIGH/MEDIUM/LOW) with source
  attribution.

- `lib/dashboard.sh` (M13) — Add `emit_dashboard_init()` function that
  generates the init data for Watchtower from INIT_REPORT.md.

Acceptance criteria:
- Post-init terminal output shows focused summary with detected values,
  attention items, health score, and numbered next steps
- INIT_REPORT.md written with complete detection results and config decisions
- pipeline.conf uses clear section headers with ═══ separators
- Essential config section is first 15-20 lines (most users only need these)
- VERIFY markers appear on low-confidence detections
- When Watchtower enabled, summary directs user to dashboard
- When Watchtower disabled, summary directs user to INIT_REPORT.md
- Config sectioning is backward compatible (key names/values unchanged)
- --reinit preserves user values while adding section headers if missing
- All existing tests pass
- `bash -n lib/init_report.sh lib/init_config_sections.sh` passes
- `shellcheck lib/init_report.sh lib/init_config_sections.sh` passes

Watch For:
- pipeline.conf is `source`d as bash. Section headers (comments) and
  whitespace changes are safe, but be careful not to add syntax that
  breaks sourcing (e.g., unescaped special chars in comments).
- The "essential" section MUST include every key a new user might need
  to verify. Missing a key here means the user won't check it.
- VERIFY markers should be rare (only low-confidence detections). If
  everything is marked VERIFY, the signal is lost.
- Health score display depends on M15. When M15 isn't implemented yet,
  skip the health score line gracefully.

Seeds Forward:
- INIT_REPORT.md is consumed by Watchtower (M13/M14) for the init view
- Config sectioning format is maintained by migration scripts (M21)
- VERIFY markers feed into the PM agent's confidence assessment (M10)
- The focused summary pattern is reusable for other CLI output improvements

Migration impact:
- New files in .claude/: INIT_REPORT.md (generated by init)
- Modified file formats: pipeline.conf (section headers added, values unchanged)
- New config keys: NONE
- Breaking changes: NONE — terminal output changes only, no behavioral change
- Migration script update required: YES — add section headers to existing
  pipeline.conf files (append-only, non-destructive)
