<!-- milestone-meta
id: "25"
status: "todo"
-->

# m25 — CI Green: Fixture .gitkeep Trap + golangci-lint Burn-Down

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | The `Go Build` GitHub workflow has zero successful runs in its last 50 — red since before V5 m09. A red CI gate is worthless as a gate: regressions land invisibly, and the m23 stable-promotion procedure can't use CI as a signal. Both failures are mechanical and fully diagnosed; this milestone makes the two failing jobs green and closes the process gap that let 31 lint findings accumulate. |
| **Gap** | (1) `go test` job: `internal/diagnose/testdata/fixtures_v3/no-state/inputs/` contains only an empty `agent_logs/` subdirectory — git cannot track empty directories, so a fresh CI clone has no `inputs/` at all and both `TestFixturesV3_HasFifteenScenarios` (`engine_test.go:39`) and `TestParity_AllFixtures/no-state` (`rules/rules_test.go:161`) fail on the stat. It passes locally only because the dirs exist from fixture authoring (May 31). All 15 fixture scenarios share the empty-`agent_logs/` shape (the other 14 survive because `inputs/` has other tracked files); `tests/fixtures/qwen_local_smoke/.claude/logs/` is the same trap class. (2) `golangci-lint` job (v1.64.5, default linters, pinned in `.github/workflows/go-build.yml:121`): 31 findings — 18 `unused`, 5 `errcheck`, 3 `ineffassign`, 5 `gosimple`/`staticcheck` (full list in Design). (3) Process gap: Tekhton's own `.claude/pipeline.conf:51` `ANALYZE_CMD` runs shellcheck only, and `Makefile` `lint` warn-and-continues, so Go lint never runs anywhere except CI — which nobody was watching. |
| **m25 fills** | (1) Commits a `.gitkeep` in all 15 `internal/diagnose/testdata/fixtures_v3/*/inputs/agent_logs/` directories and in `tests/fixtures/qwen_local_smoke/.claude/logs/`, so fresh clones reproduce the local tree (verified safe: the diagnose engine decides no-state from `.claude/PIPELINE_STATE.md` absence at `engine.go:123-125`, never from directory emptiness, and no non-test diagnose code reads `agent_logs`). (2) Fixes all 31 lint findings by deletion/correction — no `//nolint` suppressions. (3) Appends `&& make lint` to Tekhton's self-host `ANALYZE_CMD` in `.claude/pipeline.conf` so future milestone runs surface Go lint findings to the reviewer (CI stays the hard gate; `make lint` stays soft for machines without the binary). |
| **Depends on** | — |
| **Files changed** | `internal/diagnose/testdata/fixtures_v3/*/inputs/agent_logs/.gitkeep` (15 new), `tests/fixtures/qwen_local_smoke/.claude/logs/.gitkeep` (new), ~20 Go files with lint findings (list in Design), `.claude/pipeline.conf` |

---

## Design

### Goal 1 — kill the empty-directory trap

Create an empty `.gitkeep` file in each of the 16 directories:

- `internal/diagnose/testdata/fixtures_v3/<scenario>/inputs/agent_logs/.gitkeep`
  for all 15 scenarios (`build-failure`, `build-fix-exhausted`,
  `intake-clarity`, `max-turns-coder`, `no-state`,
  `preflight-interactive-config`, `quota-exhausted`,
  `review-rejection-loop`, `rule-emit-format`, `security-halt`,
  `success-run`, `transient-error`, `ui-gate-interactive-reporter`,
  `unknown-fallback`, `version-mismatch`)
- `tests/fixtures/qwen_local_smoke/.claude/logs/.gitkeep`

Only `no-state` breaks CI today, but gitkeeping all 15 prevents the
same trap from re-arming the moment any future test stats another
scenario's `agent_logs`. After adding, run the full diagnose fixture
parity suite and confirm every scenario's verdict is unchanged — the
`.gitkeep` files get copied into the materialized temp project by
`materializeFixture`, and the assertion is that no rule's output
shifts because of them.

Out of scope: the other empty `testdata` directories found in the
sweep (`internal/stages/*/testdata`, `tests/testdata/gates/*/expected`,
`tests/testdata/preflight_parity/*`) — none fail CI today and several
are `expected/`-output dirs where an extra file could perturb
enumeration. Leave them; see Seeds Forward.

### Goal 2 — lint burn-down (point-in-time list of 31)

Fix by deletion or minimal correction — never `//nolint`. The list
below is from run 27420207703 (2026-06-12); re-run
`golangci-lint run --timeout=5m` after rebasing on whatever has landed
since (m19+ may add or remove findings) and fix the union.

