## What Was Fixed

**lib/quota_probe.sh:67 — SC2086 unquoted variable in for loop**

Replaced the `local IFS=','` + unquoted `for item in $spec` pattern with
`IFS=',' read -ra items <<< "$spec"` and `for item in "${items[@]}"`.

Changes in `_quota_probe_spec_includes_claude`:
- Removed `local IFS=','` (no longer needed)
- Added `local -a items` array declaration
- Split `$spec` via `IFS=',' read -ra items <<< "$spec"` (no word-splitting risk)
- Iterated with `"${items[@]}"` (quoted, shellcheck-clean)
- Added brief `# trim leading/trailing whitespace` comment on the trim line

This also resolves the security agent's LOW glob-expansion finding (A03) at the
same line in the same stroke.

**Verification:** `shellcheck lib/quota_probe.sh` — zero warnings.

## Files Modified

- `lib/quota_probe.sh`
