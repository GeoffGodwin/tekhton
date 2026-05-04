
#### Milestone 15: Project Health Scoring & Evaluation
<!-- milestone-meta
id: "15"
status: "done"
-->
<!-- PM-tweaked: 2026-03-23 -->

Establish a measurable project health baseline during --init and track improvement
across Tekhton runs. Users see a concrete score (0-100 or belt system) that
reflects testing health, code quality, dependency freshness, and documentation
quality. The score is assessed during brownfield init, re-evaluated periodically,
and the delta is surfaced in the Watchtower Trends tab. The PM agent uses the
health score to calibrate milestone priorities.

This milestone answers the user's fundamental question: "Is Tekhton actually
making my project better?" with a number they can show their team.

Files to create:
- `lib/health.sh` — Health scoring engine:
  **Baseline assessment** (`assess_project_health(project_dir)`):
  Runs a battery of lightweight, non-executing checks and produces a composite
  score. Each dimension is scored 0-100 independently, then weighted into a
  composite. Dimensions:

  1. **Test health** (weight: 30%)
     - Test files exist? (0 if none, scaled by ratio of test files to source files)
     - Test command detected and executable? (from detect_commands.sh)
     - If tests can be run: pass rate. If not runnable: inferred from file presence.
     - Test naming conventions consistent? (*_test.go, *.spec.ts, test_*.py)
     - Test framework detected? (from M12 detect_test_frameworks)
     Source: `detect_test_frameworks()`, `TEST_CMD` execution if available, file counting.

  2. **Code quality signals** (weight: 25%)
     - Linter config exists and is configured? (from M12 linter detection)
     - Pre-commit hooks configured? (.pre-commit-config.yaml)
     - Magic number density: sample N source files, count numeric literals outside
       of common patterns (0, 1, -1, 100, etc.). High density = low score.
     - TODO/FIXME/HACK/XXX density: count per 1000 lines across sampled files.
     - Average function/method length in sampled files (heuristic: count lines
       between function signatures). Very long functions = low score.
     - Type safety: TypeScript over JavaScript? Type hints in Python? Typed
       language (Go, Rust) gets full marks automatically.
     Source: file sampling (reuse crawler sampling from brownfield init), grep.

  3. **Dependency health** (weight: 15%)
     - Lock file exists? (package-lock.json, yarn.lock, Pipfile.lock, Cargo.lock, go.sum)
     - Lock file committed to git? (git ls-files check)
     - Dependency count vs source file count ratio (bloated deps = lower score)
     - Known vulnerability scanner config present? (snyk.yml, .github/dependabot.yml,
       renovate.json)
     - Dependency freshness: if package.json/pyproject.toml has pinned versions,
       sample a few and check if they're more than 2 major versions behind
       (heuristic only — no network call needed, compare version numbers in lock file).
     Source: manifest file parsing, lock file presence checks.

  4. **Documentation quality** (weight: 15%)
     - Reuse `_assess_doc_quality()` from M12 (README, CONTRIBUTING, API docs,
       architecture docs, inline doc density).
     - If M12 already computed DOC_QUALITY_SCORE, use it directly.
     Source: `DOC_QUALITY_SCORE` from M12, or compute independently if M12 not run.

  5. **Project hygiene** (weight: 15%)
     - .gitignore exists and covers common patterns? (node_modules, __pycache__, .env)
     - .env file NOT committed to git? (security check)
     - CI/CD configured? (from M12 CI detection)
     - README has setup/install instructions? (grep for "install", "setup", "getting started")
     - CHANGELOG or release tags present?
     Source: file existence checks, git history queries.

  **Composite calculation:**
  ```
  composite = (test * 0.30) + (quality * 0.25) + (deps * 0.15) + (docs * 0.15) + (hygiene * 0.15)
  ```
  Weights are configurable via HEALTH_WEIGHT_* in pipeline.conf.

  **Belt system mapping** (fun, memorable, optional display):
  ```
  0-19:   White Belt    — "Starting fresh"
  20-39:  Yellow Belt   — "Foundation laid"
  40-59:  Orange Belt   — "Taking shape"
  60-74:  Green Belt    — "Solid practices"
  75-89:  Blue Belt     — "Well-maintained"
  90-100: Black Belt    — "Exemplary"
  ```
  Belt labels are cosmetic and configurable (HEALTH_BELT_LABELS in config).

  **Output:** `HEALTH_REPORT.md` with per-dimension breakdown, composite score,
  belt label, and specific improvement suggestions for low-scoring dimensions.
  Also writes `HEALTH_BASELINE.json` (machine-readable) for delta tracking.

  **Re-assessment** (`reassess_project_health(project_dir)`):
  Same assessment, but also reads previous HEALTH_BASELINE.json (or last
  HEALTH_REPORT.json from run history) and computes delta per dimension.
  Output includes: current score, previous score, delta, trend arrows.

