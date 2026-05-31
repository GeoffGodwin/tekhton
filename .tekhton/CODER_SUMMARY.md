# Coder Summary

## Status: COMPLETE

## What Was Implemented

Milestone **m32.2 — Diagnose Rules** (second of three children porting the
diagnose subsystem). Replaces the m32.1-shipped `BashRuleAdapter` with a
Go-native rule registry under `internal/diagnose/rules/`. Every rule that
matches against pipeline failure context now runs in-process — no more
bash exec-per-rule. The seam is unchanged (the `diagnose.Rule` /
`diagnose.RuleProvider` interface m32.1 designed), so `Engine.Run` and
`Engine.ReadContext` are untouched except for the read-side enrichment
the rules need (see below).

### `internal/diagnose/rules/` additions (NEW package)

- **`registry.go`** (74 lines) — `Registry` implements `diagnose.RuleProvider`;
  the package-level `registry` slice is the priority-ordered list of 18 rule
  structs mirroring `lib/diagnose_rules_registry.sh:DIAGNOSE_RULES`
  byte-for-byte. `Rules()` returns a defensive copy so callers cannot mutate
  the canonical priority order.

- **`core.go`** (419 lines) — 8 rules ported from `lib/diagnose_rules.sh`:
  `BuildFailure`, `MaxTurns` (both `MAX_TURNS_EXHAUSTED` and the M133
  `MAX_TURNS_ENV_ROOT` cascading-symptom branch), `ReviewLoop`,
  `SecurityHalt`, `IntakeClarity`, `QuotaExhausted`, `StuckLoop`, `Unknown`.
  Plus the `containsUnchecked`, `bumpTurnLimit`, `atoiOr`, `tryAtoi`
  helpers used by multiple rules.

- **`extra.go`** (220 lines) — 5 rules from `lib/diagnose_rules_extra.sh`:
  `MixedClassification` (intentionally low-confidence — the only LOW-conf
  rule in the registry), `TurnExhaustion`, `SplitDepth`, `TransientError`,
  `TestAuditFailure`. `lineMatchesVerdictNeedsWork` ports the
  `grep -qi 'Verdict:.*NEEDS_WORK'` predicate.

- **`migration.go`** (135 lines) — 2 rules from
  `lib/diagnose_rules_migration.sh`: `MigrationCrash` (LFC primary →
  high; backup-dir + missing version pin → medium) and
  `VersionMismatch` (medium confidence).

- **`resilience.go`** (315 lines) — 2 rules from
  `lib/diagnose_rules_resilience.sh`: `UIGateInteractiveReporter` (all
  4 source paths preserved — `primary_signal` → high, `classification`
  → high, raw-log evidence → medium, RUN_SUMMARY correlation → medium;
  CI-guard detection branches the suggestion text exactly as the bash
  rule does), `BuildFixExhausted` (RUN_SUMMARY build_fix_stats → infer
  `## Attempt` count → secondary signal fallback; required-guard on
  build-error artifact presence preserved). `extractJSONSection` ports
  the bash awk `{f=1} f{print; if(/\}/){exit}}` snippet.

- **`resilience_preflight.go`** (150 lines) — 1 rule from
  `lib/diagnose_rules_resilience_preflight.sh`:
  `PreflightInteractiveConfig`. All 3 source paths preserved (RUN_SUMMARY
  preflight_ui section → PREFLIGHT_REPORT.md fail entry → LFC explicit
  signal/classification).

- **`helpers.go`** (132 lines) — Shared `taskOrFallback`,
  `projectFileExists`, `projectFileNonEmpty`, `readProjectFile`,
  `projectPath`, `envOr`, `containsLineMatching`, `countLinesMatching`,
  `quoteTask` — pure helpers used by all rule files so per-rule code
  reads as direct ports of the bash function bodies.

- **`version.go`** (81 lines) — `extractPipelineConfigVersion` (Go port
  of bash `detect_config_version`'s slice we need), `majorMinor` (bash
  `${TEKHTON_VERSION%.*}`), `versionLT` + `splitVersion` (component-wise
  integer comparison, Go port of bash `_version_lt`).

