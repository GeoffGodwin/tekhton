# June 15 Cutover Runbook

This runbook describes how Tekhton moves off `claude --print` as the default
provider before the June 15 cutover date, the procedure for promoting the
working tree into `../tekhton-stable`, and how to recover if promotion fails.

The promotion gate is `tests/test_no_claude_e2e.sh`. Until it passes
cleanly with the `cutover_project` fixture, the stable promotion does not
proceed.

## Before June 15

Until the cutover lands, every operator-facing run should already be
routed through the Codex provider (`PROVIDER=codex`). The `qwen-local`
provider remains opt-in pending the m24 capability work.

1. Confirm `PROVIDER` is set to `codex` (or `codex,claude` with
   `PROVIDER_ALLOW_PAID_FALLBACK=true` only when explicitly opted in).
2. Confirm `TEKHTON_CLAUDE_TIER` is unset, `subscription`, or `local` —
   never `api` without `PROVIDER_ALLOW_PAID_FALLBACK=true`. The
   `provider_cutover` preflight check enforces this.
3. Operators on legacy projects that are not yet ready may set
   `TEKHTON_CLAUDE_PRE_JUNE_15=true` to silence the warning. After June
   15 this opt-out becomes a hard error.
4. Run the e2e gate once with `TEKHTON_E2E=1
   bash tests/test_no_claude_e2e.sh` against the
   `tests/fixtures/cutover_project` fixture before any promotion.

## Promoting stable

Promotion moves the validated working tree into the sibling
`../tekhton-stable` checkout that other projects run from.

1. Verify the green run:

   ```bash
   bash tests/run_tests.sh
   TEKHTON_E2E=1 bash tests/test_no_claude_e2e.sh
   ```

2. Audit the tree for any remaining hardcoded `claude --print` callers:

   ```bash
   bash scripts/audit-raw-claude.sh
   ```

3. Fast-forward `../tekhton-stable` to the validated commit:

   ```bash
   cd ../tekhton-stable
   git fetch --all
   git checkout main
   git merge --ff-only <validated-sha>
   ```

4. Re-run `tests/test_no_claude_e2e.sh` from inside `../tekhton-stable`
   to confirm the promoted tree still passes the gate.

## Rollback

If a promotion goes wrong — the e2e gate fails after the merge, a
downstream project reports a regression, or a stage starts re-invoking
`claude --print` unexpectedly — revert by resetting `../tekhton-stable`
to the prior known-good SHA:

```bash
cd ../tekhton-stable
git reflog            # find the prior known-good SHA
git reset --hard <sha>
```

Then re-run `tests/test_no_claude_e2e.sh` to confirm the rollback target
is itself green. File an issue with the failing assertion before
attempting another promotion.

## Post-cutover

After June 15:

1. Drop the `TEKHTON_CLAUDE_PRE_JUNE_15` opt-out from `pipeline.conf`
   files. The preflight rule treats it as a hard error past the date.
2. Default new projects to `PROVIDER=codex` (or `qwen-local` once m24
   ships) — never to `claude`.
3. Keep `tests/test_no_claude_e2e.sh` as the canonical promotion gate.
   Every change that touches the supervise seam must run the gate before
   merging.