- `lib/health_checks.sh` — Individual dimension check functions:
  - `_check_test_health(project_dir)` → score 0-100
  - `_check_code_quality(project_dir)` → score 0-100
  - `_check_dependency_health(project_dir)` → score 0-100
  - `_check_doc_quality(project_dir)` → score 0-100 (delegates to M12 when available)
  - `_check_project_hygiene(project_dir)` → score 0-100
  Each function outputs: `DIMENSION|SCORE|DETAIL_JSON` (pipe-delimited, detail
  is a JSON object with sub-scores and findings for the report).
  **Critical: these are all read-only, non-executing checks.** They never run
  project code, never install dependencies, never execute test suites. Only
  file presence, content sampling, and git queries. Exception: if HEALTH_RUN_TESTS
  is explicitly set to true AND TEST_CMD is configured, the test dimension CAN
  execute the test suite for an accurate pass rate. Default: false.

Files to modify:
- `tekhton.sh` — [PM: missing from original file list but required by acceptance criteria]
  Add `--health` flag handling. When invoked as `tekhton --health`, call
  `reassess_project_health "$PROJECT_DIR"` (sourcing lib/health.sh), display
  results, and exit. No pipeline stages are run. Place flag parsing alongside
  other single-action flags (--init, --plan, --replan).

- `lib/init.sh` (or equivalent --init orchestration) — [PM: lib/init.sh does not
  appear in the documented repo layout. The Brownfield Intelligence initiative
  (which owns --init) is listed as a future initiative, not yet implemented.
  The coder should: (a) check if lib/init.sh exists; (b) if not, find the actual
  --init handler in tekhton.sh and add the health assessment call there directly;
  (c) if a stub exists, add to it. The integration goal is: after --init completes
  its detection/synthesis phase, call `assess_project_health()`, write
  HEALTH_BASELINE.json to `.claude/`, and include the score in the completion
  banner.]
  During the --init interview/synthesis: include health findings in the synthesis
  context so the generated CLAUDE.md and milestones can address low-scoring
  dimensions. For example: if test health is 10/100, the PM agent should know
  that test coverage is a priority.

- `lib/finalize.sh` — At pipeline completion, if HEALTH_REASSESS_ON_COMPLETE=true,
  run `reassess_project_health()` and include delta in RUN_SUMMARY.json.
  Display delta in the completion banner: "Health: 23 → 31 (+8) Yellow Belt".
  This is optional and defaults to false (re-assessment has a small time cost
  from file sampling). Can also be triggered explicitly via `tekhton --health`.

- `lib/dashboard.sh` — Add `emit_dashboard_health()` function. Reads
  HEALTH_BASELINE.json and latest HEALTH_REPORT.json, generates
  `data/health.js` with `window.TK_HEALTH = { ... }`. Includes: current score,
  baseline score, per-dimension breakdown, belt label, trend data.

- `stages/intake.sh` — PM agent receives HEALTH_SCORE_SUMMARY in its prompt
  context. When health score is low in a specific dimension AND the current
  milestone doesn't address it, the PM can note this in INTAKE_REPORT.md as
  a suggestion (NOT a block — just awareness). Example: "Note: test coverage
  is at 12%. Consider prioritizing test milestones."

- `lib/config_defaults.sh` — Add:
  HEALTH_ENABLED=true,
  HEALTH_REASSESS_ON_COMPLETE=false,
  HEALTH_RUN_TESTS=false (never execute tests for health score by default),
  HEALTH_SAMPLE_SIZE=20 (number of source files to sample for quality checks),
  HEALTH_WEIGHT_TESTS=30,
  HEALTH_WEIGHT_QUALITY=25,
  HEALTH_WEIGHT_DEPS=15,
  HEALTH_WEIGHT_DOCS=15,
  HEALTH_WEIGHT_HYGIENE=15,
  HEALTH_SHOW_BELT=true,
  HEALTH_BASELINE_FILE=.claude/HEALTH_BASELINE.json,
  HEALTH_REPORT_FILE=HEALTH_REPORT.md.