**unused (delete the symbol; git history preserves it):**
- `internal/diagnose/engine_test.go:230,265,294,318` — `materializeFixture`, `mapFixturePath`, `readExpected`, `findTekhtonHome` (leftovers; the live copies are in `rules/rules_test.go` — verify that before deleting)
- `internal/diagnose/rules/helpers.go:83,91,109` — `pathFromEnvOr`, `containsLineMatching`, `countLinesMatching`
- `internal/diagnose/rules/resilience.go:310` — `projectFilePath`
- `internal/crawler/rescan_test.go:435` — `ensureGitAvailable`
- `internal/dashboard/dashboard.go:155` — `jsonEscape`
- `internal/errors/agent.go:260` — `trimAll`
- `internal/finalize/hook_bash_delegate.go:90` — `resolveTekhtonLib`
- `internal/stages/intake/verdict_test.go:17,22` — `fakeClarifyHandle` type + `Handle`
- `internal/supervisor/run_test.go:585,589` — `timerStub` type + `Reset`
- `internal/preflight/env.go:42` — field `exactMatch`
- `internal/runner/complete.go:19` — field `totalTurns`

**errcheck (check or explicitly assign the error):**
- `internal/provider/codex/exec_test.go:91`
- `internal/stages/cleanup/helpers_test.go:148`, `stage_test.go:300` (`defer os.Chdir` → `defer func() { _ = os.Chdir(prevWD) }()` or check)
- `internal/test_audit/sampler_test.go:87,88`

**ineffassign (remove the dead assignment):**
- `internal/coder/prerun/fix_agent.go:120` (`currentOutput`)
- `internal/crawler/deps.go:505` (`artifact`)
- `internal/diagnose/helpers.go:69` (`etype`)

**gosimple / staticcheck (apply the suggested rewrite):**
- `internal/finalize/hook_bash_delegate.go:71,74` — S1011 append-spread
- `internal/intake/verdict.go:344` — S1017 `strings.TrimPrefix`
- `internal/test_audit/sampler.go:246` — S1025 plain conversion
- `internal/stages/review/specialist_test.go:61` — SA9003 empty branch (delete it or assert something real)

For the two unused struct **fields**, confirm via `git log -p` that no
in-flight design intended to populate them before deleting; if one is
load-bearing-by-intent, wire it or delete it with a note in the commit.

### Goal 3 — surface lint in the dogfood loop

`.claude/pipeline.conf:51`:

```
ANALYZE_CMD="shellcheck tekhton.sh lib/*.sh stages/*.sh && make lint"
```

