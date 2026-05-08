# Reviewer Report — m19: tekhton run Top-Level Command (cycle 2)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `runner.go:251` (`BashHookRunner.Finalize`): `res.Disposition` is dereferenced at line 251 before the `if res != nil` guard at line 253, making the guard unreachable dead code. Both callers pass non-nil `res`, so no runtime risk, but the guard is misleading. Promote it above the env-append block or remove it. (Carried from cycle 1; rework did not touch this path.)
- `resume.go:74` (`isCompleteLoopExit`): manual `len+slice` comparison still used instead of `strings.HasPrefix(exit, "complete_loop_")`. No correctness impact. (Carried from cycle 1.)
- `run.go` switch: `--dry-run` flag is accepted and stored in `RunRequestV1.DryRun` but the RunE dispatch switch has no dry-run branch — `tekhton run --task "x" --dry-run` will invoke agents for real. A comment at the dispatch switch noting this as deferred scope (m20 / Phase 5) would prevent future confusion. (Carried from cycle 1.)

## Coverage Gaps
- None — `TestResumeProductionPath` and `TestResumeProductionPathRejectsMissingAmbient` were added in cycle 2, closing the cycle-1 coverage gap. Coverage is at 83.1%.

## ACP Verdicts
No ACPs were raised in CODER_SUMMARY.md.

## Drift Observations
- All `orchestrate_*.sh` sourced library files still carry `set -euo pipefail`. Per CLAUDE.md sourced lib files should not repeat this declaration (they inherit). The pattern predates m19; the new `orchestrate_complete.sh` and `orchestrate_save.sh` replicate it correctly. Worth a family-wide hygiene pass in a dedicated non-blocking milestone.
- `scripts/run-parity-check.sh` header describes a 10-scenario comparison (lines 5–18) but the script body implements 4 structural checks. The gap is acknowledged inline but the headline may mislead future developers; either update the comment or stub the remaining 6 scenarios.

---

## Cycle 2 Blocker Verification

**Prior blocker: `Runner.Resume(ctx)` broken — empty `ProjectDir`/`TekhtonHome` on rebuilt request.**

FIXED. Evidence:

1. `Runner` struct now carries `ProjectDir string` and `TekhtonHome string` fields (runner.go:95–96) with a clear comment explaining the Phase-5 migration path.
2. `buildRunner` in `run.go` populates both fields from the parsed request (run.go:220–221), so every CLI dispatch has ambient context.
3. `requestFromSnapshot` (resume.go:55–71) copies `r.ProjectDir` and `r.TekhtonHome` onto the rebuilt `RunRequestV1`, so `validateAndDefault` can pass.
4. `TestResumeProductionPath` (resume_test.go:112–139) calls `r.Resume(ctx)` directly (not through `resumeWithEnv`) with `r.ProjectDir` and `r.TekhtonHome` set, and asserts success.
5. `TestResumeProductionPathRejectsMissingAmbient` (resume_test.go:142–162) confirms validation still trips when both fields are left empty — the fix did not weaken the gate.
