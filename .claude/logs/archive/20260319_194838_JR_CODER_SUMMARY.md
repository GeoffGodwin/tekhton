# Junior Coder Summary — Milestone 15.1.1

## What Was Fixed

- **stages/coder.sh:330** — Updated stale log message to reflect current flag-only gating behaviour.
  - **Old message:** "Human notes exist but task does not reference them — skipping notes injection."
  - **New message:** "Human notes exist but no notes flag set (--human, --with-notes, or --notes-filter) — skipping notes injection."
  - **Why:** The message incorrectly implied task-text matching inspection was happening. After M15.1.1, the `elif` branch fires when no notes flags are set (flag-only gating), not when the task text fails to match. This fix ensures the message accurately describes the condition to operators debugging notes-injection behaviour.

## Files Modified

- `stages/coder.sh` (1 line changed)

## Verification

- ✓ `bash -n` syntax check passed
- ✓ `shellcheck` validation passed
