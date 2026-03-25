# JR Coder Summary — Milestone 25

## What Was Fixed

- **`lib/notes_cli.sh:165,180-182` — Double-increment of `total` in `list_human_notes_cli()`**
  - Removed the redundant increment logic inside the `*` (untagged) case
  - Removed lines 180–182: `total=$((total + 1))`, the comment, and the no-op calculation `total=$((total - 1 + 1))`
  - `total` is now correctly incremented once per unchecked note at line 165, regardless of tag
  - Untagged notes no longer inflate the displayed count

## Files Modified

- `lib/notes_cli.sh` (lines 175–184: simplified the `*` case in the `case "$tag"` statement)

## Verification

- ✓ `bash -n lib/notes_cli.sh` passed
- ✓ `shellcheck lib/notes_cli.sh` passed
