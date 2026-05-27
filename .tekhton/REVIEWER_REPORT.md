# Reviewer Report — m27.3 Parity Gate + CI Wiring + Docs (Re-review cycle 2)

## Verdict
APPROVED

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- The `tekhton run --dry-run` flag is plumbed but never dispatched (noted in `cmd/tekhton/run.go:85`). The coder documents this in Observed Issues and the test header, with a clear explanation of why `tekhton run-stage` per stage is mechanically equivalent for the surface under test. A future milestone should wire the flag so the parity test can drive the full `tekhton run` path end-to-end as originally envisioned by the milestone spec.
- `docs/v4-env-contract.md` is a manual snapshot that will drift as `internal/config/defaults.go` grows. The doc header documents the regeneration command and the coder flags it in Observed Issues. The milestone's Watch For called this out explicitly; a follow-up automation is the right resolution.
- Pre-existing: `test_tester.sh` Test 2 fails with UPSTREAM exit 1 at base commit `3a89ddb` (predates m27.x, `return` vs `exit 1` in `stages/tester_tdd.sh:84`). Out of scope for m27.3.

## Coverage Gaps
- None

## Drift Observations
- `scripts/wedge-audit.sh` now stands at 297 lines after the m27.3 addition — 3 lines below the 300-line hard ceiling. The extraction of companion checks into `scripts/wedge-audit-companions.sh` was the right call; one more assertion block in a future milestone could push the main file over. Worth noting so the next author reaches for the companion pattern rather than inlining.
- `tests/test_stage_env_setu.sh` Signal 2 check (lines 131–139) depends on `/tmp/tekhton_stage_env_${stage}_post.txt` being written by `internal/stagerunner/adapter.go::buildBashScript`. If that dump path changes in a future stagerunner refactor, the Signal 2 check degrades silently rather than failing loudly. A comment near the `STAGES` array pointing to the Go source that writes the dump file would make the implicit dependency explicit.