- **Test files** (~900 lines total):
  - `registry_test.go` — order-mismatch parity test (hard-coded want
    slice), 18-rule count assertion, defensive-copy test.
  - `core_test.go` — per-rule match/no-match tables for the 7
    deterministic core rules (Unknown gets a separate always-matches
    test).
  - `extra_test.go` — per-rule tables for the 5 extra rules
    (`TestSplitDepth_Match` + `TestTestAuditFailure_Match` use
    `t.Setenv` so they cannot `t.Parallel()`).
  - `migration_test.go` — both branches of `MigrationCrash` (high /
    medium / no-match) + `VersionMismatch` table.
  - `resilience_test.go` — all 4 sources of UI-gate rule individually,
    `.md`-self-trigger guard, all 3 sources of build-fix-exhausted +
    the required artifact guard, 2 sources of preflight-config rule.
  - `rules_test.go` — cross-rule priority assertions
    (build-fix-exhausted beats build-failure; unknown is always last)
    + the load-bearing 15-baseline parity test
    `TestParity_AllFixtures` that replays every
    `internal/diagnose/testdata/fixtures_v3/<scenario>/inputs/`
    through `diagnose.NewEngine(rules.New())` and asserts
    `Classification` / `Confidence` / `Stage` / `RuleName` match the
    captured baseline.

### `internal/diagnose/` modifications

- **`types.go`** — Added 6 fields to `Context` so the rules can read what
  bash reads from PIPELINE_STATE.md + RUN_SUMMARY.json: `Notes`,
  `PipelineAttempt`, `AgentErrorCategory`, `AgentErrorSubcategory`,
  `AgentErrorTransient`, `SplitDepth`. Updated the package doc comment
  and `Rule` / `RuleProvider` interface doc comments to reflect the m32.2
  cut-over (BashRuleAdapter is gone; `*rules.Registry` is the canonical
  provider).

- **`engine.go`** — Extended `ReadContext` to populate the 6 new Context
  fields from `state.Read()` (first-class + `Extra` map) and
  `RUN_SUMMARY.json` (`split_depth`). Updated the package doc comment.

- **`engine_test.go`** — Removed the m32.1 `TestBashAdapterIntegration_MaxTurnsCoder`
  (its coverage moved to `rules_test.go::TestParity_AllFixtures`, which
  is broader: 15 fixtures, no bash subprocess).

### `internal/errors/` additions

- **`evidence.go`** (189 lines, NEW) — Match-evidence regexes + typed
  helpers the diagnose rules consume. Distinct from `patterns.go`
  (build-error classifier registry). Exposes: `MatchUIGateInteractiveHTML`,
  `MatchHTMLReporterCIGuard`, `MatchPreflightReportFailWord`,
  `ExtractRunSummary{PrimarySignal,RouteTaken,InteractiveDetected,
  ReporterPatched,InteractiveConfigFile}`, `ExtractBuildFix{Outcome,Attempts}`,
  `ExtractFailureCtx{Classification,MigrationFrom,MigrationTo}`,
  `Match{FailureCtxMixedSignal,SummaryMixedPrimarySignal,
  FailureCtxPreflightConfig,PipelineConfigVersionPin}`,
  `CountBuildFixReportAttempts`, `LastBuildFixProgressLineNoProgress`,
  `ScanFiles`. Lives in `internal/errors` per the m32.2 boundary so the
  rule files stay free of `import "regexp"`.

- **`scan.go`** (39 lines, NEW) — `scanFilesImpl` — regex-free recursive
  walker (`filepath.WalkDir`) for the UI-gate rule's `.claude/logs/*.{log,jsonl}`
  scan. Split from `evidence.go` so the evidence module stays a
  regex-only file.

### `cmd/tekhton/diagnose.go` modifications

- **`newDiagnoseRunCmd`** — Wires `diagnose.NewEngine(rules.New())` in
  place of the m32.1 `&diagnose.BashRuleAdapter{...}`. Updated doc
  comment to reflect the cut-over.

