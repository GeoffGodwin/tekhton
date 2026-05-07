# Coder Summary

## Status: COMPLETE

## What Was Implemented

Milestone 16 — Config Loader Wedge. Pipeline configuration loading,
defaulting, validation, clamping, CI auto-detection, and emit are now owned
by Go code under `internal/config`, reached by bash callers through a
≤50-line shim that execs `tekhton config load --emit shell`. The on-disk
`pipeline.conf` format is unchanged; existing user configs load without edits.

Key pieces:

- **`internal/config/`** — typed loader package. Nine-phase load pipeline
  (parse → required-key check → seed-from-env → base defaults → CI gate →
  late defaults → inline validation → clamps → path resolution → milestone
  overrides). `Load(path, opts)` returns a `*Config` carrying `Values`,
  `KeysSet`, `Warnings`, `Errors`, `CIDetected`, `CIPlatform`. Sentinel
  errors `ErrNotFound`, `ErrParse`, `ErrMissingRequired`, `ErrValidation`
  match with `errors.Is`.
- **Defaults table** — `baseDefaults` (~470 entries) mirrors the legacy
  `lib/config_defaults.sh` line-for-line. Resolver functions (`lit`,
  `ref`, `concat`, `imul`, `idiv`, `iadd`, `tdFile`) preserve derived-default
  semantics (`MILESTONE_CODER_MAX_TURNS = CODER_MAX_TURNS * 2`, etc.).
  Env-set values seed before defaults so the bash `: "${KEY:=value}"`
  precedence is preserved.
- **CI auto-detection** — `DetectCI()` ports
  `_detect_runtime_ci_environment` + `_get_ci_platform_name`. Recognises
  GitHub, GitLab, CircleCI, Travis, Buildkite, Jenkins, Azure, TeamCity,
  Bitbucket, plus the generic `CI=true` fallback. `applyCIGateDefault`
  encodes the m138 contract: explicit `pipeline.conf` value always wins,
  CI signal elevates `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` to `1`,
  diagnostic stderr line emitted only when `VERBOSE_OUTPUT=true`.
- **Validation + clamps** — `runInlineValidation` ports the case
  statements at the bottom of `load_config()` (PIPELINE_ORDER,
  UI_FRAMEWORK, INTAKE_*, DASHBOARD_VERBOSITY, HEALTH_WEIGHT_* sum, etc.).
  `runClamps` ports the `_clamp_config_value`/`_clamp_config_float`
  calls. Bad values are reset to safe defaults and recorded in
  `cfg.Warnings` (the bash side emits to stderr).
- **Emit** — `EmitShell(w)` writes `export KEY='value'` lines with
  single-quote escaping; `EmitJSON(w, indent)` writes a `tekhton.config.v1`
  envelope.
- **Cobra wiring** (`cmd/tekhton/config.go`) — `tekhton config load`,
  `config show`, `config validate [--strict]`, `config defaults`. Exit
  codes match the rest of the binary (`exitNotFound`, `exitCorrupt`,
  `exitUsage`).
- **Bash shims** — `lib/config.sh` (46 lines) and `lib/config_defaults.sh`
  (45 lines) exec the Go binary and source/eval its emit-shell payload.
  `lib/config_defaults_ci.sh` deleted; logic now runs inside
  `internal/config/ci.go`.
- **Parity gate** — `scripts/config-parity-check.sh` runs 10 fixtures
  (`tests/fixtures/config/01_minimal.conf` ... `10_milestone_mode.conf`)
  through the Go binary and asserts behavioural parity with the legacy
  bash loader: defaults, operator overrides, CI auto-detection, explicit
  override, integer + float clamps, enum resets, health-weight reset,
  path resolution, quoted/inline-comment parsing, milestone-mode
  overrides, required-key enforcement.

## Acceptance Verification

- `tekhton config load --emit shell | source` matches the post-`load_config`
  bash environment for all 10 fixtures (parity script: 36/36 PASS).
- `tekhton config validate --strict` rejects out-of-range values and
  unknown enums with clear diagnostics (covered by
  `cmd/tekhton/config_test.go::TestConfigValidate_StrictPromotesWarnings`).
