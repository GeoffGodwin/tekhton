# JR Coder Summary

## What Was Fixed

- **Staleness Fix**: Updated misleading comment at `crawler_content.sh:149`
  - **Before**: `# --- Structured emitter — moved from crawler_emit.sh per M67 spec ------------`
  - **After**: 
    ```
    # --- Structured emitter — moved here from crawler_emit.sh (size management; -------
    # --- M67 spec originally placed this in crawler_emit.sh) -----------------------
    ```
  - **Rationale**: The original comment was misleading. It implied the current placement was spec-intentional, when in fact the function was moved *out* of crawler_emit.sh for size management—contrary to the spec's original placement. The corrected comment now clearly explains this deviation and prevents future confusion.

## Files Modified

- `lib/crawler_content.sh` (line 149–150)

## Verification

- ✓ Syntax check passed (`bash -n`)
- ✓ No breaking changes — comment-only modification