### Deletions

- **`internal/diagnose/bash_rule_adapter.go`** — Replaced by
  `*rules.Registry`.
- **`internal/diagnose/bash_rule_adapter_test.go`** — Coverage moved to
  `rules/rules_test.go` (broader: drives the full 15-fixture parity).

### Acceptance gate additions

- **`scripts/wedge-audit-companions.sh`** — Appended the m32.2
  no-regexp-in-rules companion check: `grep -rl '"regexp"'
  internal/diagnose/rules` must return empty. Fails the audit with a
  remediation hint pointing at `internal/errors/evidence.go`.

- **`tests/test_wedge_audit_rules.sh`** (NEW, 79 lines) — Regression
  test that plants a `//go:build ignore`-tagged file with
  `import "regexp"` inside `internal/diagnose/rules/`, runs
  `wedge-audit.sh`, asserts non-zero exit + that the offending file
  path appears in stderr, then cleans up and verifies the audit goes
  green again. 3 assertions, all passing.

### Fixture corrections (the m32.1 stubs needed alignment with bash logic)

- **`build-fix-exhausted/inputs/BUILD_FIX_REPORT.md`** — Replaced the
  free-form `Attempt 1: failed` text with the canonical `## Attempt`
  heading shape the bash rule's source-2 path counts. Three attempts +
  `- Progress signal: unchanged` so the rule infers `no_progress`.
- **`ui-gate-interactive-reporter/inputs/LAST_FAILURE_CONTEXT.json`** —
  Changed `primary_cause.signal` from the stub value
  `playwright_html_reporter_hang` to the bash rule's source-1 value
  `ui_timeout_interactive_report` so the rule fires at the high-confidence
  source.
- **`version-mismatch/inputs/pipeline.conf`** (NEW) — Added the
  `TEKHTON_CONFIG_VERSION=3.0` pin the bash rule reads.
- **`version-mismatch/expected/verdict.txt`** — Corrected `confidence=high`
  → `confidence=medium` (the bash rule always emits medium — the original
  stub was aspirational).
- **`quota-exhausted/inputs/QUOTA_PAUSED`** (NEW, empty file) — Added
  the marker file the bash rule's `[[ -f QUOTA_PAUSED ]]` predicate
  requires.

### Documentation

- **`ARCHITECTURE.md`** — Replaced the m32.1 `BashRuleAdapter`
  description in the `cmd/tekhton/diagnose.go` and `internal/diagnose/`
  entries with the m32.2 `rules.New()` wiring + new Context fields.
  Added a fresh entry for `internal/diagnose/rules/` (one paragraph
  enumerating every rule file + the parity test) and
  `internal/errors/evidence.go` (typed helpers + scan.go).

## Root Cause (bugs only)

N/A — feature-port milestone.

## Files Modified

### Created (NEW)
- `internal/diagnose/rules/registry.go` (NEW)
- `internal/diagnose/rules/registry_test.go` (NEW)
- `internal/diagnose/rules/core.go` (NEW)
- `internal/diagnose/rules/core_test.go` (NEW)
- `internal/diagnose/rules/extra.go` (NEW)
- `internal/diagnose/rules/extra_test.go` (NEW)
- `internal/diagnose/rules/migration.go` (NEW)
- `internal/diagnose/rules/migration_test.go` (NEW)
- `internal/diagnose/rules/resilience.go` (NEW)
- `internal/diagnose/rules/resilience_preflight.go` (NEW)
- `internal/diagnose/rules/resilience_test.go` (NEW)
- `internal/diagnose/rules/helpers.go` (NEW)
- `internal/diagnose/rules/version.go` (NEW)
- `internal/diagnose/rules/rules_test.go` (NEW)
- `internal/errors/evidence.go` (NEW)
- `internal/errors/scan.go` (NEW)
- `tests/test_wedge_audit_rules.sh` (NEW)
- `internal/diagnose/testdata/fixtures_v3/version-mismatch/inputs/pipeline.conf` (NEW)
- `internal/diagnose/testdata/fixtures_v3/quota-exhausted/inputs/QUOTA_PAUSED` (NEW)

