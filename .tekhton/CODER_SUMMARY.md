# Coder Summary

## Status: COMPLETE

## What Was Implemented

m29.2 — Detect Domain Detectors. Ported the eight remaining bash detect
files (and the UI framework helper from `lib/detect.sh`) into Go under
`internal/detect/`, cut every bash caller over to JSON-shaped wrappers,
and deleted the ten bash detect files.

### Goal-by-goal

**Goal 1 — Eight Go detectors.** Added under `internal/detect/`:
- `commands.go` + `commands_pkg.go` + `commands_meta.go` (split across
  three files to keep each under the 600-line Go soft target). Owns
  `CommandsDetector` plus `detectCommands`, `detectEntryPoints`,
  `detectProjectType`. Cross-detector dependency on CI is resolved by
  calling `detectCIConfig` (from ci.go) inline; both detectors share the
  helper without depending on CIDetector registration order.
- `workspaces.go` — `WorkspacesDetector` plus per-monorepo enumeration
  helpers (pnpm, npm, lerna, nx, cargo, go, gradle, maven).
- `services.go` — `ServicesDetector` (docker-compose, Procfile, k8s).
- `ci.go` — `CIDetector` (GitHub Actions, GitLab, CircleCI, Jenkins,
  Bitbucket, Dockerfile) + the shared `detectCIConfig` helper that
  `commands.go` consumes. Mirrors the bash quirk where the dockerfile
  language lands in the Deploy column (lib/detect_ci.sh:187-191).
- `infrastructure.go` — `InfrastructureDetector` (Terraform, Pulumi,
  CDK, CloudFormation/SAM, Ansible). Never reads `.tfstate`.
- `test_frameworks.go` — `TestFrameworksDetector` covering Python /
  JS / Go / Rust / Ruby / Java / C# / Dart / Shell.
- `doc_quality.go` — `DocQualityDetector` (README + CONTRIBUTING +
  API docs + architecture + inline doc density scoring).
- `ai_artifacts.go` — `AIArtifactsDetector` with the load-bearing
  heuristic-order const slice (`aiArtifactHeuristics`) and
  `TestHeuristicOrder` guarding against reordering. `ClassifyAITool`
  exposed for parity with the bash surface.
- `ui_framework.go` — `detectUIFramework` plus the `Framework.Kind="ui"`
  emission inside `LanguagesDetector` so the deleted bash function's
  side effects (UI_PROJECT_DETECTED, UI_FRAMEWORK env vars) can move
  to the bash wrapper.

**Goal 2 — `ai_artifacts.go` heuristic order.** `aiArtifactHeuristics`
slice in `ai_artifacts.go` declares `[known_dirs, known_files,
known_globs, claude_dir, claude_md, directive_markdowns]` in the bash
order. `TestHeuristicOrder` asserts the exact sequence; reorder fails
red.

**Goal 3 — Detector registration.** `cmd/tekhton/detect.go::
registeredDetectors` returns the 9-detector slice in bash-report order.
`TestRegistrationOrder` in `cmd/tekhton/detect_test.go` asserts the
sequence.

**Goal 4 — Bash wrappers.** `lib/common_detect.sh` (sourced by
`lib/common.sh`) defines `_tk_detect_summary` plus per-domain accessors
(`_tk_detect_languages`, `_tk_detect_frameworks`, `_tk_detect_commands`,
`_tk_detect_entry_points`, `_tk_detect_project_type`,
`_tk_detect_workspaces`, `_tk_detect_services`, `_tk_detect_ci`,
`_tk_detect_infrastructure`, `_tk_detect_test_frameworks`,
`_tk_detect_doc_quality`, `_tk_detect_ai_artifacts`). The
`_tk_detect_ui_framework` wrapper preserves the UI_PROJECT_DETECTED +
UI_FRAMEWORK env-var side effects via `select(.kind == "ui")`.
`_tk_detect_ui_test_cmd` ports the CI/script/convention priority chain.
`_tk_format_detection_report` and `_tk_format_detection_summary` cover
the report formatter surface.

**Goal 5 — Caller migration.** Updated:
- `lib/init.sh` — six detect calls replaced with `_tk_detect_*`
  wrappers; AI-artifact source line removed.
- `lib/init_synthesize_helpers.sh` — `format_detection_report` →
  `_tk_format_detection_report`; `assess_doc_quality` →
  `_tk_detect_doc_quality`.
- `lib/express.sh` — `detect_languages`/`detect_commands` →
  `_tk_detect_languages`/`_tk_detect_commands`.
- `lib/health_checks.sh` — two `detect_test_frameworks` calls →
  `_tk_detect_test_frameworks` (dropped the `command -v` guard and the
  manual-config-file fallback — the Go binary is unconditionally
  available post-m20).