- `pipeline.conf` format unchanged; `tests/test_config.sh` confirms.
- `lib/config.sh` is 46 lines (≤60).
- `lib/config_defaults_ci.sh` deleted.
- `internal/config` coverage: 83.3% (≥80%).
- Parity script: PASS (36/36 assertions).
- `bash tests/run_tests.sh`: 498 shell + 250 python + Go all PASS.

## Root Cause (bugs only)

N/A — milestone wedge implementation, not a bug fix.

## Files Modified

### New Go code
- `internal/config/config.go` (NEW) — Loader entry point + `Config` type.
- `internal/config/parse.go` (NEW) — `pipeline.conf` parser (KEY=VALUE,
  comment stripping, quote stripping, shell-metachar rejection).
- `internal/config/defaults.go` (NEW) — `baseDefaults` table +
  `applyDefaults`, `applyLateDefaults`, `applyMilestoneOverrides`.
- `internal/config/validate.go` (NEW) — Inline validation + integer/float
  clamps + path resolution.
- `internal/config/ci.go` (NEW) — `DetectCI` + `applyCIGateDefault`
  (m138 port).
- `internal/config/emit.go` (NEW) — `EmitShell` + `EmitJSON`.
- `internal/config/config_test.go` (NEW) — Direct unit tests for the
  package; 83.3% line coverage.
- `cmd/tekhton/config.go` (NEW) — Cobra subcommands
  (`load|show|validate|defaults`).
- `cmd/tekhton/config_test.go` (NEW) — Cobra wiring tests.
- `cmd/tekhton/main.go` — Register `newConfigCmd()` on the root command.

### Bash shims
- `lib/config.sh` — Rewrite as ≤50-line shim (was full loader).
- `lib/config_defaults.sh` — Rewrite as 45-line shim (was full defaults table).
- `lib/config_defaults_ci.sh` — DELETED (logic in `internal/config/ci.go`).

### Tests adapted
- `tests/test_config.sh` — Drives the binary round-trip.
- `tests/test_config_clamp_build_fix_attempts.sh` — Exercises clamps
  through the binary.
- `tests/test_config_leading_dot_float.sh` — Float-clamp parsing through
  the binary.
- `tests/test_m138_coverage_gaps.sh` — `applyCIGateDefault` via the binary.
- `tests/test_ci_environment_detection.sh` — Re-targeted at the binary.
- `tests/test_dedup_callsites.sh` — Updated to skip the new shim files.
- `tests/test_m72_tekhton_dir.sh`, `tests/test_m84_tekhton_dir_complete.sh`,
  `tests/test_milestone_split.sh` — Adapted for the new shim layout.

### Fixtures + scripts
- `tests/fixtures/config/01_minimal.conf` ... `10_milestone_mode.conf` (NEW)
  — Ten parity fixtures.
- `scripts/config-parity-check.sh` (NEW) — 10-fixture acceptance gate.

### Docs
- `ARCHITECTURE.md` — Updated `lib/config.sh` / `lib/config_defaults.sh`
  entries to describe the wedge shim, added `internal/config/` and
  `cmd/tekhton/config.go` entries.
- `CLAUDE.md` — Repository layout updated to call out the shim status.
- `docs/go-build.md` — Added `tekhton config …` subcommand reference
  (load/show/validate/defaults, exit codes, flag semantics).

## Docs Updated

- `ARCHITECTURE.md` — `lib/config.sh`, `lib/config_defaults.sh`,
  `internal/config/`, `cmd/tekhton/config.go` entries (public surface).
- `CLAUDE.md` — Repository layout for `lib/config.sh`,
  `lib/config_defaults.sh`; deleted `lib/config_defaults_ci.sh` line.
- `docs/go-build.md` — `tekhton config …` subcommand reference.

## Human Notes Status

No notes were targeted by this run. The milestone-mode pipeline does not
ingest `HUMAN_NOTES.md` items; existing unchecked notes (action-items
refresh bug, m01/m02 doc-cleanup polish) remain pending for a future
human-mode run.
