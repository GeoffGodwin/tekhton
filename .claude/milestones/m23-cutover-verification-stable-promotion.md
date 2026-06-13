<!-- milestone-meta
id: "23"
status: "todo"
-->

# m23 — Zero-Claude End-to-End Cutover Verification + Stable Promotion Runbook

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | The dogfood loop itself must survive June 15. Tekhton milestones run through `../tekhton-stable` (currently **5.16.8** — it predates qwen-local m17/m18 and all of m19–m22), so even after the cutover fixes land in this tree, the *runtime* executing future milestones is still the old one. We need (a) machine-checked proof that a full pipeline run completes with zero claude-binary executions, and (b) a written, repeatable promotion procedure so stable is refreshed before the deadline and after every future arc — today that procedure exists only as tribal knowledge. |
| **Gap** | (1) No test exercises the whole pipeline (stages + finalize fix agents + commit hooks + quota paths) under `PROVIDER=codex` while *proving* claude is never exec'd — m19–m21 each verify their own seam, but nothing verifies the composition. (2) No cutover runbook: which pipeline.conf keys to set, how to verify codex auth, what to do when codex quota exhausts post-cutover, how to promote this tree over `../tekhton-stable` safely (the rinse-repeat loop) and roll back if the promoted build is bad. (3) Nothing checks at startup that the operator is about to run a Claude-dependent config after the cutover — the first failure would surface mid-run, mid-milestone. |
| **m23 fills** | (1) `tests/test_no_claude_e2e.sh`: builds the tree's `tekhton` binary, constructs a throwaway fixture project, installs a PATH-shim `claude` that records-and-fails any invocation plus a scripted fake `codex` (reusing the m19 shim harness), runs a minimal real milestone through `tekhton run` including finalize, and asserts: run completes, milestone marked done, claude shim never invoked, RUN_SUMMARY `tier_used` ∈ {subscription, local}. (2) A preflight rule (`internal/preflight`): when the resolved provider spec for any stage includes `claude` and claude reports tier `api` and `PROVIDER_ALLOW_PAID_FALLBACK`/`QUOTA_PROBE_ALLOW_PAID` are unset, emit a pre-run warning block naming the keys (fail only with `PREFLIGHT_FAIL_ON_WARN=true`). (3) `docs/cutover-runbook.md`: the June-15 checklist + the stable-promotion procedure (verify → snapshot old stable → rsync/replace → smoke → rollback path), written against the actual two-directory dogfood model. |
| **Depends on** | m19, m20, m21 |
| **Files changed** | `tests/test_no_claude_e2e.sh` (new), `tests/fixtures/cutover_project/` (new fixture), `internal/preflight/` (new rule + test), `docs/cutover-runbook.md` (new), `tests/run_tests.sh`, `docs/v5-polyglot.md` (cross-link) |

---

## Design

### Sequencing note

Must land after m19–m21 — it is the arc's verification gate. In
particular it requires m21's Goal 4 (gating
`internal/preflight/claude_env.go::checkClaudeVersion` on
claude-in-resolved-spec): without that gate, preflight itself execs
`claude --version` whenever the PATH-shim claude exists, and this
milestone's central zero-invocation assertion fails on a correct tree.
m22 is NOT a dependency: the e2e test runs against the fake-codex shim,
not a live local model. Run `tests/test_qwen_local_smoke.sh` manually against the
real 4090 box as a companion check, but don't couple this milestone to
live local serving.

### Goal 1 — `tests/test_no_claude_e2e.sh`

Harness shape (self-skips without `go` or the built binary):

1. Build `tekhton` from this tree into a temp bin dir.
2. Create a fixture target project (copy `tests/fixtures/cutover_project/`):
   git-init'd, trivial `TEST_CMD` (a passing script), pipeline.conf with
   `PROVIDER=codex`, one tiny milestone in `.claude/milestones/` (e.g.
   "create file hello.txt with content hello") authored from
   `.tekhton/MILESTONE_TEMPLATE.md`.
3. PATH precedence dir containing: `claude` → appends argv to
   `claude_invocations.log`, exits 99; `codex` → scripted fake that
   speaks enough of the codex JSONL event protocol to drive each stage
   to a successful outcome (reuse/extend the m19/m20 fake; a canned
   per-label response table is acceptable — determinism over realism).
   The harness also sets `HOME` to a temp dir containing a fake
   `~/.codex/auth.json` (subscription shape) so `codex.Tier()` resolves
   deterministically to `subscription` regardless of the host machine's
   real auth state, and scrubs inherited `PROVIDER_*`, `TEKHTON_*`,
   `CODEX_*` vars.
4. Run `tekhton run` (the real dispatcher path) to completion including
   finalize (final-checks hook included — `FINAL_FIX_ENABLED` left at
   default so the bash delegate path executes).
5. Assertions: exit 0; manifest entry `status=done`; `hello.txt`
   exists in the fixture; `claude_invocations.log` absent or empty —
   if non-empty, print it (each line is a regression pointer to an
   unported call site); RUN_SUMMARY `tier_used` is `subscription` or
   `local`; `scripts/audit-raw-claude.sh` passes on the tree.

Register in `tests/run_tests.sh` behind a `TEKHTON_E2E=1` env guard so
the default suite stays fast; CI/dogfood preflight can opt in.

### Goal 2 — cutover preflight rule