### Modified
- `internal/diagnose/types.go` — added 6 Context fields + updated package
  & interface doc comments
- `internal/diagnose/engine.go` — populate new Context fields in
  ReadContext; updated package doc
- `internal/diagnose/engine_test.go` — removed obsolete BashRuleAdapter
  integration test
- `cmd/tekhton/diagnose.go` — wire `rules.New()`; updated doc comment
- `cmd/tekhton/diagnose_test.go` — updated obsolete comment
- `scripts/wedge-audit-companions.sh` — appended m32.2 no-regexp-in-rules check
- `internal/diagnose/testdata/fixtures_v3/build-fix-exhausted/inputs/BUILD_FIX_REPORT.md` — `## Attempt` headers
- `internal/diagnose/testdata/fixtures_v3/ui-gate-interactive-reporter/inputs/LAST_FAILURE_CONTEXT.json` — canonical primary signal
- `internal/diagnose/testdata/fixtures_v3/version-mismatch/expected/verdict.txt` — `confidence=medium`
- `ARCHITECTURE.md` — updated diagnose entries + new rules/evidence entries

### Deleted
- `internal/diagnose/bash_rule_adapter.go`
- `internal/diagnose/bash_rule_adapter_test.go`

## Test Results

- `go test ./internal/diagnose/... ./internal/errors/... ./cmd/tekhton/...` PASS
- `go test ./...` PASS (all 29 Go packages)
- `go vet ./...` clean
- `gofmt -l` clean for every file I created or modified
- `shellcheck` clean on `tekhton.sh lib/*.sh stages/*.sh scripts/wedge-audit*.sh tests/test_wedge_audit_rules.sh`
- `bash tests/run_tests.sh` — 503 shell PASS + Go PASS (was 502; +1 for
  `test_wedge_audit_rules.sh`)
- `bash scripts/wedge-audit.sh` — clean (192 files audited)
- `bash scripts/audit-bash-env.sh` — clean
- `bash tests/test_wedge_audit_rules.sh` — 3/3 PASS
- 15-baseline parity test (`TestParity_AllFixtures`) — all 15 scenarios
  match their `verdict.txt` baseline byte-for-byte
- `grep -rln '"regexp"' internal/diagnose/rules/` — empty (m17 boundary
  preserved)
- `find internal/diagnose -name 'bash_rule_adapter*'` — empty
  (BashRuleAdapter fully removed)
- `find lib -name 'diagnose*.sh' -o -name 'remediation.sh' | wc -l` —
  11 (no bash deletes — m32.3 owns those)

### Note: pre-existing `make dogfood` failure

`make dogfood` fails on `tests/test_stage_env_setu.sh` because stages
source `lib/gates.sh`, which was deleted in m31.1. This failure
pre-exists m32.2 — same failure reported by m32.1 and verifiable by
checking out m32.1's tip. Out of scope for this milestone; recorded
under `## Observed Issues (out of scope)` below.

## Human Notes Status

No human notes referenced for m32.2.

## Docs Updated

- `ARCHITECTURE.md` — updated `cmd/tekhton/diagnose.go` + `internal/diagnose/`
  entries; added `internal/diagnose/rules/` + `internal/errors/evidence.go`
  entries.

## Observed Issues (out of scope)

- `tests/test_stage_env_setu.sh` (driven by `make dogfood`) — every
  stage (intake, coder, security, review, tester) fails its env-dump
  step because it sources `lib/gates.sh`, which was deleted in m31.1.
  Confirmed pre-existing — same failure shape as m32.1. Should be
  resolved as a m31-arc follow-up before m32.3 bumps VERSION. The
  source line is in the env-dump bash snippet inside
  `tests/test_stage_env_setu.sh`; replacing the `source lib/gates.sh`
  line with `source tekhton-legacy.sh` (which now owns the
  `run_build_gate` shim) should fix it.