- `lib/health_checks_hygiene.sh` — `detect_ci_config` → `_tk_detect_ci`.
- `lib/health_checks_infra.sh` — `assess_doc_quality` →
  `_tk_detect_doc_quality`.
- `lib/crawler.sh` — `assess_doc_quality` → `_tk_detect_doc_quality`.
- `tekhton-legacy.sh` — `detect_ui_framework`/`detect_ui_test_cmd` calls
  rewritten to `_tk_detect_ui_*`; eight `source lib/detect*.sh` lines
  (across the --init, --rescan, --plan-from-index, --health, and main
  source blocks) removed.

**Goal 6 — Parity gate extension.** `tests/test_detect_parity.sh` now
asserts byte-identical FULL markdown across all four fixtures
(`monorepo-pnpm`, `polyglot-services`, `ai-heavy-mess`, plus the new
`empty/`). No per-section extraction. Baselines remain frozen.

**Goal 7 — Bash deletions.** Ten files deleted: `lib/detect.sh`,
`lib/detect_report.sh`, `lib/detect_commands.sh`,
`lib/detect_workspaces.sh`, `lib/detect_services.sh`, `lib/detect_ci.sh`,
`lib/detect_infrastructure.sh`, `lib/detect_test_frameworks.sh`,
`lib/detect_doc_quality.sh`, `lib/detect_ai_artifacts.sh`.
`scripts/wedge-audit.sh` gains a regression guard that fails red on
any `lib/detect*.sh` re-introduction. `internal/stagerunner/helpers.go::
DefaultLibHelpers` drops the ten detect entries.

**Goal 8 — VERSION bump.** See "Acceptance criteria not literally met"
below.

### Per-detector unit tests

`internal/detect/<name>_test.go` for each of the eight new detectors,
each with at least three table-driven test cases (positive + negative
+ edge case). `TestHeuristicOrder` guards the AI-artifact ordering.
`TestRegistrationOrder` in `cmd/tekhton/detect_test.go` guards the CLI
registration sequence. The package-level `readonly_test.go` (from
m29.1) still passes — every new file is read-only.

### Bash test cleanup

25 bash tests that sourced the deleted `lib/detect*.sh` files skip-stub
with a note pointing at the Go replacements (Go unit tests + parity
gate + CLI tests). 6 platform tests + 2 index/rescan tests likewise
skip-stub because they depended on internal bash helpers
(`_extract_json_keys`, `_check_dep`, `_DETECT_EXCLUDE_DIRS`) that did
not survive the port. Same pattern as m22.

## Root Cause (bugs only)
N/A — this is a migration milestone.

## Files Modified

### New (Go)
- `internal/detect/commands.go` (NEW)
- `internal/detect/commands_pkg.go` (NEW)
- `internal/detect/commands_meta.go` (NEW)
- `internal/detect/workspaces.go` (NEW)
- `internal/detect/services.go` (NEW)
- `internal/detect/ci.go` (NEW)
- `internal/detect/infrastructure.go` (NEW)
- `internal/detect/test_frameworks.go` (NEW)
- `internal/detect/doc_quality.go` (NEW)
- `internal/detect/ai_artifacts.go` (NEW)
- `internal/detect/ui_framework.go` (NEW)

### New (tests)
- `internal/detect/commands_test.go` (NEW)
- `internal/detect/workspaces_test.go` (NEW)
- `internal/detect/services_test.go` (NEW)
- `internal/detect/ci_test.go` (NEW)
- `internal/detect/infrastructure_test.go` (NEW)
- `internal/detect/test_frameworks_test.go` (NEW)
- `internal/detect/doc_quality_test.go` (NEW)
- `internal/detect/ai_artifacts_test.go` (NEW)
- `tests/testdata/detect/empty/.gitkeep` (NEW — empty fixture)
- `tests/testdata/detect/baselines/empty.md` (NEW — bash-captured baseline)

### New (bash)
- `lib/common_detect.sh` (NEW — Go-engine wrappers)

### Modified (Go)
- `internal/detect/detect.go` (Framework.Kind field; AIArtifact field
  rename to match bash shape; attach() switch for new detectors; splitCSV
  and splitSemicolon helpers)
- `internal/detect/languages.go` (UI framework emission via
  detectUIFramework + kind="ui_framework" row)
- `internal/detect/helpers.go` (dirExists, statSafe, readDirNames,
  listFilesDepth, globMany helpers used by m29.2 detectors)
- `internal/detect/report.go` (renderWorkspaces counts subprojects
  excluding "...(N more)" overflow marker)
- `cmd/tekhton/detect.go` (registeredDetectors slice + 9-detector
  registration)
- `cmd/tekhton/detect_test.go` (TestRegistrationOrder)
- `internal/stagerunner/helpers.go` (DefaultLibHelpers loses 10 detect
  entries)

