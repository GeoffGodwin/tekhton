# Reviewer Report — m28.1 Serena Template + Resolver Fix

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/mcp.sh:76`: Function header comment reads "Sets _SERENA_DIR, _SERENA_PYTHON on success" but `_SERENA_BIN` is now also set on the success path. Update to "Sets _SERENA_DIR, _SERENA_PYTHON, _SERENA_BIN on success."
- `lib/mcp.sh:261`: `check_serena_available()` still tests via `"$_SERENA_PYTHON" -c "import serena"`. `_SERENA_PYTHON` is legitimately retained for pip-invocation purposes, but this availability check is orthogonal to the binary surface fixed in m28.1. If `_SERENA_PYTHON` is removed in a future milestone, this function will need updating. No action needed for m28.1.
- `scripts/wedge-audit.sh` is at 307 lines (7 over the 300-line hard ceiling). Coder documented this accurately as pre-existing drift caused by two commits in the m27.3/m28.1 chain. No net changes were made to this file in the current cycle. The extraction path is established (`scripts/wedge-audit-companions.sh` at 53 lines); a follow-up milestone should move one block into the companions file.

## Coverage Gaps
- None

## ACP Verdicts
- ACP: SERENA_BIN placement (resolve after pip install, above sed block) — **ACCEPT** — Resolving after pip install is the only correct order; the binary does not exist until pip creates the console-script entry point. The implementation places resolution on lines 235-242 of `setup_serena.sh`, safely after the `pip install -e .` call at line 143.

## Drift Observations
- `lib/mcp.sh:15`: `set -euo pipefail` appears in a sourced library file. Reviewer checklist calls for sourced `lib/` files to inherit rather than declare. Pre-existing condition; not introduced by m28.1, but worth scheduling for a cleanup pass.
- Pre-existing: `test_tester.sh` Test 2 fails with UPSTREAM exit 1 (`stages/tester_tdd.sh:84`, `return` vs `exit 1`). Predates m27.x; out of scope for m28.1.