New rule in `internal/preflight` (alongside existing rules): resolve the
provider spec for each pipeline stage (same resolution as
`runner.ResolveProvider`, dry — no construction side effects). If any
resolved spec includes `claude` while the claude tier reports `api` and
neither `PROVIDER_ALLOW_PAID_FALLBACK=true` nor stage pinning excludes
it, emit a WARN block: "stage X may bill the metered Anthropic API;
set PROVIDER_X or PROVIDER_ALLOW_PAID_FALLBACK explicitly." Severity
warn (existing `PREFLIGHT_FAIL_ON_WARN` escalation applies). One block,
listing all affected stages — not one warning per stage.

### Goal 3 — `docs/cutover-runbook.md`

Sections, written against the real dogfood layout (`tekhton` dev tree +
`../tekhton-stable` runtime):

1. **Before June 15 checklist** — codex auth verified (`codex login`
   state, `CODEX_API_KEY` fallback), `PROVIDER` set in each target
   project's pipeline.conf, paid-fallback/probe keys decided,
   qwen-local endpoint smoke-tested (`tests/test_qwen_local_smoke.sh`).
2. **Promoting stable** — run `tests/test_no_claude_e2e.sh` + full
   suites in the dev tree; `git -C ../tekhton-stable describe`/VERSION
   snapshot; archive old stable (`mv` to `tekhton-stable.prev` or git
   tag); replace with this tree's checkout at the promoted commit;
   post-promotion smoke (one trivial milestone in a sandbox project via
   the new stable).
3. **Rollback** — restore `tekhton-stable.prev`, note the failing
   milestone/commit, file the regression as a reliability-fix milestone.
4. **Post-cutover operations** — what codex quota exhaustion looks like
   (m11 retry-after), when to flip `PROVIDER_ALLOW_PAID_FALLBACK`,
   running on qwen-local during outages, reading `tier_used` and the
   m14 cost banner for billing sanity.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `tests/test_no_claude_e2e.sh` | Create | Full-pipeline zero-claude verification harness (env-guarded). |
| `tests/fixtures/cutover_project/` | Create | Minimal target-project fixture: pipeline.conf, agents, one milestone, passing TEST_CMD. |
| `internal/preflight/provider_cutover.go` | Create | Paid-claude-exposure preflight WARN rule. |
| `internal/preflight/provider_cutover_test.go` | Create | Rule matrix: claude-in-spec × tier × override keys. |
| `tests/run_tests.sh` | Modify | Register e2e test behind `TEKHTON_E2E=1`. |
| `docs/cutover-runbook.md` | Create | Cutover checklist + stable promotion/rollback procedure. |
| `docs/v5-polyglot.md` | Modify | Cross-link to the runbook. |

---

## Acceptance Criteria

- [ ] `TEKHTON_E2E=1 bash tests/test_no_claude_e2e.sh` passes on this tree: run exits 0, fixture milestone manifest entry is `done`, `hello.txt` exists, and `claude_invocations.log` is empty or absent.
- [ ] Sabotage check: with the m19 supervise provider resolution reverted (simulated by forcing `PROVIDER=claude` for one stage), the same harness fails and prints the recorded claude argv lines — proving the shim actually detects invocations.
- [ ] The e2e harness self-skips with a clear message when `go` or `codex`-shim prerequisites are unavailable.
- [ ] The preflight rule emits exactly one WARN block when a stage spec includes claude at tier `api` without `PROVIDER_ALLOW_PAID_FALLBACK=true`, and emits nothing when `PROVIDER=codex` everywhere or `TEKHTON_CLAUDE_PRE_JUNE_15=true` (table test).
- [ ] `PREFLIGHT_FAIL_ON_WARN=true` escalates that WARN to a run-aborting failure (existing escalation path, asserted).
- [ ] `docs/cutover-runbook.md` exists and contains the four sections (checklist, promotion, rollback, post-cutover operations) with the stable-promotion steps referencing `../tekhton-stable` and the e2e test as the promotion gate.
- [ ] All new tests pass; no regression in `go test ./...` and `bash tests/run_tests.sh` (default suite unchanged in runtime — e2e is opt-in).
- [ ] `docs/v5-polyglot.md` links to the runbook.

## Watch For

- **The fake codex must drive real stage outcomes:** stages parse provider results for verdicts (intake clarity, reviewer rework routing, tester pass). The canned response table needs per-label outputs that produce success verdicts, or the run stalls in rework loops. Budget real time for this fixture; it is the bulk of the milestone.
- **Finalize is the regression hotspot:** the `_hook_final_checks` bash delegate is exactly where claude-lock hid before m19. Do not disable `FINAL_FIX_ENABLED` in the fixture conf to make the test pass.
- **Env hygiene:** the harness must scrub inherited `PROVIDER_*`, `TEKHTON_*`, and `CODEX_*` vars AND redirect `HOME` to a temp dir with a fake `.codex/auth.json` — `codex.Tier()` reads real auth state (`codex.go:60-72`), so without the fake HOME the `tier_used` assertion is hostage to the host machine's login state.
- **Stable promotion is operator-executed:** this milestone writes the runbook and the gate; it must NOT itself modify `../tekhton-stable` (out of the project tree, and rule 1 — no project-specific logic — applies to paths too: the runbook documents the convention, the code never hardcodes `../tekhton-stable`).
- **Keep the fixture project-agnostic** — no references to Tekhton's own pipeline.conf or milestone numbering.

## Seeds Forward

- **Every future stable promotion** uses the e2e gate + runbook as standard procedure, not just the June-15 event.
- **Provider conformance harness:** the scripted fake-codex protocol fixture is the seed of a reusable provider-conformance test kit (drive any new provider through the same stage-outcome table).
- **CI mode (DESIGN_v5 integrations arc):** `TEKHTON_E2E=1` is the hook a future CI workflow flips on.