### Modified (bash)
- `lib/common.sh` (sources common_detect.sh)
- `lib/init.sh` (six detect calls migrated; source line for
  detect_ai_artifacts removed)
- `lib/init_synthesize_helpers.sh` (format/quality migration)
- `lib/express.sh` (language + command detection migrated)
- `lib/health_checks.sh` (test framework lookup migrated; manual
  fallback removed)
- `lib/health_checks_hygiene.sh` (CI lookup migrated; manual fallback
  removed)
- `lib/health_checks_infra.sh` (doc quality lookup migrated)
- `lib/crawler.sh` (doc quality lookup migrated)
- `lib/rescan.sh` (header comment refresh only)
- `lib/health.sh` (header comment refresh only)
- `stages/init_synthesize.sh` (header comment refresh only)
- `tekhton-legacy.sh` (eight source lines removed; UI framework + UI
  test cmd calls migrated)
- `scripts/wedge-audit.sh` (m29.2 re-introduction guard)
- `scripts/capture-detect-baselines.sh` (rewritten to capture from the
  Go binary; baselines remain frozen unless explicitly regenerated)
- `tests/test_detect_parity.sh` (full-markdown comparison; empty fixture
  added)

### Skip-stubbed (bash tests)
33 tests stubbed under `tests/` — see "Bash test cleanup" above. Same
pattern as m22.

### Deleted
- `lib/detect.sh`, `lib/detect_report.sh`, `lib/detect_commands.sh`,
  `lib/detect_workspaces.sh`, `lib/detect_services.sh`, `lib/detect_ci.sh`,
  `lib/detect_infrastructure.sh`, `lib/detect_test_frameworks.sh`,
  `lib/detect_doc_quality.sh`, `lib/detect_ai_artifacts.sh` (ten files).

### Docs
- `docs/v4-phase5-stub.md` — m29.2 closing notes appended; LOC budget
  table updated; row 13 (init.sh + crawler/detect_*) marked done.

## Acceptance Criteria Not Literally Met

Two acceptance criteria from the milestone could not be met literally;
both documented in `docs/v4-phase5-stub.md::m29.2 closing notes`:

1. **`empty/` fixture ≥ 8 `(none detected)` markers.** The bash report
   formatter `_format_<section>_section` returns early when the section
   is empty (no header emitted). For an empty project the bash output
   contains only 4 `(none detected)` markers (Frameworks, Commands,
   Entry Points, plus one inside the Languages table cell). Modifying
   the bash report formatter to emit empty section markers would violate
   the no-feature-redesign rule. The Go port matches the bash output
   exactly (parity gate passes).

2. **`VERSION` reads `4.29.0`.** The milestone specifies the source state
   as `4.27.x` / `4.28.x` and a bump to `4.29.0`. The actual project
   `VERSION` is `4.33.28` — milestones merged out of order, so m29
   closing lands well past the milestone-number minor. Setting VERSION
   backward to `4.29.0` would regress for caches and tooling observing
   the version. Left at `4.33.28`.

## Architecture Change Proposals

### Adding `Kind` field to `Framework`

- **Current constraint**: `Framework` in `internal/detect/detect.go` had
  only `Name`, `Language`, `Evidence` fields.
- **What triggered this**: The milestone's caller migration goal specified
  `tekhton detect summary --json | jq '.frameworks[] | select(.kind ==
  "ui")'` as the new `detect_ui_framework` extraction path. Without a
  `Kind` field, there was no way to distinguish UI frameworks (E2E test
  runners, platform-adapter targets) from runtime frameworks (Express,
  Django, Spring-Boot, etc.).
- **Proposed change**: Added `Kind string` with `json:"kind,omitempty"`.
  `LanguagesDetector` emits a new `kind=ui_framework` row when
  `detectUIFramework` returns a hit; `frameworksFromResult` demuxes into
  `Framework{Kind: "ui"}`. The `omitempty` tag keeps the JSON shape
  unchanged for the existing rows.
- **Backward compatible**: Yes — `omitempty` keeps the field absent for
  existing rows; bash callers using `_tk_detect_frameworks` see no shape
  change because the wrapper's jq filter `select((.kind // "") != "ui")`
  excludes the new UI rows.
- **ARCHITECTURE.md update needed**: No — the framework JSON shape is
  internal to `internal/detect/` and `cmd/tekhton/detect.go`. The bash
  wrapper signatures don't change.

## Human Notes Status

No HUMAN_NOTES.md items active for this milestone.

## Docs Updated

- `docs/v4-phase5-stub.md` — m29.2 closing notes section appended; row
  13 (init.sh + crawler/detect_*) marked done; LOC budget table updated
  with the m29.2 entry.

## Observed Issues (out of scope)

None — the task scope was clear; the migration touched only the files
documented above.
