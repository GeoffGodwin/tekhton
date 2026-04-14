## What Was Fixed

- Added missing `set -euo pipefail` to `lib/validate_config.sh` line 2, immediately after the shebang. This ensures the file conforms to project standards (all other lib files in the codebase have this safety pragma).

## Files Modified

- `lib/validate_config.sh`

## Verification

- ✓ Syntax check: `bash -n` passes
- ✓ Shellcheck: zero warnings