`make lint` (Makefile:49) already warn-and-continues when golangci-lint
isn't installed, so this cannot brick machines without the binary;
where it IS installed, findings flow into `ANALYZE_ISSUES` and reach
the reviewer prompt. This is Tekhton's own target-project config — the
runtime defaults stay project-agnostic (rule 1 untouched).

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/diagnose/testdata/fixtures_v3/*/inputs/agent_logs/.gitkeep` | Create | 15 empty keep-files so fresh clones materialize the fixture tree. |
| `tests/fixtures/qwen_local_smoke/.claude/logs/.gitkeep` | Create | Same trap class, qwen smoke fixture. |
| `internal/diagnose/engine_test.go` | Modify | Delete 4 orphaned fixture helpers. |
| `internal/diagnose/rules/helpers.go`, `rules/resilience.go`, `internal/diagnose/helpers.go` | Modify | Delete unused helpers; remove dead `etype` assignment. |
| `internal/crawler/rescan_test.go`, `internal/crawler/deps.go` | Modify | Delete unused helper; remove dead assignment. |
| `internal/dashboard/dashboard.go`, `internal/errors/agent.go`, `internal/finalize/hook_bash_delegate.go` | Modify | Delete unused funcs; S1011 rewrites. |
| `internal/stages/intake/verdict_test.go`, `internal/supervisor/run_test.go` | Modify | Delete unused test doubles. |
| `internal/preflight/env.go`, `internal/runner/complete.go` | Modify | Delete unused struct fields (after intent check). |
| `internal/intake/verdict.go`, `internal/test_audit/sampler.go` | Modify | S1017 / S1025 rewrites. |
| `internal/provider/codex/exec_test.go`, `internal/stages/cleanup/helpers_test.go`, `internal/stages/cleanup/stage_test.go`, `internal/test_audit/sampler_test.go` | Modify | errcheck fixes. |
| `internal/coder/prerun/fix_agent.go` | Modify | ineffassign fix. |
| `internal/stages/review/specialist_test.go` | Modify | SA9003 empty branch. |
| `.claude/pipeline.conf` | Modify | `ANALYZE_CMD` gains `&& make lint`. |

---

## Acceptance Criteria

<!-- NOTE: acceptance runs BEFORE the finalize commit, so criteria here must
     not depend on the files being committed (git ls-files / fresh-clone of
     HEAD would fail on a correct working tree). Tracked-ness is asserted via
     check-ignore now and by CI after the milestone commit lands. -->

- [ ] All 16 `.gitkeep` files exist on disk: `find internal/diagnose/testdata/fixtures_v3/*/inputs/agent_logs tests/fixtures/qwen_local_smoke/.claude/logs -name .gitkeep | wc -l` prints 16.
- [ ] None of the 16 paths is gitignored: `git check-ignore internal/diagnose/testdata/fixtures_v3/*/inputs/agent_logs/.gitkeep tests/fixtures/qwen_local_smoke/.claude/logs/.gitkeep` produces no output (exit 1) — i.e. the finalize commit will actually track them.
- [ ] Post-commit (verified by the next CI run, or manually after finalize): a fresh clone passes `go test ./internal/diagnose/...` — e.g. `d=$(mktemp -d) && git clone --no-hardlinks . "$d" && (cd "$d" && go test ./internal/diagnose/...)`.
- [ ] `TestParity_AllFixtures` passes with verdicts unchanged for all 15 scenarios (no `.gitkeep`-induced rule output shift).
- [ ] `golangci-lint run --timeout=5m` (v1.64.5, repo default config) reports zero issues.
- [ ] No `//nolint` comment is introduced anywhere in the change set: `git diff HEAD` output contains no `nolint` substring (use `! git diff HEAD | grep -q nolint` — plain `grep -c` exits 1 on zero matches and would trip `set -e`).
- [ ] `go build ./...`, `go vet ./...`, and `go test ./...` all pass.
- [ ] `.claude/pipeline.conf` `ANALYZE_CMD` contains `make lint`, and `make lint` on a machine without golangci-lint still exits 0 with the warning (existing Makefile behavior, asserted manually or by inspection).
- [ ] No regression in `bash tests/run_tests.sh`.

## Watch For

- **Coverage gate + fuzz have never executed** — they sit after the failing test step in `go-build.yml` and will run for the first time when this lands. If the coverage gate fails, that is a follow-up milestone, not scope creep here; do not weaken thresholds to force green.
- **Deletion safety for the four `engine_test.go` helpers:** confirm `rules/rules_test.go` contains its own live copies (it does today — `materializeFixture` at `rules_test.go:161` context) before deleting the engine-side ones.
- **Unused struct fields may encode intent:** `exactMatch` (`preflight/env.go:42`) and `totalTurns` (`runner/complete.go:19`) — check git history for an aborted feature before deleting; m19 touches `internal/runner`, so rebase first and re-check.
- **The 31-item list is point-in-time** (run 27420207703). m19 lands before this milestone executes — re-run the linter and fix the union, don't blindly apply the list.
- **Don't create `.golangci.yml` here.** CLAUDE.md rule 3 mentions an "advanced preset" that was never authored; adopting one would surface a much larger finding set and is its own milestone (see Seeds Forward).
- **`.gitkeep` only in `inputs/` trees**, never in `expected/` dirs — expected-output enumeration could pick the file up as a baseline.
- **The "behaviorally inert" claim rests on one filter:** `mapFixturePath` materializes `agent_logs/*` into `.claude/logs/`, and the non-test `CollectAgentLogTails` (`internal/diagnose/helpers.go:188-225`) DOES `os.ReadDir` that directory — `.gitkeep` is skipped only because of the `\.log$` basename filter at `helpers.go:114`. The parity AC catches a regression, but don't loosen that filter casually.
- **Linter version skew:** CI pins golangci-lint v1.64.5; a different local version (`make lint`) may report a slightly different finding set. The CI-pinned version is the arbiter — install/match it for the zero-issues AC.

## Seeds Forward

- **m23 promotion gate:** a green CI badge becomes a usable pre-promotion signal in the cutover runbook.
- **Advanced lint preset:** once green on defaults, authoring the DESIGN_v4 Risk §9 `.golangci.yml` (gocyclo, etc.) becomes a measurable, incremental milestone instead of an avalanche.
- **Coverage/fuzz first light:** whatever the never-run steps reveal lands as a scoped reliability-fix milestone with this one as the baseline.
- **Empty-dir hygiene:** the out-of-scope empty `testdata` dirs are now a known, documented trap class if future tests start stat'ing them.
