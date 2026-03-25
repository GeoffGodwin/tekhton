# Jr Coder Summary — Architect Remediation

**Date:** 2026-03-25
**Focus:** Staleness Fixes (SF-1, SF-2)

## What Was Fixed

### SF-1: PIPELINE_ORDER Validation Cross-References
- **lib/config.sh:169** — Added three-line comment block above the `if [[ -n "${PIPELINE_ORDER:-}" ]]` validation block explaining:
  - Normalization runs here during `load_config()` before `pipeline_order.sh` is sourced
  - `validate_pipeline_order()` in `pipeline_order.sh` provides the test-facing validation API
  - When adding a new order value, **both locations** must be updated
- **lib/pipeline_order.sh:27** — Added three-line note above `validate_pipeline_order()` function explaining:
  - `load_config()` in `config.sh` contains a parallel inline case block that runs before this library is sourced
  - Any new order value must be added to **both locations**
  - This function is the test-facing validation API; `config.sh` is the runtime normalizer

**Rationale:** Documents the split responsibility between config-time normalization and test-time validation, preventing future bugs when new order values are added.

### SF-2: Loop-Local Variable Declarations in express.sh
- **lib/express.sh:87** — Added `_source _conf` to the existing `local` declaration. Changed:
  ```bash
  local cmd_type cmd
  ```
  to:
  ```bash
  local cmd_type cmd _source _conf
  ```
  This ensures variables assigned by the first `while IFS='|' read -r` loop (line 88) are declared as local and do not leak to global scope.

- **lib/express.sh:218** — Added `_csrc _cconf` to the existing `local` declaration. Changed:
  ```bash
  local _ctype _ccmd
  ```
  to:
  ```bash
  local _ctype _ccmd _csrc _cconf
  ```
  This ensures variables assigned by the second `while IFS='|' read -r` loop (line 219) are declared as local and do not leak to global scope.

**Rationale:** Follows bash convention: variables assigned by `read -r` inside a loop must be declared `local` before the loop to prevent global namespace pollution. The underscore prefix (`_source`, `_conf`, etc.) indicates "discard, don't rely on," but proper scoping is still required.

## Files Modified

- `lib/config.sh` — Added cross-reference comment (3 lines)
- `lib/pipeline_order.sh` — Added cross-reference comment (3 lines)
- `lib/express.sh` — Added `local` declarations (2 declarations across two read loops)

## Verification

✓ All modified files pass `bash -n` syntax check
✓ All modified files pass `shellcheck` (pre-existing warnings unrelated to changes)
✓ Comments correctly placed and formatted
✓ Variable declarations properly scoped

## Notes

- **Dead Code Removal:** No dead code items in ARCHITECT_PLAN.md
- **Naming Normalization:** No naming normalization items in ARCHITECT_PLAN.md
- **Simplification & Design Doc Observations:** Deferred to senior coder and human review per scope guidelines

All changes are mechanical, bounded, and test-focused per junior coder mandate.