- `lib/config.sh` — Validate HEALTH_WEIGHT_* sum to 100. Validate
  HEALTH_SAMPLE_SIZE is 5-100.

- `prompts/intake_scan.prompt.md` — Add conditional health context block:
  `{{IF:HEALTH_SCORE_SUMMARY}}## Project Health Context
  {{HEALTH_SCORE_SUMMARY}}{{ENDIF:HEALTH_SCORE_SUMMARY}}`

- `templates/watchtower/app.js` (M14) — Add health score rendering in the
  Trends tab: current score with belt badge, per-dimension bar chart,
  baseline vs current delta with trend arrows.

Acceptance criteria:
- `assess_project_health()` produces a composite score 0-100 from 5 dimensions
- Each dimension check is read-only (no code execution unless HEALTH_RUN_TESTS=true)
- HEALTH_REPORT.md contains per-dimension breakdown with sub-scores and findings
- HEALTH_BASELINE.json written during --init for future delta tracking
- `reassess_project_health()` computes delta from baseline and per-dimension trends
- Belt system maps score to label correctly at all boundaries
- Health score displayed in --init completion banner with color coding
- Health delta displayed in run completion banner when HEALTH_REASSESS_ON_COMPLETE=true
- `tekhton --health` triggers standalone re-assessment without running pipeline
- PM agent sees HEALTH_SCORE_SUMMARY in context when available
- Watchtower data layer emits health data to data/health.js
- Dimension weights are configurable and validated to sum to 100
- File sampling respects HEALTH_SAMPLE_SIZE limit
- Magic number detection skips common constants (0, 1, -1, 2, 100, 1000, etc.)
- .env-in-git detection correctly identifies committed secrets as hygiene failure
- When HEALTH_ENABLED=false, all health functions are no-ops
- A project with zero tests, no linter, no docs, no CI scores near 0
- A well-maintained OSS project (linted, tested, documented, CI'd) scores near 90
- All existing tests pass
- `bash -n lib/health.sh lib/health_checks.sh` passes
- `shellcheck lib/health.sh lib/health_checks.sh` passes
- New test file `tests/test_health_scoring.sh` covers: dimension checks against
  fixture projects, composite calculation, weight validation, belt mapping,
  delta computation, baseline persistence

Watch For:
- File sampling must be deterministic (sorted file list, not random). Same repo
  state → same score. Use `git ls-files | sort | head -n SAMPLE_SIZE` pattern.
- Magic number detection is inherently noisy. Focus on numeric literals in
  non-obvious contexts (inside conditionals, as function arguments) rather than
  in array indices or loop bounds. Err toward fewer false positives.
- The test health dimension without HEALTH_RUN_TESTS=true is a rough proxy
  (file count ratio + naming conventions). Make this clear in the report:
  "Estimated from file presence. Run with HEALTH_RUN_TESTS=true for actual pass rate."
- Dependency version comparison (is it 2+ majors behind?) requires parsing
  semver from lock files. Handle non-semver versions gracefully (skip them).
- The composite score should be stable across runs on the same codebase (no
  randomization in sampling). If a user runs --health twice without changing
  code, they must get the same score.
- Belt system is fun but some users may find it patronizing. Make it configurable
  (HEALTH_SHOW_BELT=true by default) and keep the 0-100 number always visible.
- Never read .env file contents for the hygiene check — only check if the
  FILENAME is tracked by git (`git ls-files .env`). The contents may have secrets.
- [PM: lib/init.sh may not exist — see note in "Files to modify" above. Resolve
  by locating the actual --init dispatch in tekhton.sh before writing any code.]

Seeds Forward:
- V4 tech debt agent uses health score to prioritize which debt to tackle first
  (lowest dimension = highest priority)
- V4 parallel execution can run health re-assessment in parallel with the
  regular pipeline (it's read-only, no conflicts)
- Health score trends in Watchtower provide the "before/after" proof that
  Tekhton is delivering value
- Enterprise users can set minimum health scores as gates ("don't deploy below 60")
- The dimension framework is extensible: V4 adds security posture dimension
  (from M09 findings history), accessibility dimension, performance dimension
